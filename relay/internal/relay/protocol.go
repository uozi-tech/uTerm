// Package relay implements uterm-relay; the wire protocol is in PROTOCOL.md.
package relay

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
)

const (
	protocolVersion = 1
	magic           = "UTRL"
	maxFrameBytes   = 64 * 1024
	// nonceBytes is the raw challenge the relay writes after the client's magic.
	nonceBytes = 32
	signPrefix = "uterm-relay-v1"
	// certPrefix starts the text a member certificate signs, see certMessage. v1 certificates (relay 1.2.x)
	// had no expiry and are no longer accepted.
	certPrefix = "uterm-relay-member-v2"
	// certMaxLifetime caps how far ahead a certificate may expire. Hosts issue 90 days; anything signed
	// further out is refused, which also bounds how long a revocation has to be kept.
	certMaxLifetime = 180 * 24 * time.Hour
)

const (
	roleHost   = "host"
	roleClient = "client"
	roleDial   = "dial"
	roleAccept = "accept"
)

// Reasons sent in a failed answer.
const (
	reasonHostKey = "hostKey"
	reasonFull    = "full"
	reasonOffline = "offline"
	reasonTicket  = "ticket"
	reasonInvalid = "invalid"
)

// requestFrame is the first frame of a connection.
type requestFrame struct {
	Role    string `json:"role"`
	HostID  string `json:"hostID,omitempty"`
	HostKey string `json:"hostKey,omitempty"`
	Session string `json:"session,omitempty"`
	Ticket  string `json:"ticket,omitempty"`
	Sig     string `json:"sig,omitempty"`
	HostSig string `json:"hostSig,omitempty"`
	// Member, Cert and Scope are set by a member that holds its own key instead of the relay's:
	// Member is its public key, Cert the relay key's signature over certMessage, Scope the only host
	// it may reach, Expires (Unix seconds) when the certificate stops working. Sig is then made with the
	// member's own key.
	Member  string `json:"member,omitempty"`
	Cert    string `json:"cert,omitempty"`
	Scope   string `json:"scope,omitempty"`
	Expires int64  `json:"exp,omitempty"`
}

type answerFrame struct {
	OK     bool   `json:"ok"`
	Reason string `json:"reason,omitempty"`
	// Server is the relay build, e.g. "1.1.1", so apps can tell the owner an update exists. Only sent to
	// a member that has just authenticated as host or client: an anonymous prober must not learn the
	// version and pick targets by it. Absent before 1.1.1.
	Server string `json:"server,omitempty"`
}

// messageFrame is every frame after the request on a control connection.
type messageFrame struct {
	Type    string   `json:"type"`
	Session string   `json:"session,omitempty"`
	From    string   `json:"from,omitempty"`
	To      string   `json:"to,omitempty"`
	Box     string   `json:"box,omitempty"`
	Ticket  string   `json:"ticket,omitempty"`
	Hosts   []string `json:"hosts,omitempty"`
	// Member is the public key a host revokes, and the one the relay confirms. Expires is when that
	// member's certificate runs out anyway: the revocation is kept until then and no longer.
	Member  string `json:"member,omitempty"`
	Expires int64  `json:"exp,omitempty"`
}

func writeFrame(w io.Writer, value any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(body) > maxFrameBytes {
		return errors.New("frame too large")
	}
	frame := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(frame, uint32(len(body)))
	copy(frame[4:], body)
	_, err = w.Write(frame)
	return err
}

func readFrame(r io.Reader, value any) error {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return err
	}
	length := binary.BigEndian.Uint32(header[:])
	if length == 0 || length > maxFrameBytes {
		return fmt.Errorf("bad frame length %d", length)
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return err
	}
	return json.Unmarshal(body, value)
}

func signedMessage(role, relayID, nonce, parameter string) []byte {
	return []byte(strings.Join([]string{signPrefix, role, relayID, nonce, parameter}, "\n"))
}

// certMessage is what the relay's member key signs to let another key in: that key may reach one host
// until expires (Unix seconds).
func certMessage(relayID, member, scope string, expires int64) []byte {
	return []byte(strings.Join([]string{certPrefix, relayID, member, scope, strconv.FormatInt(expires, 10)}, "\n"))
}

func verifySignature(key *ecdsa.PublicKey, message []byte, signature string) bool {
	if key == nil {
		return false
	}
	der, err := base64.StdEncoding.DecodeString(signature)
	if err != nil {
		return false
	}
	digest := sha256.Sum256(message)
	return ecdsa.VerifyASN1(key, digest[:], der)
}

func parsePublicKey(encoded string) (*ecdsa.PublicKey, error) {
	der, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PublicKey)
	if !ok {
		return nil, errors.New("not an ECDSA key")
	}
	return key, nil
}

func encodePublicKey(key *ecdsa.PublicKey) (string, error) {
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(der), nil
}

func randomBytes(count int) []byte {
	bytes := make([]byte, count)
	if _, err := rand.Read(bytes); err != nil {
		panic(err)
	}
	return bytes
}
