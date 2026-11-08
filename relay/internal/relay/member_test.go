package relay

import (
	"crypto/ecdsa"
	"fmt"
	"io"
	"net"
	"testing"
	"time"
)

// certMember is a member that holds its own key: the relay's key signed a certificate for it and one host.
type certMember struct {
	key    *ecdsa.PrivateKey
	public string
	cert   string
	scope  string
}

func (h *harness) certify(scope string) certMember {
	h.t.Helper()
	key := newKey(h.t)
	public, err := encodePublicKey(&key.PublicKey)
	if err != nil {
		h.t.Fatal(err)
	}
	return certMember{key: key, public: public, scope: scope,
		cert: sign(h.t, h.member, certMessage(h.relayID, public, scope))}
}

func (m certMember) request(t *testing.T, role, relayID, nonce, parameter string) requestFrame {
	return requestFrame{Role: role, Member: m.public, Cert: m.cert, Scope: m.scope,
		Sig: sign(t, m.key, signedMessage(role, relayID, nonce, parameter))}
}

func (h *harness) certClient(m certMember) (net.Conn, answerFrame) {
	h.t.Helper()
	conn, hello := h.open()
	writeFrame(conn, m.request(h.t, roleClient, h.relayID, hello.Nonce, ""))
	return conn, h.answer(conn)
}

func (h *harness) certDial(m certMember, hostID string) net.Conn {
	h.t.Helper()
	conn, hello := h.open()
	request := m.request(h.t, roleDial, h.relayID, hello.Nonce, hostID)
	request.HostID, request.Session = hostID, "s1"
	writeFrame(conn, request)
	return conn
}

func TestCertifiedMemberSeesAndReachesOnlyItsHost(t *testing.T) {
	h := newHarness(t, testLimits())
	mine := h.registerHost("mac-1", newKey(t))
	other := h.registerHost("mac-2", newKey(t))
	member := h.certify("mac-1")

	phone, answer := h.certClient(member)
	if !answer.OK || answer.Server != "9.8.7" {
		t.Fatalf("client answer = %+v", answer)
	}
	writeFrame(phone, messageFrame{Type: "list"})
	if got := readMessage(t, phone); len(got.Hosts) != 1 || got.Hosts[0] != "mac-1" {
		t.Fatalf("list = %+v", got)
	}

	writeFrame(phone, messageFrame{Type: "signal", To: "mac-2", Session: "a", Box: "x"})
	if got := readMessage(t, phone); got.Type != "undeliverable" || got.Session != "a" {
		t.Fatalf("signal to another host = %+v", got)
	}
	other.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	var leaked messageFrame
	if err := readFrame(other, &leaked); err == nil {
		t.Fatalf("another host got the signal: %+v", leaked)
	}
	writeFrame(phone, messageFrame{Type: "signal", To: "mac-1", Session: "b", From: "phone", Box: "offer"})
	if got := readMessage(t, mine); got.Type != "signal" || got.Box != "offer" {
		t.Fatalf("its host got %+v", got)
	}

	// Its host offline: the list is empty rather than the scope.
	mine.Close()
	waitFor(t, func() bool { return len(h.server.Status().Hosts) == 1 })
	writeFrame(phone, messageFrame{Type: "list"})
	if got := readMessage(t, phone); len(got.Hosts) != 0 {
		t.Fatalf("list after its host left = %+v", got)
	}
}

func TestCertifiedMemberDialsOnlyItsHost(t *testing.T) {
	h := newHarness(t, testLimits())
	key := newKey(t)
	host := h.registerHost("mac-1", key)
	h.registerHost("mac-2", newKey(t))
	member := h.certify("mac-1")

	if answer := h.answer(h.certDial(member, "mac-2")); answer.Reason != reasonClosed {
		t.Fatalf("dial outside the scope got %+v", answer)
	}
	phone := h.certDial(member, "mac-1")
	incoming := readMessage(t, host)
	leg, answer := h.accept(incoming.Ticket, key)
	if !answer.OK {
		t.Fatalf("accept: %+v", answer)
	}
	if answer := h.answer(phone); !answer.OK {
		t.Fatalf("dial: %+v", answer)
	}
	leg.Write([]byte("hi"))
	got := make([]byte, 2)
	if _, err := io.ReadFull(phone, got); err != nil || string(got) != "hi" {
		t.Fatalf("splice: %q %v", got, err)
	}
}

