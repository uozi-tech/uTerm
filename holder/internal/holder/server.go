package holder

import (
	"bufio"
	"encoding/binary"
	"errors"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

const (
	// 客户端发不出去的输出超过这么多就先不读 PTY，降到下面那条线再读（也用于输入积压）。
	pauseAboveBytes  = 1 << 20
	resumeBelowBytes = 256 << 10
	// 一次往客户端写这么多。配合写超时判断「对端一点都没在收」。
	clientWriteChunk = 32 << 10
	// 往 PTY 一次写这么多：前台程序不读 stdin 时，卡在写上的最多就是这一块。
	inputWriteChunk = 4096
)

// Config 是一个会话的参数。
type Config struct {
	// socket 路径。长度受 sun_path 限制，调用方可以先切进目录再给相对路径。
	SocketPath string
	Cols, Rows uint16
	// shell 的可执行文件、argv（Args[0] 是 argv0）、环境和工作目录。
	Shell   string
	Args    []string
	Env     []string
	WorkDir string

	// 以下留空用默认值，测试里调小。
	LogCapacity int
	// 接着的客户端这么久一个字节都收不下：它那头的连接多半已经死了（手机被挂起、断网）。
	// 断开它，shell 接着跑，不能让一条死连接把输出堵住。
	ClientStallTimeout time.Duration
	// 输入积压这么久纹丝不动：前台程序不读 stdin，积压的丢掉。
	InputStallTimeout time.Duration
	// shell 在没人接着时退出：留着最后一屏等客户端回来，但不能永远等。
	ExitedLinger time.Duration
	// 结束会话时先发 SIGHUP，过这么久还没退出再发 SIGKILL。
	KillGrace time.Duration
}

func (c *Config) applyDefaults() {
	if c.LogCapacity == 0 {
		c.LogCapacity = defaultLogCapacity
	}
	if c.ClientStallTimeout == 0 {
		c.ClientStallTimeout = 10 * time.Second
	}
	if c.InputStallTimeout == 0 {
		c.InputStallTimeout = 10 * time.Second
	}
	if c.ExitedLinger == 0 {
		c.ExitedLinger = 24 * time.Hour
	}
	if c.KillGrace == 0 {
		c.KillGrace = 3 * time.Second
	}
}

// Server 是一个会话的全部状态。
//
// 这里故意不懂终端：不解析字节，检查点对它也只是一块不透明的数据。终端解析器在 App 里，经常变；
// 保持进程不跟它绑在一起，升级 App 才不用碰服务器上正在跑的会话。
type Server struct {
	config Config

	mu   sync.Mutex
	cond *sync.Cond

	listener  *net.UnixListener
	master    *os.File
	shellPID  int
	createdAt uint64
	cols      uint16
	rows      uint16

	log        *OutputLog
	checkpoint *Checkpoint
	attributes []byte

	pendingInput      []byte
	inputWrittenTotal uint64
	inputStallArmed   bool

	exitStatus    *int32
	masterClosed  bool
	finished      bool
	terminating   bool
	socketRemoved bool
	hasQuit       bool
	done          chan struct{}

	clients  map[*client]struct{}
	attached *client
}

// 一条客户端连接。字段都在 Server.mu 下读写。
type client struct {
	conn  *net.UnixConn
	queue []byte
	// 排着队和正在写的字节数。
	queued  int
	closing bool
	closed  bool
	// 已经告诉这个客户端 shell 退出了。
	sawExit bool
}

func NewServer(config Config) *Server {
	config.applyDefaults()
	server := &Server{
		config:    config,
		cols:      config.Cols,
		rows:      config.Rows,
		createdAt: uint64(time.Now().Unix()),
		log:       NewOutputLog(config.LogCapacity),
		done:      make(chan struct{}),
		clients:   map[*client]struct{}{},
	}
	server.cond = sync.NewCond(&server.mu)
	return server
}

// Start 开始监听并起 shell。先监听再起 shell：连得上就说明 shell 已经起来了。
func (s *Server) Start() error {
	// 走到这里说明没人在这个路径上监听，留下的文件是上一个进程的残骸。
	_ = os.Remove(s.config.SocketPath)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: s.config.SocketPath, Net: "unix"})
	if err != nil {
		return err
	}
	// 文件由 removeSocket 删，而且只删一次：删掉之后这个名字可能已经属于新的会话。
	listener.SetUnlinkOnClose(false)
	_ = os.Chmod(s.config.SocketPath, 0o600)
	s.listener = listener
	if err := s.spawnShell(); err != nil {
		listener.Close()
		_ = os.Remove(s.config.SocketPath)
		return err
	}
	go s.acceptLoop()
	go s.outputReader()
	go s.inputWriter()
	return nil
}

