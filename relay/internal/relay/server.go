package relay

import (
	"bufio"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"sort"
	"sync"
	"time"
)

// Limits bound what one relay holds. Tests shrink the timeouts.
type Limits struct {
	Hosts          int
	Bindings       int // host ID → key bindings kept in hosts.json, online or not
	TicketsPerHost int
	Splices        int
	Controls       int
	Unauthed       int
	// UnauthedPerSource caps how many of the Unauthed slots one source holds, so a
	// single machine can't fill them all. 0 turns it off, as RatePerIP 0 does.
	UnauthedPerSource int
	RatePerIP         int
	RateWindow        time.Duration
	RequestTimeout    time.Duration
	TicketLife        time.Duration
	HostSilence       time.Duration
	ClientSilence     time.Duration
	WriteTimeout      time.Duration
}

// DefaultLimits are the production values, documented in PROTOCOL.md.
func DefaultLimits() Limits {
	return Limits{
		Hosts: 64, Bindings: 1024, TicketsPerHost: 32, Splices: 512, Controls: 256, Unauthed: 64,
		UnauthedPerSource: 16, RatePerIP: 60, RateWindow: 10 * time.Second,
		RequestTimeout: 5 * time.Second, TicketLife: 10 * time.Second,
		HostSilence: 200 * time.Second, ClientSilence: 200 * time.Second,
		WriteTimeout: 10 * time.Second,
	}
}

// Server is a running relay.
type Server struct {
	store  *Store
	limits Limits
	rate   *rateLimiter

	mu       sync.Mutex
	hosts    map[string]*control
	clients  map[*control]struct{}
	sessions map[string]*control // signaling session → the phone that opened it
	tickets  map[string]*pendingDial
	splices  int
	unauthed int
	// unauthed connections per source, only tracked while UnauthedPerSource is on
	unauthedFrom map[netip.Addr]int
	closed       bool
	listener     net.Listener
	packet       *net.UDPConn
	allConns     map[net.Conn]struct{}
	waitGroup    sync.WaitGroup
}

// control is one registered Mac or one phone's control connection.
type control struct {
	conn    net.Conn
	writeMu sync.Mutex
	hostID  string
	hostKey string
	// sessions a phone opened, cleared when it goes away.
	sessions map[string]struct{}
	tickets  map[string]struct{}
}

type pendingDial struct {
	ticket string
	host   *control
	client net.Conn
	ready  chan net.Conn
	timer  *time.Timer
}

func NewServer(store *Store, limits Limits) *Server {
	return &Server{
		store: store, limits: limits,
		rate:     newRateLimiter(limits.RatePerIP, limits.RateWindow),
		hosts:    map[string]*control{},
		clients:  map[*control]struct{}{},
		sessions: map[string]*control{},
		tickets:  map[string]*pendingDial{},
		allConns: map[net.Conn]struct{}{},

		unauthedFrom: map[netip.Addr]int{},
	}
}

// Listen binds TCP and UDP on the same address and starts serving. It returns the TCP address.
func (s *Server) Listen(address string) (netip.AddrPort, error) {
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return netip.AddrPort{}, err
	}
	bound := listener.Addr().(*net.TCPAddr).AddrPort()
	packet, err := net.ListenUDP("udp", net.UDPAddrFromAddrPort(netip.AddrPortFrom(bound.Addr(), bound.Port())))
	if err != nil {
		listener.Close()
		return netip.AddrPort{}, fmt.Errorf("udp: %w", err)
	}
	s.mu.Lock()
	s.listener, s.packet = listener, packet
	s.mu.Unlock()
	s.waitGroup.Add(2)
	go func() { defer s.waitGroup.Done(); serveSTUN(packet) }()
	go func() { defer s.waitGroup.Done(); s.accept(listener) }()
	return bound, nil
}

// Close stops listening and drops every connection.
func (s *Server) Close() {
	s.mu.Lock()
	s.closed = true
	listener, packet := s.listener, s.packet
	conns := make([]net.Conn, 0, len(s.allConns))
	for conn := range s.allConns {
		conns = append(conns, conn)
	}
	s.mu.Unlock()
	if listener != nil {
		listener.Close()
	}
	if packet != nil {
		packet.Close()
	}
	for _, conn := range conns {
		conn.Close()
	}
	s.waitGroup.Wait()
}

// Status is what `uterm-relay status` prints.
type Status struct {
	Hosts   []string `json:"hosts"`
	Clients int      `json:"clients"`
	Splices int      `json:"splices"`
}

