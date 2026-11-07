package relay

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func testLimits() Limits {
	limits := DefaultLimits()
	limits.RatePerIP = 0
	limits.UnauthedPerSource = 0
	limits.TicketLife = 300 * time.Millisecond
	limits.RequestTimeout = 300 * time.Millisecond
	return limits
}

type harness struct {
	t       *testing.T
	store   *Store
	server  *Server
	address string
	relayID string
	member  *ecdsa.PrivateKey
}

func newHarness(t *testing.T, limits Limits) *harness {
	t.Helper()
	store, err := OpenStore(t.TempDir(), "test")
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(store, limits)
	server.Version = "9.8.7"
	bound, err := server.Listen("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(server.Close)
	h := &harness{t: t, store: store, server: server, address: bound.String()}
	h.loadMember()
	return h
}

func (h *harness) loadMember() {
	h.t.Helper()
	config, err := h.store.ClientConfig("relay.test", 47310)
	if err != nil {
		h.t.Fatal(err)
	}
	h.relayID = config.RelayID
	h.member = privateFromConfig(h.t, config.Key)
}

func privateFromConfig(t *testing.T, encoded string) *ecdsa.PrivateKey {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), raw)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func sign(t *testing.T, key *ecdsa.PrivateKey, message []byte) string {
	t.Helper()
	digest := sha256.Sum256(message)
	der, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

func newKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

// open connects and reads the hello.
func (h *harness) open() (net.Conn, helloFrame) {
	h.t.Helper()
	conn, err := net.Dial("tcp", h.address)
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { conn.Close() })
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write(append([]byte(magic), protocolVersion)); err != nil {
		h.t.Fatal(err)
	}
	var hello helloFrame
	if err := readFrame(conn, &hello); err != nil {
		h.t.Fatal(err)
	}
	return conn, hello
}

func (h *harness) answer(conn net.Conn) answerFrame {
	h.t.Helper()
	var answer answerFrame
	if err := readFrame(conn, &answer); err != nil {
		h.t.Fatalf("no answer: %v", err)
	}
	return answer
}

func (h *harness) registerHost(hostID string, hostKey *ecdsa.PrivateKey) net.Conn {
	h.t.Helper()
	conn, answer := h.tryRegister(hostID, hostKey, h.member)
	if !answer.OK {
		h.t.Fatalf("register failed: %s", answer.Reason)
	}
	return conn
}

func (h *harness) tryRegister(hostID string, hostKey, member *ecdsa.PrivateKey) (net.Conn, answerFrame) {
	h.t.Helper()
	conn, hello := h.open()
	public, err := encodePublicKey(&hostKey.PublicKey)
	if err != nil {
		h.t.Fatal(err)
	}
	message := signedMessage(roleHost, h.relayID, hello.Nonce, hostID)
	writeFrame(conn, requestFrame{Role: roleHost, HostID: hostID, HostKey: public,
		Sig: sign(h.t, member, message), HostSig: sign(h.t, hostKey, message)})
	return conn, h.answer(conn)
}

func (h *harness) client() net.Conn {
	h.t.Helper()
	conn, hello := h.open()
	writeFrame(conn, requestFrame{Role: roleClient, Sig: sign(h.t, h.member, signedMessage(roleClient, h.relayID, hello.Nonce, ""))})
	if answer := h.answer(conn); !answer.OK {
		h.t.Fatalf("client refused: %s", answer.Reason)
	}
	return conn
}

func (h *harness) dial(hostID string) net.Conn {
	h.t.Helper()
	conn, hello := h.open()
	writeFrame(conn, requestFrame{Role: roleDial, HostID: hostID, Session: "s1",
		Sig: sign(h.t, h.member, signedMessage(roleDial, h.relayID, hello.Nonce, hostID))})
	return conn
}

func (h *harness) accept(ticket string, hostKey *ecdsa.PrivateKey) (net.Conn, answerFrame) {
	h.t.Helper()
	conn, hello := h.open()
	writeFrame(conn, requestFrame{Role: roleAccept, Ticket: ticket,
		HostSig: sign(h.t, hostKey, signedMessage(roleAccept, h.relayID, hello.Nonce, ticket))})
	return conn, h.answer(conn)
}