// Done 在会话结束（shell 退出并交代完，或被结束）时关闭。
func (s *Server) Done() <-chan struct{} { return s.done }

// Terminate 结束会话：shell 连同它的进程组。
func (s *Server) Terminate() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.terminateLocked()
}

func (s *Server) spawnShell() error {
	master, slavePath, err := openPTY()
	if err != nil {
		return err
	}
	slave, err := os.OpenFile(slavePath, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		master.Close()
		return err
	}
	defer slave.Close()
	// 从端打开之后再设尺寸：macOS 上从端第一次打开会把之前设的尺寸清掉。
	_ = setWindowSize(master, s.cols, s.rows)
	command := &exec.Cmd{
		Path:   s.config.Shell,
		Args:   s.config.Args,
		Env:    append(append([]string(nil), s.config.Env...), "SSH_TTY="+slavePath),
		Dir:    s.config.WorkDir,
		Stdin:  slave,
		Stdout: slave,
		Stderr: slave,
		// 新会话 + 把 PTY 设成控制终端（Ctty 是子进程里的 fd 号）。
		SysProcAttr: &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0},
	}
	if err := command.Start(); err != nil {
		master.Close()
		return err
	}
	s.master = master
	s.shellPID = command.Process.Pid
	go s.waitForExit(command)
	return nil
}

func (s *Server) waitForExit(command *exec.Cmd) {
	_ = command.Wait()
	var status int32
	if state := command.ProcessState; state != nil {
		if wait, ok := state.Sys().(syscall.WaitStatus); ok {
			status = int32(wait)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.exitStatus = &status
	// shell 退出前写的字节还在内核里，读完才算最后一屏。后台进程还攥着从端时主端读不到结束，所以限时。
	_ = s.master.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	s.finishIfDoneLocked()
}

// MARK: - 连接

func (s *Server) acceptLoop() {
	for {
		conn, err := s.listener.AcceptUnix()
		if err != nil {
			return
		}
		if !peerIsSameUser(conn) {
			conn.Close()
			continue
		}
		c := &client{conn: conn}
		s.mu.Lock()
		if s.hasQuit {
			s.mu.Unlock()
			conn.Close()
			return
		}
		s.clients[c] = struct{}{}
		s.mu.Unlock()
		go s.clientReader(c)
		go s.clientWriter(c)
	}
}

func (s *Server) clientReader(c *client) {
	reader := bufio.NewReaderSize(c.conn, 64<<10)
	for {
		frame, err := ReadFrame(reader)
		s.mu.Lock()
		if err != nil {
			s.closeClientLocked(c)
			s.mu.Unlock()
			return
		}
		s.handleLocked(frame, c)
		s.mu.Unlock()
	}
}

func (s *Server) clientWriter(c *client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		for len(c.queue) == 0 && !c.closing && !c.closed {
			s.cond.Wait()
		}
		if c.closed || len(c.queue) == 0 {
			break
		}
		count := min(len(c.queue), clientWriteChunk)
		chunk := c.queue[:count]
		c.queue = c.queue[count:]
		if len(c.queue) == 0 {
			c.queue = nil
		}
		s.mu.Unlock()
		_ = c.conn.SetWriteDeadline(time.Now().Add(s.config.ClientStallTimeout))
		_, err := c.conn.Write(chunk)
		s.mu.Lock()
		c.queued -= count
		s.cond.Broadcast()
		if err != nil {
			break
		}
	}
	s.closeClientLocked(c)
}

func (s *Server) sendLocked(c *client, kind Kind, payload []byte) {
	if c.closed || c.closing {
		return
	}
	before := len(c.queue)
	c.queue = AppendFrame(c.queue, kind, payload)
	c.queued += len(c.queue) - before
	s.cond.Broadcast()
}

func (s *Server) closeAfterFlushLocked(c *client) {
	if c.closed || c.closing {
		return
	}
	c.closing = true
	s.cond.Broadcast()
	// 对端不读也不能一直挂着。
	time.AfterFunc(5*time.Second, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.closeClientLocked(c)
	})
}

func (s *Server) closeClientLocked(c *client) {
	if c.closed {
		return
	}
	c.closed = true
	c.conn.Close()
	delete(s.clients, c)
	if s.attached == c {
		// 没人看了也要继续读：不读 shell 就会卡在写输出上。outputReader 被 Broadcast 叫醒后接着读。
		s.attached = nil
	}
	s.cond.Broadcast()
	// 最后一屏已经交出去了，这个进程没有别的用处了。
	if c.sawExit {
		s.quitLocked()
	}
}