func (s *Server) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return Status{Hosts: s.onlineHostsLocked(), Clients: len(s.clients), Splices: s.splices}
}

// DropAll ends every connection; used after the member key changes.
func (s *Server) DropAll() {
	s.mu.Lock()
	conns := make([]net.Conn, 0, len(s.allConns))
	for conn := range s.allConns {
		conns = append(conns, conn)
	}
	s.mu.Unlock()
	for _, conn := range conns {
		conn.Close()
	}
}

// DropHost ends one registration, after its binding was forgotten.
func (s *Server) DropHost(hostID string) {
	s.mu.Lock()
	host := s.hosts[hostID]
	s.mu.Unlock()
	if host != nil {
		host.conn.Close()
	}
}

func (s *Server) onlineHostsLocked() []string {
	hosts := make([]string, 0, len(s.hosts))
	for id := range s.hosts {
		hosts = append(hosts, id)
	}
	sort.Strings(hosts)
	return hosts
}

func (s *Server) accept(listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		source := sourceOf(conn)
		if !s.admit(conn, source) {
			conn.Close()
			continue
		}
		s.waitGroup.Add(1)
		go func() {
			defer s.waitGroup.Done()
			s.handle(conn, source)
		}()
	}
}

func (s *Server) admit(conn net.Conn, source netip.Addr) bool {
	if !s.rate.allow(source, time.Now()) {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.unauthed >= s.limits.Unauthed {
		return false
	}
	if perSource := s.limits.UnauthedPerSource; perSource > 0 {
		if s.unauthedFrom[source] >= perSource {
			return false
		}
		s.unauthedFrom[source]++
	}
	s.unauthed++
	s.allConns[conn] = struct{}{}
	return true
}

// sourceOf is the address limits are counted against. An IPv6 host usually owns
// a whole /64 and can pick a new address for every connection, so the /64 counts
// as one source.
func sourceOf(conn net.Conn) netip.Addr {
	address, ok := conn.RemoteAddr().(*net.TCPAddr)
	if !ok {
		return netip.Addr{}
	}
	return sourceAddress(address.AddrPort().Addr())
}

func sourceAddress(address netip.Addr) netip.Addr {
	address = address.Unmap()
	if address.Is6() {
		return netip.PrefixFrom(address, 64).Masked().Addr()
	}
	return address
}

// handle reads the request and routes the connection. Exactly one path releases `unauthed`.
func (s *Server) handle(conn net.Conn, source netip.Addr) {
	defer func() {
		conn.Close()
		s.mu.Lock()
		delete(s.allConns, conn)
		s.mu.Unlock()
	}()
	released := false
	release := func() {
		if released {
			return
		}
		released = true
		s.mu.Lock()
		s.unauthed--
		if s.limits.UnauthedPerSource > 0 {
			if s.unauthedFrom[source]--; s.unauthedFrom[source] <= 0 {
				delete(s.unauthedFrom, source)
			}
		}
		s.mu.Unlock()
	}
	defer release()

	configureSocket(conn)
	conn.SetDeadline(time.Now().Add(s.limits.RequestTimeout))

	var prefix [5]byte
	if _, err := io.ReadFull(conn, prefix[:]); err != nil || string(prefix[:4]) != magic {
		return
	}
	relayID, member := s.store.Identity()
	nonce := base64.StdEncoding.EncodeToString(randomBytes(32))
	hello := helloFrame{Relay: "uterm-relay", Version: protocolVersion, RelayID: relayID, Nonce: nonce}
	if err := writeFrame(conn, hello); err != nil {
		return
	}
	if prefix[4] != protocolVersion {
		writeFrame(conn, answerFrame{Reason: reasonVersion})
		return
	}
	// Buffered only until the request is out of the way: a splice must not lose
	// bytes that were read ahead, so reads stay unbuffered here.
	var request requestFrame
	if err := readFrame(conn, &request); err != nil {
		return
	}

	switch request.Role {
	case roleHost:
		message := signedMessage(roleHost, relayID, nonce, request.HostID)
		if !verifySignature(member, message, request.Sig) {
			writeFrame(conn, answerFrame{Reason: reasonAuth})
			return
		}
		release()
		s.serveHost(conn, request, message)
	case roleClient:
		if !verifySignature(member, signedMessage(roleClient, relayID, nonce, ""), request.Sig) {
			writeFrame(conn, answerFrame{Reason: reasonAuth})
			return
		}
		release()
		s.serveClient(conn)
	case roleDial:
		if !verifySignature(member, signedMessage(roleDial, relayID, nonce, request.HostID), request.Sig) {
			writeFrame(conn, answerFrame{Reason: reasonAuth})
			return
		}
		release()
		s.serveDial(conn, request)
	case roleAccept:
		release()
		s.serveAccept(conn, request, relayID, nonce)
	default:
		writeFrame(conn, answerFrame{Reason: reasonInvalid})
	}
}

func (c *control) send(value any, timeout time.Duration) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	c.conn.SetWriteDeadline(time.Now().Add(timeout))
	err := writeFrame(c.conn, value)
	c.conn.SetWriteDeadline(time.Time{})
	return err
}