func TestCertifiedMemberCannotRegisterAHost(t *testing.T) {
	h := newHarness(t, testLimits())
	member := h.certify("mac-1")
	hostKey := newKey(t)
	public, _ := encodePublicKey(&hostKey.PublicKey)
	conn, hello := h.open()
	message := signedMessage(roleHost, h.relayID, hello.Nonce, "mac-1")
	request := member.request(t, roleHost, h.relayID, hello.Nonce, "mac-1")
	request.HostID, request.HostKey, request.HostSig = "mac-1", public, sign(t, hostKey, message)
	writeFrame(conn, request)
	if answer := h.answer(conn); answer.Reason != reasonClosed {
		t.Fatalf("a certificate member registered a host: %+v", answer)
	}
}

func TestForgedOrMismatchedCertificatesAreRefusedSilently(t *testing.T) {
	h := newHarness(t, testLimits())
	h.registerHost("mac-1", newKey(t))
	good := h.certify("mac-1")

	cases := map[string]certMember{}
	selfSigned := good
	selfSigned.cert = sign(t, good.key, certMessage(h.relayID, good.public, good.scope))
	cases["signed by the member itself"] = selfSigned
	widened := good
	widened.scope = "mac-2"
	cases["scope changed after signing"] = widened
	swapped := h.certify("mac-1")
	swapped.key = newKey(t)
	cases["someone else's certificate"] = swapped
	noCert := good
	noCert.cert = ""
	cases["no certificate"] = noCert
	noScope := good
	noScope.scope = ""
	noScope.cert = sign(t, h.member, certMessage(h.relayID, good.public, ""))
	cases["no scope"] = noScope

	for name, member := range cases {
		if _, answer := h.certClient(member); answer.Reason != reasonClosed {
			t.Errorf("%s: got %+v", name, answer)
		}
	}
}

func TestRevokedMemberIsCutOffAndStaysOut(t *testing.T) {
	h := newHarness(t, testLimits())
	key := newKey(t)
	host := h.registerHost("mac-1", key)
	member := h.certify("mac-1")
	keep := h.certify("mac-1")

	control, _ := h.certClient(member)
	phone := h.certDial(member, "mac-1")
	incoming := readMessage(t, host)
	leg, _ := h.accept(incoming.Ticket, key)
	if answer := h.answer(phone); !answer.OK {
		t.Fatalf("dial: %+v", answer)
	}
	other, _ := h.certClient(keep)

	writeFrame(host, messageFrame{Type: "revoke", Member: member.public})
	if got := readMessage(t, host); got.Type != "revoked" || got.Member != member.public {
		t.Fatalf("host got %+v", got)
	}
	for name, conn := range map[string]net.Conn{"control": control, "relayed": phone, "host leg": leg} {
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		if _, err := io.ReadAll(conn); err != nil {
			t.Fatalf("%s connection still open: %v", name, err)
		}
	}
	if _, answer := h.certClient(member); answer.Reason != reasonClosed {
		t.Fatalf("revoked member got back in: %+v", answer)
	}
	writeFrame(other, messageFrame{Type: "list"})
	if got := readMessage(t, other); len(got.Hosts) != 1 {
		t.Fatalf("another member was cut off too: %+v", got)
	}

	// The revocation outlives a restart.
	reopened, err := OpenStore(h.store.dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if !reopened.IsRevoked(member.public) || reopened.IsRevoked(keep.public) {
		t.Fatal("revocation not saved, or saved too much")
	}
}

func TestRevocationListKeepsTheNewest(t *testing.T) {
	store, err := OpenStore(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < revocationLimit+5; i++ {
		store.revoked[fmt.Sprintf("old-%05d", i)] = int64(i)
	}
	if err := store.Revoke("newest"); err != nil {
		t.Fatal(err)
	}
	if len(store.revoked) != revocationLimit || !store.IsRevoked("newest") || store.IsRevoked("old-00000") {
		t.Fatalf("kept %d, newest %v, oldest %v", len(store.revoked), store.IsRevoked("newest"),
			store.IsRevoked("old-00000"))
	}
}

func TestRotateForgetsRevocations(t *testing.T) {
	store, err := OpenStore(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Revoke("member"); err != nil {
		t.Fatal(err)
	}
	if err := store.Rotate(); err != nil {
		t.Fatal(err)
	}
	if store.IsRevoked("member") {
		t.Fatal("revocation survived rotate")
	}
}

func TestFreshRevocationSurvivesSameSecondEviction(t *testing.T) {
	store, err := OpenStore(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	for i := 0; i < revocationLimit; i++ {
		store.revoked[fmt.Sprintf("same-second-%05d", i)] = now
	}
	// Sorts before every existing key, all from the same second: it must still be the one kept.
	if err := store.Revoke("0-fresh"); err != nil {
		t.Fatal(err)
	}
	if !store.IsRevoked("0-fresh") || len(store.revoked) != revocationLimit {
		t.Fatalf("fresh revocation kept: %v, size %d", store.IsRevoked("0-fresh"), len(store.revoked))
	}
}