// MARK: - 帧

func (s *Server) handleLocked(frame Frame, c *client) {
	// 不认识的帧忽略：新版 App 可能连着旧的保持进程。
	switch frame.Kind {
	case KindHello:
		s.sendLocked(c, KindHelloReply, HelloReply{
			Version: ProtocolVersion, ShellPID: int32(s.shellPID), CreatedAt: s.createdAt,
			Cols: s.cols, Rows: s.rows, ExitStatus: s.exitStatus, Attributes: s.attributes,
		}.Encode())
	case KindAttach:
		s.attachLocked(c, frame.Payload)
	case KindInput:
		if c == s.attached {
			s.queueInputLocked(c, frame.Payload)
		}
	case KindResize:
		if cols, rows, ok := decodeGridSize(frame.Payload); ok && c == s.attached {
			s.resizeLocked(cols, rows)
		}
	case KindCheckpoint:
		if received, ok := DecodeCheckpoint(frame.Payload); ok && c == s.attached {
			received.HasGap = false
			s.checkpoint = &received
		}
	case KindSetAttributes:
		s.attributes = frame.Payload
	case KindTerminate:
		s.terminateLocked()
	case KindRedraw:
		if c == s.attached && !s.masterClosed {
			if group := foregroundProcessGroup(s.master); group > 0 {
				_ = syscall.Kill(-group, syscall.SIGWINCH)
			}
		}
	}
}

// 接入：把这个客户端不在期间的东西补给它，之后的输出接着流。同一时刻只有一个客户端。
func (s *Server) attachLocked(c *client, payload []byte) {
	if previous := s.attached; previous != nil && previous != c {
		s.sendLocked(previous, KindReplaced, nil)
		s.closeAfterFlushLocked(previous)
	}
	s.attached = c
	reply := Checkpoint{Cols: s.cols, Rows: s.rows}
	if offset, ok := decodeAttachOffset(payload); ok {
		// 客户端自己留着终端状态，只补它之后的字节。位置比这条流还靠后，说明它手里的不是这个会话的状态。
		reply.Offset = offset
		reply.HasGap = offset > s.log.EndOffset()
	} else if s.checkpoint != nil {
		reply = *s.checkpoint
	}
	if reply.Offset < s.log.StartOffset() {
		reply.HasGap = true
	}
	s.sendLocked(c, KindReplayCheckpoint, reply.Encode())
	position := min(max(reply.Offset, s.log.StartOffset()), s.log.EndOffset())
	for position < s.log.EndOffset() {
		chunk, ok := s.log.Read(position, outputChunkBytes)
		if !ok || len(chunk) == 0 {
			break
		}
		s.sendLocked(c, KindOutput, chunk)
		position += uint64(len(chunk))
	}
	s.sendLocked(c, KindReplayEnd, binary.LittleEndian.AppendUint64(nil, s.log.EndOffset()))
	if s.finished {
		s.sendExitedLocked(c)
	}
}

func (s *Server) sendExitedLocked(c *client) {
	s.sendLocked(c, KindExited, binary.LittleEndian.AppendUint32(nil, uint32(*s.exitStatus)))
	c.sawExit = true
	s.closeAfterFlushLocked(c)
}

// MARK: - PTY