func (s *Server) serveHost(conn net.Conn, request requestFrame, message []byte) {
	if request.HostID == "" || request.HostKey == "" {
		writeFrame(conn, answerFrame{Reason: reasonInvalid})
		return
	}
	hostKey, err := parsePublicKey(request.HostKey)
	if err != nil || !verifySignature(hostKey, message, request.HostSig) {
		writeFrame(conn, answerFrame{Reason: reasonHostKey})
		return
	}
	// Checked before binding as well: a registration refused as full must not
	// leave a binding behind, or a member could fill hosts.json without ever
	// holding a place online. The check that counts is the one at the insert below.
	if s.hostsFull(request.HostID) {
		writeFrame(conn, answerFrame{Reason: reasonFull})
		return
	}
	bound, err := s.store.BindHost(request.HostID, request.HostKey, s.limits.Bindings)
	switch {
	case errors.Is(err, errBindingsFull):
		writeFrame(conn, answerFrame{Reason: reasonFull})
		return
	case err != nil:
		log.Printf("uterm-relay: saving host binding: %v", err)
		writeFrame(conn, answerFrame{Reason: reasonFull})
		return
	case !bound:
		writeFrame(conn, answerFrame{Reason: reasonHostKey})
		return
	}

	host := &control{conn: conn, hostID: request.HostID, hostKey: request.HostKey, tickets: map[string]struct{}{}}
	// The capacity check and the insert share one critical section, or concurrent registrations could
	// all pass the check before any of them is counted.
	s.mu.Lock()
	previous := s.hosts[request.HostID]
	if s.hostsFullLocked(request.HostID) {
		s.mu.Unlock()
		writeFrame(conn, answerFrame{Reason: reasonFull})
		return
	}
	s.hosts[request.HostID] = host
	s.mu.Unlock()
	if previous != nil {
		previous.send(messageFrame{Type: "superseded"}, s.limits.WriteTimeout)
		previous.conn.Close()
	}
	defer s.removeHost(host)

	conn.SetDeadline(time.Time{})
	if err := host.send(answerFrame{OK: true}, s.limits.WriteTimeout); err != nil {
		return
	}
	reader := bufio.NewReader(conn)
	for {
		conn.SetReadDeadline(time.Now().Add(s.limits.HostSilence))
		var frame messageFrame
		if err := readFrame(reader, &frame); err != nil {
			return
		}
		switch frame.Type {
		case "ping":
			if host.send(messageFrame{Type: "pong"}, s.limits.WriteTimeout) != nil {
				return
			}
		case "pong":
		case "signal":
			s.mu.Lock()
			client := s.sessions[frame.Session]
			s.mu.Unlock()
			if client != nil {
				client.send(messageFrame{Type: "signal", Session: frame.Session, Box: frame.Box}, s.limits.WriteTimeout)
			}
		}
	}
}

func (s *Server) hostsFull(hostID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.hostsFullLocked(hostID)
}

// hostsFullLocked reports whether hostID would need a new place online and none is left.
func (s *Server) hostsFullLocked(hostID string) bool {
	_, online := s.hosts[hostID]
	return !online && len(s.hosts) >= s.limits.Hosts
}

func (s *Server) removeHost(host *control) {
	s.mu.Lock()
	if s.hosts[host.hostID] == host {
		delete(s.hosts, host.hostID)
	}
	var pending []*pendingDial
	for ticket := range host.tickets {
		if dial := s.tickets[ticket]; dial != nil {
			pending = append(pending, dial)
		}
	}
	s.mu.Unlock()
	for _, dial := range pending {
		s.cancelTicket(dial)
	}
}

