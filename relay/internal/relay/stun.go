package relay

import (
	"encoding/binary"
	"net"
	"net/netip"
)

const (
	stunHeaderBytes     = 20
	stunMagicCookie     = 0x2112A442
	stunBindingRequest  = 0x0001
	stunBindingResponse = 0x0101
	stunBindingError    = 0x0111
	stunXorMappedAddr   = 0x0020
	stunErrorCode       = 0x0009
	// stunErrorBytes is a Binding error response carrying only a bare ERROR-CODE.
	stunErrorBytes = stunHeaderBytes + 8
)

// stunResponse answers a Binding Request, or returns nil for anything else.
//
// The answer is never larger than the request, so a forged source address can't use the relay to
// amplify traffic. An XOR-MAPPED-ADDRESS answer is 32 bytes for IPv4 and 44 for IPv6, more than a bare
// 20-byte request. libjuice, the app's ICE agent, sends 40 bytes (SOFTWARE and FINGERPRINT): that fits
// IPv4 but not IPv6. When the address doesn't fit, the request gets a 500 error instead, so libjuice
// marks the server failed at once rather than retrying for twenty seconds before gathering finishes; an
// IPv6 host candidate usually carries the same address anyway. Requests too short even for that are
// dropped.
func stunResponse(request []byte, from netip.AddrPort) []byte {
	if len(request) < stunHeaderBytes || request[0]&0xC0 != 0 {
		return nil
	}
	if binary.BigEndian.Uint16(request) != stunBindingRequest ||
		binary.BigEndian.Uint32(request[4:]) != stunMagicCookie {
		return nil
	}
	if int(binary.BigEndian.Uint16(request[2:]))+stunHeaderBytes != len(request) {
		return nil
	}

	address := from.Addr().Unmap()
	var family byte = 1
	raw := address.AsSlice()
	if address.Is6() {
		family = 2
	}
	var mask [16]byte
	binary.BigEndian.PutUint32(mask[:], stunMagicCookie)
	copy(mask[4:], request[8:20])
	for index := range raw {
		raw[index] ^= mask[index]
	}
	port := from.Port() ^ uint16(stunMagicCookie>>16)

	attributeLength := 4 + len(raw)
	if stunHeaderBytes+4+attributeLength > len(request) {
		return stunErrorResponse(request)
	}
	response := make([]byte, stunHeaderBytes+4+attributeLength)
	binary.BigEndian.PutUint16(response, stunBindingResponse)
	binary.BigEndian.PutUint16(response[2:], uint16(4+attributeLength))
	copy(response[4:20], request[4:20])
	binary.BigEndian.PutUint16(response[20:], stunXorMappedAddr)
	binary.BigEndian.PutUint16(response[22:], uint16(attributeLength))
	response[25] = family
	binary.BigEndian.PutUint16(response[26:], port)
	copy(response[28:], raw)
	return response
}

// stunErrorResponse is 500 Server Error with an empty reason, or nil when even that exceeds the
// request. 400 would read better, but RFC 8489 has clients discard an unauthenticated 400 and keep
// retrying.
func stunErrorResponse(request []byte) []byte {
	if len(request) < stunErrorBytes {
		return nil
	}
	response := make([]byte, stunErrorBytes)
	binary.BigEndian.PutUint16(response, stunBindingError)
	binary.BigEndian.PutUint16(response[2:], 8)
	copy(response[4:20], request[4:20])
	binary.BigEndian.PutUint16(response[20:], stunErrorCode)
	binary.BigEndian.PutUint16(response[22:], 4)
	response[26] = 5 // class 5, number 0: 500
	return response
}

func serveSTUN(conn *net.UDPConn) {
	buffer := make([]byte, 1500)
	for {
		count, from, err := conn.ReadFromUDPAddrPort(buffer)
		if err != nil {
			return
		}
		if response := stunResponse(buffer[:count], from); response != nil {
			_, _ = conn.WriteToUDPAddrPort(response, from)
		}
	}
}