func (s *Server) outputReader() {
	buffer := make([]byte, 64<<10)
	for {
		count, err := s.master.Read(buffer)
		if count > 0 {
			s.mu.Lock()
			s.log.Append(buffer[:count])
			if c := s.attached; c != nil {
				s.sendLocked(c, KindOutput, buffer[:count])
				if c.queued > pauseAboveBytes {
					// 背压：客户端收得慢就让 shell 等一等。它彻底不收时 clientWriter 的写超时会断开它。
					for s.attached == c && !c.closed && c.queued >= resumeBelowBytes {
						s.cond.Wait()
					}
				}
			}
			s.mu.Unlock()
		}
		if err != nil {
			break
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.masterClosed = true
	// 关掉主端之后，还攥着从端的后台进程才会收到 SIGHUP。
	s.master.Close()
	s.pendingInput = nil
	s.cond.Broadcast()
	s.finishIfDoneLocked()
}

// 输入先排队，由 inputWriter 写进 PTY：主端一次只收几 KB，大段粘贴不能丢尾巴，
// 也不能让读这个客户端的 goroutine 卡在写上。
func (s *Server) queueInputLocked(c *client, data []byte) {
	if s.masterClosed {
		return
	}
	s.pendingInput = append(s.pendingInput, data...)
	s.cond.Broadcast()
	if len(s.pendingInput) <= pauseAboveBytes {
		return
	}
	// 积压太多：先不读这个客户端的后续帧。前台程序一直不读 stdin 的话，后面的帧（关标签时的 terminate、
	// 改尺寸）永远轮不到，所以积压一段时间纹丝不动就丢掉它。
	s.armInputStallCheckLocked()
	for len(s.pendingInput) >= resumeBelowBytes && !s.masterClosed && !c.closed {
		s.cond.Wait()
	}
}

func (s *Server) armInputStallCheckLocked() {
	if s.inputStallArmed {
		return
	}
	s.inputStallArmed = true
	mark := s.inputWrittenTotal
	time.AfterFunc(s.config.InputStallTimeout, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.inputStallArmed = false
		if len(s.pendingInput) < resumeBelowBytes {
			return
		}
		if s.inputWrittenTotal == mark {
			s.pendingInput = nil
			s.cond.Broadcast()
		} else {
			s.armInputStallCheckLocked()
		}
	})
}

func (s *Server) inputWriter() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		for len(s.pendingInput) == 0 && !s.masterClosed {
			s.cond.Wait()
		}
		if s.masterClosed {
			return
		}
		count := min(len(s.pendingInput), inputWriteChunk)
		chunk := append([]byte(nil), s.pendingInput[:count]...)
		s.pendingInput = s.pendingInput[count:]
		if len(s.pendingInput) == 0 {
			s.pendingInput = nil
		}
		s.mu.Unlock()
		written, err := s.master.Write(chunk)
		s.mu.Lock()
		s.inputWrittenTotal += uint64(written)
		s.cond.Broadcast()
		if err != nil {
			// EIO 等：shell 已经没了，退出路径会处理。
			s.pendingInput = nil
			return
		}
	}
}

func (s *Server) resizeLocked(cols, rows uint16) {
	if cols == 0 || rows == 0 {
		return
	}
	s.cols, s.rows = cols, rows
	if !s.masterClosed {
		_ = setWindowSize(s.master, cols, rows)
	}
}

// MARK: - 结束

func (s *Server) terminateLocked() {
	if s.terminating {
		return
	}
	s.terminating = true
	if s.finished {
		s.quitLocked()
		return
	}
	// 正在退出的会话不再接客。同一个 id 马上再开要得到新的会话，而不是接上一个将死的。
	s.removeSocketLocked()
	s.signalShellLocked(syscall.SIGHUP)
	time.AfterFunc(s.config.KillGrace, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.exitStatus == nil {
			s.signalShellLocked(syscall.SIGKILL)
		}
	})
}

// shell 是会话首进程，进程组号就是它的 pid。
func (s *Server) signalShellLocked(signal syscall.Signal) {
	_ = syscall.Kill(-s.shellPID, signal)
	_ = syscall.Kill(s.shellPID, signal)
}

// shell 退出、最后的输出也读完之后：把退出码交给接着的客户端；没人接着就留着最后一屏等一阵。
func (s *Server) finishIfDoneLocked() {
	if s.finished || s.exitStatus == nil || !s.masterClosed {
		return
	}
	s.finished = true
	switch {
	case s.attached != nil:
		s.sendExitedLocked(s.attached)
	case s.terminating:
		s.quitLocked()
		return
	default:
		time.AfterFunc(s.config.ExitedLinger, s.quit)
	}
	// 结束会话时客户端随后就断开了，别停在这里等它。
	if s.terminating {
		time.AfterFunc(2*time.Second, s.quit)
	}
}

func (s *Server) quit() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.quitLocked()
}

func (s *Server) quitLocked() {
	if s.hasQuit {
		return
	}
	s.hasQuit = true
	s.removeSocketLocked()
	s.listener.Close()
	for c := range s.clients {
		c.closed = true
		c.conn.Close()
	}
	s.clients = map[*client]struct{}{}
	s.attached = nil
	if !s.masterClosed {
		s.master.Close()
	}
	s.cond.Broadcast()
	close(s.done)
}

func (s *Server) removeSocketLocked() {
	if s.socketRemoved {
		return
	}
	s.socketRemoved = true
	_ = os.Remove(s.config.SocketPath)
}

// ErrNoSession：这个路径上没有会话在监听。
var ErrNoSession = errors.New("no such session")

// Dial 连上一个会话。socket 文件在但没人监听（进程已经没了）时顺手删掉残骸。
func Dial(socketPath string) (*net.UnixConn, error) {
	conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err == nil {
		return conn, nil
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		_ = os.Remove(socketPath)
		return nil, ErrNoSession
	}
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNoSession
	}
	return nil, err
}