func (s *Server) serveClient(conn net.Conn) {
	client := &control{conn: conn, sessions: map[string]struct{}{}}
	s.mu.Lock()
	if len(s.clients) >= s.limits.Controls {
		s.mu.Unlock()
		writeFrame(conn, answerFrame{Reason: reasonFull})
		return
	}
	s.clients[client] = struct{}{}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.clients, client)
		for session := range client.sessions {
			if s.sessions[session] == client {
				delete(s.sessions, session)
			}
		}
		s.mu.Unlock()
	}()

	conn.SetDeadline(time.Time{})
	if err := client.send(answerFrame{OK: true}, s.limits.WriteTimeout); err != nil {
		return
	}
	reader := bufio.NewReader(conn)
	for {
		conn.SetReadDeadline(time.Now().Add(s.limits.ClientSilence))
		var frame messageFrame
		if err := readFrame(reader, &frame); err != nil {
			return
		}
		switch frame.Type {
		case "ping":
			if client.send(messageFrame{Type: "pong"}, s.limits.WriteTimeout) != nil {
				return
			}
		case "list":
			s.mu.Lock()
			hosts := s.onlineHostsLocked()
			s.mu.Unlock()
			if client.send(messageFrame{Type: "hosts", Hosts: hosts}, s.limits.WriteTimeout) != nil {
				return
			}
		case "signal":
			if frame.Session == "" {
				return
			}
			s.mu.Lock()
			// A session belongs to the phone that opened it, so another member
			// can't read a Mac's replies by reusing its id.
			owner, taken := s.sessions[frame.Session]
			if taken && owner != client {
				s.mu.Unlock()
				continue
			}
			if !taken && len(client.sessions) >= 64 {
				s.mu.Unlock()
				continue
			}
			s.sessions[frame.Session] = client
			client.sessions[frame.Session] = struct{}{}
			host := s.hosts[frame.To]
			s.mu.Unlock()
			if host == nil || host.send(messageFrame{Type: "signal", Session: frame.Session, From: frame.From, Box: frame.Box},
				s.limits.WriteTimeout) != nil {
				client.send(messageFrame{Type: "undeliverable", Session: frame.Session}, s.limits.WriteTimeout)
			}
		}
	}
}

// serveDial parks a phone until its Mac calls back, then splices the two.
func (s *Server) serveDial(conn net.Conn, request requestFrame) {
	ticket := base64.RawURLEncoding.EncodeToString(randomBytes(16))
	dial := &pendingDial{ticket: ticket, client: conn, ready: make(chan net.Conn, 1)}
	s.mu.Lock()
	host := s.hosts[request.HostID]
	switch {
	case host == nil:
		s.mu.Unlock()
		writeFrame(conn, answerFrame{Reason: reasonOffline})
		return
	case len(host.tickets) >= s.limits.TicketsPerHost, s.splices >= s.limits.Splices:
		s.mu.Unlock()
		writeFrame(conn, answerFrame{Reason: reasonFull})
		return
	}
	dial.host = host
	s.splices++
	s.tickets[ticket] = dial
	host.tickets[ticket] = struct{}{}
	dial.timer = time.AfterFunc(s.limits.TicketLife, func() { s.cancelTicket(dial) })
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.splices--
		s.mu.Unlock()
	}()
	defer s.cancelTicket(dial)

	conn.SetDeadline(time.Time{})
	if host.send(messageFrame{Type: "incoming", Session: request.Session, Ticket: ticket}, s.limits.WriteTimeout) != nil {
		return
	}

	// Notice the phone leaving while it waits. A well-behaved phone sends nothing
	// until `ok`, so a byte here is a protocol error too.
	gone := make(chan struct{})
	stopWatch := make(chan struct{})
	watcherDone := make(chan struct{})
	go func() {
		defer close(watcherDone)
		var probe [1]byte
		for {
			conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			_, err := conn.Read(probe[:])
			select {
			case <-stopWatch:
				return
			default:
			}
			var timeout net.Error
			if err == nil || !errors.As(err, &timeout) || !timeout.Timeout() {
				close(gone)
				return
			}
		}
	}()

	var leg net.Conn
	select {
	case leg = <-dial.ready:
	case <-gone:
		close(stopWatch)
		<-watcherDone
		// Too late to cancel means the Mac already claimed the ticket: its leg is
		// on the way, and its goroutine waits until that leg is closed.
		if !s.cancelTicket(dial) {
			if late := <-dial.ready; late != nil {
				late.Close()
			}
		}
		return
	}
	close(stopWatch)
	<-watcherDone
	if leg == nil {
		writeFrame(conn, answerFrame{Reason: reasonTicket})
		return
	}
	defer leg.Close()
	conn.SetDeadline(time.Time{})
	conn.SetWriteDeadline(time.Now().Add(s.limits.WriteTimeout))
	if writeFrame(conn, answerFrame{OK: true}) != nil {
		return
	}
	conn.SetWriteDeadline(time.Time{})
	splice(conn, leg)
}