func readMessage(t *testing.T, conn net.Conn) messageFrame {
	t.Helper()
	var frame messageFrame
	if err := readFrame(conn, &frame); err != nil {
		t.Fatalf("no message: %v", err)
	}
	return frame
}

func TestHelloCarriesTheBuildVersion(t *testing.T) {
	h := newHarness(t, testLimits())
	_, hello := h.open()
	if hello.Version != protocolVersion || hello.Server != "9.8.7" || hello.RelayID != h.relayID {
		t.Fatalf("hello = %+v", hello)
	}
}

func TestWrongMemberKeyIsRefusedOnEveryRole(t *testing.T) {
	h := newHarness(t, testLimits())
	stranger := newKey(t)

	if _, answer := h.tryRegister("host-1", newKey(t), stranger); answer.Reason != reasonAuth {
		t.Fatalf("host: %+v", answer)
	}
	conn, hello := h.open()
	writeFrame(conn, requestFrame{Role: roleClient, Sig: sign(t, stranger, signedMessage(roleClient, h.relayID, hello.Nonce, ""))})
	if answer := h.answer(conn); answer.Reason != reasonAuth {
		t.Fatalf("client: %+v", answer)
	}
	conn, hello = h.open()
	writeFrame(conn, requestFrame{Role: roleDial, HostID: "h", Sig: sign(t, stranger, signedMessage(roleDial, h.relayID, hello.Nonce, "h"))})
	if answer := h.answer(conn); answer.Reason != reasonAuth {
		t.Fatalf("dial: %+v", answer)
	}
}

func TestSignatureFromAnotherConnectionIsRefused(t *testing.T) {
	h := newHarness(t, testLimits())
	conn, _ := h.open()
	replayed := sign(t, h.member, signedMessage(roleClient, h.relayID, "someone-elses-nonce", ""))
	writeFrame(conn, requestFrame{Role: roleClient, Sig: replayed})
	if answer := h.answer(conn); answer.Reason != reasonAuth {
		t.Fatalf("replayed signature accepted: %+v", answer)
	}
}

