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
	stunXorMappedAddr   = 0x0020
)

// stunResponse answers a Binding Request, or returns nil for anything else.
// The answer is no larger than a typical request, so it can't amplify traffic.
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