// cancelTicket forgets a ticket and wakes the dial waiting on it. It reports
// whether this call was the one that ended the ticket. Safe to call repeatedly.
func (s *Server) cancelTicket(dial *pendingDial) bool {
	s.mu.Lock()
	_, live := s.tickets[dial.ticket]
	delete(s.tickets, dial.ticket)
	if dial.host != nil {
		delete(dial.host.tickets, dial.ticket)
	}
	s.mu.Unlock()
	if !live {
		return false
	}
	if dial.timer != nil {
		dial.timer.Stop()
	}
	dial.ready <- nil
	return true
}

func (s *Server) serveAccept(conn net.Conn, request requestFrame, relayID, nonce string) {
	s.mu.Lock()
	dial := s.tickets[request.Ticket]
	s.mu.Unlock()
	if dial == nil {
		writeFrame(conn, answerFrame{Reason: reasonTicket})
		return
	}
	hostKey, err := parsePublicKey(dial.host.hostKey)
	if err != nil || !verifySignature(hostKey, signedMessage(roleAccept, relayID, nonce, request.Ticket), request.HostSig) {
		writeFrame(conn, answerFrame{Reason: reasonHostKey})
		return
	}
	s.mu.Lock()
	_, live := s.tickets[request.Ticket]
	delete(s.tickets, request.Ticket)
	delete(dial.host.tickets, request.Ticket)
	s.mu.Unlock()
	if !live {
		writeFrame(conn, answerFrame{Reason: reasonTicket})
		return
	}
	dial.timer.Stop()
	conn.SetDeadline(time.Time{})
	conn.SetWriteDeadline(time.Now().Add(s.limits.WriteTimeout))
	if writeFrame(conn, answerFrame{OK: true}) != nil {
		dial.ready <- nil
		return
	}
	conn.SetWriteDeadline(time.Time{})

	// The dial owns the splice from here. This goroutine has to keep the socket
	// registered, so it waits until the splice has ended and closed the leg.
	done := make(chan struct{})
	dial.ready <- &notifyingConn{Conn: conn, closed: done}
	<-done
}

// notifyingConn reports when the splice closes it.
type notifyingConn struct {
	net.Conn
	closed chan struct{}
	once   sync.Once
}

func (c *notifyingConn) Close() error {
	c.once.Do(func() { close(c.closed) })
	return c.Conn.Close()
}

// splice copies both ways until either side ends, then closes both. Each copy
// writes before it reads again, so a slow reader slows the writer instead of
// filling memory here.
func splice(first, second net.Conn) {
	done := make(chan struct{}, 2)
	copyOne := func(to, from net.Conn) {
		buffer := make([]byte, 32*1024)
		io.CopyBuffer(onlyWriter{to}, onlyReader{from}, buffer)
		done <- struct{}{}
	}
	go copyOne(first, second)
	go copyOne(second, first)
	<-done
	first.Close()
	second.Close()
	<-done
}

type onlyReader struct{ io.Reader }
type onlyWriter struct{ io.Writer }

type rateLimiter struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	seen   map[netip.Addr][]time.Time
	swept  time.Time
}

func newRateLimiter(limit int, window time.Duration) *rateLimiter {
	return &rateLimiter{limit: limit, window: window, seen: map[netip.Addr][]time.Time{}}
}

func (r *rateLimiter) allow(address netip.Addr, now time.Time) bool {
	if r.limit <= 0 {
		return true
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	cutoff := now.Add(-r.window)
	recent := r.seen[address]
	for len(recent) > 0 && recent[0].Before(cutoff) {
		recent = recent[1:]
	}
	if len(recent) >= r.limit {
		r.seen[address] = recent
		return false
	}
	r.seen[address] = append(recent, now)
	if now.Sub(r.swept) > r.window {
		r.swept = now
		for key, times := range r.seen {
			if len(times) == 0 || times[len(times)-1].Before(cutoff) {
				delete(r.seen, key)
			}
		}
	}
	return true
}