func TestVersionMismatchIsAnswered(t *testing.T) {
	h := newHarness(t, testLimits())
	conn, err := net.Dial("tcp", h.address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	conn.Write(append([]byte(magic), 99))
	var hello helloFrame
	if err := readFrame(conn, &hello); err != nil {
		t.Fatal(err)
	}
	if answer := h.answer(conn); answer.Reason != reasonVersion {
		t.Fatalf("got %+v", answer)
	}
}

func TestSilentAndGarbageConnectionsAreClosed(t *testing.T) {
	h := newHarness(t, testLimits())
	for _, opening := range [][]byte{nil, []byte("GET / HTTP/1.1\r\n\r\n")} {
		conn, err := net.Dial("tcp", h.address)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		if opening != nil {
			conn.Write(opening)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		// Unread bytes turn the close into a reset; either way only a timeout means it stayed open.
		if _, err := io.ReadAll(conn); err != nil && os.IsTimeout(err) {
			t.Fatalf("not closed in time: %v", err)
		}
	}
}

func TestHostKeyBindingStopsTakeover(t *testing.T) {
	h := newHarness(t, testLimits())
	owner := newKey(t)
	h.registerHost("mac-1", owner)

	if _, answer := h.tryRegister("mac-1", newKey(t), h.member); answer.Reason != reasonHostKey {
		t.Fatalf("another key took the id: %+v", answer)
	}
	if status := h.server.Status(); len(status.Hosts) != 1 {
		t.Fatalf("owner should stay registered: %+v", status)
	}
}

func TestBindingSurvivesRestartAndForgetClearsIt(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := store.BindHost("mac", "key-a", DefaultLimits().Bindings); !ok || err != nil {
		t.Fatalf("first bind: %v %v", ok, err)
	}
	reopened, err := OpenStore(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if ok, _ := reopened.BindHost("mac", "key-b", DefaultLimits().Bindings); ok {
		t.Fatal("binding was lost across restart")
	}
	if err := reopened.Forget("mac"); err != nil {
		t.Fatal(err)
	}
	if ok, _ := reopened.BindHost("mac", "key-b", DefaultLimits().Bindings); !ok {
		t.Fatal("forget did not clear the binding")
	}
}

func TestSameKeyRegistrationSupersedesOldConnection(t *testing.T) {
	h := newHarness(t, testLimits())
	key := newKey(t)
	first := h.registerHost("mac-1", key)
	h.registerHost("mac-1", key)
	if frame := readMessage(t, first); frame.Type != "superseded" {
		t.Fatalf("got %+v", frame)
	}
}

func TestSignalingRoutesBothWaysAndStaysWithItsOwner(t *testing.T) {
	h := newHarness(t, testLimits())
	host := h.registerHost("mac-1", newKey(t))
	phone := h.client()
	other := h.client()

	writeFrame(phone, messageFrame{Type: "signal", To: "mac-1", Session: "sess", From: "phone-1", Box: "offer"})
	got := readMessage(t, host)
	if got.Type != "signal" || got.Session != "sess" || got.From != "phone-1" || got.Box != "offer" {
		t.Fatalf("host got %+v", got)
	}

	// Another member reusing the id must not take over the replies.
	writeFrame(other, messageFrame{Type: "signal", To: "mac-1", Session: "sess", From: "evil", Box: "x"})
	writeFrame(host, messageFrame{Type: "signal", Session: "sess", Box: "answer"})
	if back := readMessage(t, phone); back.Box != "answer" {
		t.Fatalf("phone got %+v", back)
	}
	other.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	var leaked messageFrame
	if err := readFrame(other, &leaked); err == nil {
		t.Fatalf("reply leaked to another member: %+v", leaked)
	}
}

func TestSignalToOfflineHostIsUndeliverable(t *testing.T) {
	h := newHarness(t, testLimits())
	phone := h.client()
	writeFrame(phone, messageFrame{Type: "signal", To: "nobody", Session: "s", Box: "x"})
	if got := readMessage(t, phone); got.Type != "undeliverable" || got.Session != "s" {
		t.Fatalf("got %+v", got)
	}
}

func TestListShowsOnlineHostsOnly(t *testing.T) {
	h := newHarness(t, testLimits())
	host := h.registerHost("mac-1", newKey(t))
	phone := h.client()
	writeFrame(phone, messageFrame{Type: "list"})
	if got := readMessage(t, phone); len(got.Hosts) != 1 || got.Hosts[0] != "mac-1" {
		t.Fatalf("got %+v", got)
	}
	host.Close()
	waitFor(t, func() bool { return len(h.server.Status().Hosts) == 0 })
	writeFrame(phone, messageFrame{Type: "list"})
	if got := readMessage(t, phone); len(got.Hosts) != 0 {
		t.Fatalf("got %+v", got)
	}
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met in time")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestDialToOfflineHostIsRefused(t *testing.T) {
	h := newHarness(t, testLimits())
	conn := h.dial("nobody")
	if answer := h.answer(conn); answer.Reason != reasonOffline {
		t.Fatalf("got %+v", answer)
	}
}

func TestSpliceCarriesBytesBothWaysAndClosesTogether(t *testing.T) {
	h := newHarness(t, testLimits())
	key := newKey(t)
	host := h.registerHost("mac-1", key)
	phone := h.dial("mac-1")

	incoming := readMessage(t, host)
	if incoming.Type != "incoming" || incoming.Session != "s1" || incoming.Ticket == "" {
		t.Fatalf("got %+v", incoming)
	}
	leg, answer := h.accept(incoming.Ticket, key)
	if !answer.OK {
		t.Fatalf("accept: %+v", answer)
	}
	if answer := h.answer(phone); !answer.OK {
		t.Fatalf("dial: %+v", answer)
	}

	payload := bytes.Repeat([]byte("uterm"), 200_000)
	go phone.Write(payload)
	received := make([]byte, len(payload))
	leg.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(leg, received); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(received, payload) {
		t.Fatal("bytes changed in the splice")
	}
	leg.Write([]byte("pong"))
	back := make([]byte, 4)
	phone.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(phone, back); err != nil || string(back) != "pong" {
		t.Fatalf("back: %q %v", back, err)
	}

	leg.Close()
	phone.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadAll(phone); err != nil {
		t.Fatalf("other side not closed: %v", err)
	}
	waitFor(t, func() bool { return h.server.Status().Splices == 0 })
}

func TestOnlyTheHostItWasOfferedToCanAcceptATicket(t *testing.T) {
	h := newHarness(t, testLimits())
	key := newKey(t)
	host := h.registerHost("mac-1", key)
	h.dial("mac-1")
	incoming := readMessage(t, host)

	if _, answer := h.accept(incoming.Ticket, newKey(t)); answer.Reason != reasonHostKey {
		t.Fatalf("wrong key accepted: %+v", answer)
	}
	if _, answer := h.accept(incoming.Ticket, key); !answer.OK {
		t.Fatalf("right key refused: %+v", answer)
	}
	if _, answer := h.accept(incoming.Ticket, key); answer.Reason != reasonTicket {
		t.Fatalf("a ticket must work once: %+v", answer)
	}
}

func TestTicketExpiresAndPhoneIsTold(t *testing.T) {
	h := newHarness(t, testLimits())
	key := newKey(t)
	host := h.registerHost("mac-1", key)
	phone := h.dial("mac-1")
	incoming := readMessage(t, host)

	if answer := h.answer(phone); answer.Reason != reasonTicket {
		t.Fatalf("got %+v", answer)
	}
	if _, answer := h.accept(incoming.Ticket, key); answer.Reason != reasonTicket {
		t.Fatalf("expired ticket accepted: %+v", answer)
	}
	waitFor(t, func() bool { return h.server.Status().Splices == 0 })
}

func TestPhoneLeavingKillsTheTicket(t *testing.T) {
	limits := testLimits()
	limits.TicketLife = 5 * time.Second
	h := newHarness(t, limits)
	key := newKey(t)
	host := h.registerHost("mac-1", key)
	phone := h.dial("mac-1")
	incoming := readMessage(t, host)
	phone.Close()
	waitFor(t, func() bool { return h.server.Status().Splices == 0 })
	if _, answer := h.accept(incoming.Ticket, key); answer.Reason != reasonTicket {
		t.Fatalf("got %+v", answer)
	}
}

func TestHostLeavingFailsWaitingDials(t *testing.T) {
	limits := testLimits()
	limits.TicketLife = 5 * time.Second
	h := newHarness(t, limits)
	host := h.registerHost("mac-1", newKey(t))
	phone := h.dial("mac-1")
	readMessage(t, host)
	host.Close()
	if answer := h.answer(phone); answer.Reason != reasonTicket {
		t.Fatalf("got %+v", answer)
	}
}

func TestLimitsAreEnforced(t *testing.T) {
	limits := testLimits()
	limits.Hosts = 1
	limits.TicketsPerHost = 1
	limits.TicketLife = 5 * time.Second
	h := newHarness(t, limits)
	host := h.registerHost("mac-1", newKey(t))
	if _, answer := h.tryRegister("mac-2", newKey(t), h.member); answer.Reason != reasonFull {
		t.Fatalf("host limit: %+v", answer)
	}
	h.dial("mac-1")
	readMessage(t, host)
	second := h.dial("mac-1")
	if answer := h.answer(second); answer.Reason != reasonFull {
		t.Fatalf("ticket limit: %+v", answer)
	}
}

func TestConcurrentRegistrationsStayWithinHostLimit(t *testing.T) {
	limits := testLimits()
	limits.Hosts = 3
	h := newHarness(t, limits)
	const attempts = 24
	var (
		group    sync.WaitGroup
		mu       sync.Mutex
		accepted int
	)
	for index := 0; index < attempts; index++ {
		key := newKey(t)
		group.Add(1)
		go func() {
			defer group.Done()
			conn, answer := h.tryRegister(fmt.Sprintf("mac-%d", index), key, h.member)
			t.Cleanup(func() { conn.Close() })
			if answer.OK {
				mu.Lock()
				accepted++
				mu.Unlock()
			}
		}()
	}
	group.Wait()
	if accepted != limits.Hosts {
		t.Fatalf("%d hosts registered, limit %d", accepted, limits.Hosts)
	}
	if online := len(h.server.Status().Hosts); online != limits.Hosts {
		t.Fatalf("%d hosts online, limit %d", online, limits.Hosts)
	}
}

func TestBindingLimitRefusesNewHostIDsButKeepsKnownOnes(t *testing.T) {
	limits := testLimits()
	limits.Bindings = 2
	h := newHarness(t, limits)
	first, second := newKey(t), newKey(t)
	h.registerHost("mac-1", first).Close()
	h.registerHost("mac-2", second).Close()
	waitFor(t, func() bool { return len(h.server.Status().Hosts) == 0 })

	if _, answer := h.tryRegister("mac-3", newKey(t), h.member); answer.Reason != reasonFull {
		t.Fatalf("a third host ID was bound: %+v", answer)
	}
	h.registerHost("mac-1", first)
	if _, answer := h.tryRegister("mac-2", newKey(t), h.member); answer.Reason != reasonHostKey {
		t.Fatalf("a full store must still check known IDs: %+v", answer)
	}
	if err := h.store.Forget("mac-2"); err != nil {
		t.Fatal(err)
	}
	h.registerHost("mac-3", newKey(t))

	data, err := os.ReadFile(h.store.hostsPath())
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]string
	if err := json.Unmarshal(data, &saved); err != nil || len(saved) != limits.Bindings {
		t.Fatalf("hosts.json holds %v (%v)", saved, err)
	}
}

func TestRateLimitPerAddress(t *testing.T) {
	limiter := newRateLimiter(2, time.Second)
	address := netip.MustParseAddr("192.0.2.1")
	now := time.Unix(1000, 0)
	if !limiter.allow(address, now) || !limiter.allow(address, now) {
		t.Fatal("first two should pass")
	}
	if limiter.allow(address, now) {
		t.Fatal("third should be refused")
	}
	if !limiter.allow(netip.MustParseAddr("192.0.2.2"), now) {
		t.Fatal("another address has its own budget")
	}
	if !limiter.allow(address, now.Add(2*time.Second)) {
		t.Fatal("the window should pass")
	}
}

func TestIPv6SourcesCountPerSlash64(t *testing.T) {
	for address, want := range map[string]string{
		"2001:db8:1:2:aaaa:bbbb:cccc:dddd": "2001:db8:1:2::",
		"2001:db8:1:2::1":                  "2001:db8:1:2::",
		"2001:db8:1:3::1":                  "2001:db8:1:3::",
		"::ffff:192.0.2.7":                 "192.0.2.7",
		"192.0.2.7":                        "192.0.2.7",
	} {
		if got := sourceAddress(netip.MustParseAddr(address)); got != netip.MustParseAddr(want) {
			t.Errorf("%s counts as %s, want %s", address, got, want)
		}
	}
}

// rawConnect opens a TCP connection and sends nothing, the way a slow or hostile
// client holds an unauthenticated slot.
func rawConnect(t *testing.T, address string) net.Conn {
	t.Helper()
	conn, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

// closedByServer reports whether the relay hung up without saying anything.
func closedByServer(conn net.Conn) bool {
	conn.SetReadDeadline(time.Now().Add(time.Second))
	var probe [1]byte
	_, err := conn.Read(probe[:])
	var timeout net.Error
	return err != nil && !(errors.As(err, &timeout) && timeout.Timeout())
}

func TestOneSourceCannotHoldEveryUnauthenticatedSlot(t *testing.T) {
	limits := testLimits()
	limits.UnauthedPerSource = 2
	limits.RequestTimeout = 10 * time.Second
	h := newHarness(t, limits)

	first := rawConnect(t, h.address)
	rawConnect(t, h.address)
	waitFor(t, func() bool {
		h.server.mu.Lock()
		defer h.server.mu.Unlock()
		return h.server.unauthed == 2
	})
	if third := rawConnect(t, h.address); !closedByServer(third) {
		t.Fatal("a third unauthenticated connection from the same source was kept")
	}

	first.Close()
	waitFor(t, func() bool {
		h.server.mu.Lock()
		defer h.server.mu.Unlock()
		return h.server.unauthed == 1
	})
	// The slot comes back, and a connection that authenticates gives its slot up.
	h.client()
	h.client()
	h.server.mu.Lock()
	defer h.server.mu.Unlock()
	if h.server.unauthed != 1 || h.server.unauthedFrom[netip.MustParseAddr("127.0.0.1")] != 1 {
		t.Fatalf("unauthed = %d, per source = %v", h.server.unauthed, h.server.unauthedFrom)
	}
}

func TestOpenStoreTightensAnOpenDataDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "data")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil { // the umask may have taken bits off
		t.Fatal(err)
	}
	if _, err := OpenStore(dir, "test"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o700 {
		t.Fatalf("data directory is %o", mode)
	}
}

func TestRegistrationRefusedAsFullLeavesNoBinding(t *testing.T) {
	limits := testLimits()
	limits.Hosts = 1
	h := newHarness(t, limits)
	h.registerHost("mac-1", newKey(t))
	for index := 2; index <= 5; index++ {
		if _, answer := h.tryRegister(fmt.Sprintf("mac-%d", index), newKey(t), h.member); answer.Reason != reasonFull {
			t.Fatalf("mac-%d: %+v", index, answer)
		}
	}
	data, err := os.ReadFile(h.store.hostsPath())
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]string
	if err := json.Unmarshal(data, &saved); err != nil || len(saved) != 1 || saved["mac-1"] == "" {
		t.Fatalf("hosts.json holds %v (%v)", saved, err)
	}
}

func TestRotateInvalidatesOldMembersAndBindings(t *testing.T) {
	h := newHarness(t, testLimits())
	key := newKey(t)
	host := h.registerHost("mac-1", key)
	old := h.member
	// t.TempDir paths can exceed the 104 bytes a Unix socket path may have on macOS.
	socketDir, err := os.MkdirTemp("", "ur")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(socketDir)
	socket := filepath.Join(socketDir, "admin.sock")
	stop, err := h.server.ServeAdmin(socket)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()

	if answer, err := AdminCommand(socket, "rotate"); err != nil || answer != "ok" {
		t.Fatalf("rotate: %q %v", answer, err)
	}
	host.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := io.ReadAll(host); err != nil {
		t.Fatalf("old connection should be dropped: %v", err)
	}
	h.loadMember()
	if _, answer := h.tryRegister("mac-2", newKey(t), old); answer.Reason != reasonAuth {
		t.Fatalf("old key still works: %+v", answer)
	}
	h.registerHost("mac-1", newKey(t))
}

func TestPrivateKeyStaysOutOfPublicFiles(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir, "n")
	if err != nil {
		t.Fatal(err)
	}
	config, err := store.ClientConfig("relay.test", 47310)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"relay.json", "hosts.json"} {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		if strings.Contains(string(data), config.Key) {
			t.Fatalf("%s holds the private key", name)
		}
	}
	info, err := os.Stat(filepath.Join(dir, "member.key"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("member.key mode %v", info.Mode().Perm())
	}
}

func TestConfigNeedsAPublicHostAndRoundTrips(t *testing.T) {
	store, err := OpenStore(t.TempDir(), "home")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ClientConfig("", 47310); err == nil {
		t.Fatal("config without a host should fail")
	}
	config, err := store.ClientConfig("relay.test", 1234)
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	var decoded ClientConfig
	if err := json.Unmarshal(body, &decoded); err != nil || decoded != config {
		t.Fatalf("round trip: %+v %v", decoded, err)
	}
	link, err := config.URL()
	if err != nil || !strings.HasPrefix(link, "uterm://relay?") {
		t.Fatalf("url: %q %v", link, err)
	}
}

func TestSTUNAnswersBindingWithXorMappedAddress(t *testing.T) {
	h := newHarness(t, testLimits())
	conn, err := net.Dial("udp", h.address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	request := libjuiceBindingRequest()
	copy(request[8:], "transaction!")
	conn.Write(request)

	response := make([]byte, 64)
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	count, err := conn.Read(response)
	if err != nil {
		t.Fatal(err)
	}
	response = response[:count]
	if binary.BigEndian.Uint16(response) != stunBindingResponse || !bytes.Equal(response[8:20], request[8:20]) {
		t.Fatalf("bad header % x", response)
	}
	if binary.BigEndian.Uint16(response[20:]) != stunXorMappedAddr {
		t.Fatalf("bad attribute % x", response)
	}
	local := conn.LocalAddr().(*net.UDPAddr).AddrPort()
	port := binary.BigEndian.Uint16(response[26:]) ^ uint16(stunMagicCookie>>16)
	if port != local.Port() {
		t.Fatalf("port %d, want %d", port, local.Port())
	}
	var cookie [4]byte
	binary.BigEndian.PutUint32(cookie[:], stunMagicCookie)
	address := netip.AddrFrom4([4]byte{response[28] ^ cookie[0], response[29] ^ cookie[1], response[30] ^ cookie[2], response[31] ^ cookie[3]})
	if address != local.Addr().Unmap() {
		t.Fatalf("address %v, want %v", address, local.Addr())
	}
}

// stunBindingRequestOfSize builds a Binding Request of exactly `size` bytes, the attributes being one
// comprehension-optional padding attribute that the relay doesn't read.
func stunBindingRequestOfSize(size int) []byte {
	request := make([]byte, size)
	binary.BigEndian.PutUint16(request, stunBindingRequest)
	binary.BigEndian.PutUint16(request[2:], uint16(size-stunHeaderBytes))
	binary.BigEndian.PutUint32(request[4:], stunMagicCookie)
	if size > stunHeaderBytes {
		binary.BigEndian.PutUint16(request[20:], 0x8026)
		binary.BigEndian.PutUint16(request[22:], uint16(size-stunHeaderBytes-4))
	}
	return request
}

// libjuiceBindingRequest is what the app's ICE agent sends a STUN server: SOFTWARE "libjuice" and
// FINGERPRINT, 40 bytes.
func libjuiceBindingRequest() []byte {
	request := make([]byte, stunHeaderBytes, 40)
	binary.BigEndian.PutUint16(request, stunBindingRequest)
	binary.BigEndian.PutUint16(request[2:], 20)
	binary.BigEndian.PutUint32(request[4:], stunMagicCookie)
	request = binary.BigEndian.AppendUint16(request, 0x8022)
	request = binary.BigEndian.AppendUint16(request, 8)
	request = append(request, "libjuice"...)
	request = binary.BigEndian.AppendUint16(request, 0x8028)
	request = binary.BigEndian.AppendUint16(request, 4)
	return binary.BigEndian.AppendUint32(request, 0xDEADBEEF)
}

func TestSTUNNeverAnswersWithMoreBytesThanItGot(t *testing.T) {
	sources := []netip.AddrPort{
		netip.MustParseAddrPort("192.0.2.1:1000"),
		netip.MustParseAddrPort("[2001:db8::1]:1000"),
	}
	for _, from := range sources {
		for size := stunHeaderBytes; size <= 64; size += 4 {
			request := stunBindingRequestOfSize(size)
			if response := stunResponse(request, from); len(response) > len(request) {
				t.Fatalf("%v: %d-byte request got %d bytes", from, size, len(response))
			}
		}
	}
	if stunResponse(stunBindingRequestOfSize(stunHeaderBytes), sources[0]) != nil {
		t.Fatal("a bare 20-byte request must not be answered")
	}
}

func TestSTUNAnswersWhatLibjuiceSends(t *testing.T) {
	request := libjuiceBindingRequest()
	if len(request) != 40 {
		t.Fatalf("request is %d bytes", len(request))
	}
	if response := stunResponse(request, netip.MustParseAddrPort("192.0.2.1:1000")); len(response) != 32 ||
		binary.BigEndian.Uint16(response) != stunBindingResponse {
		t.Fatalf("IPv4 answer % x", response)
	}
	// The IPv6 address doesn't fit in 40 bytes: a prompt 500 keeps libjuice from retrying for twenty seconds.
	response := stunResponse(request, netip.MustParseAddrPort("[2001:db8::1]:1000"))
	if len(response) != stunErrorBytes || binary.BigEndian.Uint16(response) != stunBindingError ||
		!bytes.Equal(response[4:20], request[4:20]) {
		t.Fatalf("IPv6 answer % x", response)
	}
	if binary.BigEndian.Uint16(response[20:]) != stunErrorCode || int(response[26])*100+int(response[27]) != 500 {
		t.Fatalf("error code % x", response[20:])
	}
}

func TestSTUNIgnoresEverythingElse(t *testing.T) {
	from := netip.MustParseAddrPort("192.0.2.1:1000")
	valid := libjuiceBindingRequest()
	if stunResponse(valid, from) == nil {
		t.Fatal("valid request ignored")
	}
	for name, request := range map[string][]byte{
		"short":      valid[:10],
		"no cookie":  append(append([]byte{}, valid[:4]...), make([]byte, 16)...),
		"not stun":   []byte(strings.Repeat("x", 40)),
		"bad length": append(append([]byte{}, valid...), 1, 2, 3, 4),
	} {
		if stunResponse(request, from) != nil {
			t.Fatalf("%s got an answer", name)
		}
	}
}

func TestSTUNEncodesIPv6(t *testing.T) {
	request := stunBindingRequestOfSize(20 + 4 + 20)
	response := stunResponse(request, netip.MustParseAddrPort("[2001:db8::1]:1000"))
	if len(response) != 20+4+20 || response[25] != 2 {
		t.Fatalf("bad IPv6 answer % x", response)
	}
}

func TestSpliceDoesNotReadAhead(t *testing.T) {
	// The phone's first bytes must reach the Mac even when they arrive right behind `ok`.
	h := newHarness(t, testLimits())
	key := newKey(t)
	host := h.registerHost("mac-1", key)
	phone := h.dial("mac-1")
	incoming := readMessage(t, host)
	leg, answer := h.accept(incoming.Ticket, key)
	if !answer.OK {
		t.Fatal(fmt.Sprintf("%+v", answer))
	}
	h.answer(phone)
	phone.Write([]byte("hello"))
	got := make([]byte, 5)
	leg.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadFull(leg, got); err != nil || string(got) != "hello" {
		t.Fatalf("%q %v", got, err)
	}
}

// `serve` and `config` often start at the same moment. They must end up with one key.
func TestConcurrentOpenStoreAgreesOnOneKey(t *testing.T) {
	for round := 0; round < 20; round++ {
		dir := t.TempDir()
		const openers = 8
		ids := make([]string, openers)
		keys := make([]string, openers)
		var group sync.WaitGroup
		for index := 0; index < openers; index++ {
			group.Add(1)
			go func() {
				defer group.Done()
				store, err := OpenStore(dir, "")
				if err != nil {
					t.Error(err)
					return
				}
				id, public := store.Identity()
				encoded, err := encodePublicKey(public)
				if err != nil {
					t.Error(err)
					return
				}
				ids[index], keys[index] = id, encoded
			}()
		}
		group.Wait()
		for index := range ids {
			if ids[index] != ids[0] || keys[index] != keys[0] {
				t.Fatalf("round %d: opener %d got a different identity", round, index)
			}
		}
		store, err := OpenStore(dir, "")
		if err != nil {
			t.Fatal(err)
		}
		config, err := store.ClientConfig("relay.test", 47310)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := base64.StdEncoding.DecodeString(config.Key)
		if err != nil {
			t.Fatal(err)
		}
		private, err := ecdh.P256().NewPrivateKey(raw)
		if err != nil {
			t.Fatal(err)
		}
		public, err := ecdsaPublicKey(private)
		if err != nil {
			t.Fatal(err)
		}
		encoded, err := encodePublicKey(public)
		if err != nil {
			t.Fatal(err)
		}
		if encoded != keys[0] {
			t.Fatalf("round %d: exported key does not match the identity", round)
		}
	}
}
