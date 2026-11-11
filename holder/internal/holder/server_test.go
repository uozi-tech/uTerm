package holder

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math/rand"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// MARK: - 夹具

// 起一个跑着 `sh -c script` 的会话。socket 放在 /tmp 下的短路径里（macOS 的临时目录太长，超过 sun_path）。
func startSession(t *testing.T, script string, adjust func(*Config)) (server *Server, socketPath, directory string) {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "uh")
	if err != nil {
		t.Fatal(err)
	}
	config := Config{
		SocketPath: filepath.Join(directory, "s.sock"),
		Cols:       80,
		Rows:       24,
		Shell:      "/bin/sh",
		Args:       []string{"sh", "-c", script},
		Env:        append(os.Environ(), "TERM=xterm-256color", "DIR="+directory),
		WorkDir:    directory,
		KillGrace:  300 * time.Millisecond,
	}
	if adjust != nil {
		adjust(&config)
	}
	server = NewServer(config)
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		server.Terminate()
		select {
		case <-server.Done():
		case <-time.After(5 * time.Second):
			t.Error("session did not end after Terminate")
		}
		os.RemoveAll(directory)
	})
	return server, config.SocketPath, directory
}

type testClient struct {
	t      *testing.T
	conn   *net.UnixConn
	frames chan Frame
}

func dialSession(t *testing.T, socketPath string) *testClient {
	t.Helper()
	conn, err := Dial(socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	c := &testClient{t: t, conn: conn, frames: make(chan Frame, 4096)}
	go func() {
		defer close(c.frames)
		for {
			frame, err := ReadFrame(conn)
			if err != nil {
				return
			}
			c.frames <- frame
		}
	}()
	t.Cleanup(func() { conn.Close() })
	return c
}

func (c *testClient) send(kind Kind, payload []byte) {
	c.t.Helper()
	if _, err := c.conn.Write(AppendFrame(nil, kind, payload)); err != nil {
		c.t.Fatalf("send %d: %v", kind, err)
	}
}

// 下一帧。连接关了返回 ok=false。
func (c *testClient) next() (Frame, bool) {
	c.t.Helper()
	select {
	case frame, ok := <-c.frames:
		return frame, ok
	case <-time.After(10 * time.Second):
		c.t.Fatal("timed out waiting for a frame")
		return Frame{}, false
	}
}

func (c *testClient) expect(kind Kind) Frame {
	c.t.Helper()
	frame, ok := c.next()
	if !ok || frame.Kind != kind {
		c.t.Fatalf("want frame %d, got %d (open=%v)", kind, frame.Kind, ok)
	}
	return frame
}

// 接入并收完回放：检查点、回放的字节、回放结束时的流位置。
func (c *testClient) attach(payload []byte) (checkpoint Checkpoint, replay []byte, end uint64) {
	c.t.Helper()
	c.send(KindAttach, payload)
	checkpoint, ok := DecodeCheckpoint(c.expect(KindReplayCheckpoint).Payload)
	if !ok {
		c.t.Fatal("bad replayCheckpoint")
	}
	for {
		frame, ok := c.next()
		if !ok {
			c.t.Fatal("connection closed during replay")
		}
		switch frame.Kind {
		case KindOutput:
			replay = append(replay, frame.Payload...)
		case KindReplayEnd:
			return checkpoint, replay, binary.LittleEndian.Uint64(frame.Payload)
		default:
			c.t.Fatalf("unexpected frame %d during replay", frame.Kind)
		}
	}
}

// 接着收输出，直到攒下的内容满足条件。
func (c *testClient) outputUntil(collected []byte, done func([]byte) bool) []byte {
	c.t.Helper()
	for !done(collected) {
		frame, ok := c.next()
		if !ok {
			c.t.Fatalf("connection closed; collected %q", tail(collected))
		}
		if frame.Kind == KindOutput {
			collected = append(collected, frame.Payload...)
		}
	}
	return collected
}

func tail(data []byte) []byte {
	if len(data) > 200 {
		return data[len(data)-200:]
	}
	return data
}

func contains(text string) func([]byte) bool {
	return func(data []byte) bool { return bytes.Contains(data, []byte(text)) }
}

func waitDone(t *testing.T, server *Server) {
	t.Helper()
	select {
	case <-server.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("session did not end")
	}
}

func waitFor(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// MARK: - 接入与回放

func TestAttachReplaysEarlierOutputThenStreams(t *testing.T) {
	_, socket, _ := startSession(t, `printf 'before\n'; read line; printf 'after:%s\n' "$line"; sleep 30`, nil)
	first := dialSession(t, socket)
	_, replay, _ := first.attach(nil)
	first.outputUntil(replay, contains("before"))
	first.conn.Close()

	// 断开期间的输出要补回来。
	second := dialSession(t, socket)
	checkpoint, replay, end := second.attach(nil)
	if checkpoint.Offset != 0 || checkpoint.HasGap || len(checkpoint.Blob) != 0 {
		t.Fatalf("checkpoint %+v", checkpoint)
	}
	if !bytes.Contains(replay, []byte("before")) || end != uint64(len(replay)) {
		t.Fatalf("replay %q, end %d", replay, end)
	}
	second.send(KindInput, []byte("hi\n"))
	second.outputUntil(nil, contains("after:hi"))
}

// 核心性质：不管在哪个字节断开，按「已经收到的位置」接回，拼起来的流和 PTY 写出的逐字节相同，
// 不丢、不重。画面还原靠它（客户端的终端状态 + 这之后的字节）。
func TestReattachFromOffsetIsByteExactAtRandomCutPoints(t *testing.T) {
	const lines = 30000
	script := fmt.Sprintf(`stty -echo; i=0; while [ $i -lt %d ]; do printf 'line %%06d abcdefghij\n' $i; i=$((i+1)); done; sleep 30`, lines)
	_, socket, _ := startSession(t, script, nil)

	var want bytes.Buffer
	for i := 0; i < lines; i++ {
		fmt.Fprintf(&want, "line %06d abcdefghij\r\n", i)
	}

	random := rand.New(rand.NewSource(7))
	var got []byte
	cuts := 0
	for len(got) < want.Len() {
		client := dialSession(t, socket)
		client.send(KindAttach, EncodeAttachFromOffset(uint64(len(got))))
		checkpoint, ok := DecodeCheckpoint(client.expect(KindReplayCheckpoint).Payload)
		if !ok || checkpoint.Offset != uint64(len(got)) || checkpoint.HasGap || len(checkpoint.Blob) != 0 {
			t.Fatalf("cut %d: checkpoint %+v", cuts, checkpoint)
		}
		// 这一轮只「处理」budget 个字节就断开，哪怕停在一帧的中间。
		budget := 1 + random.Intn(40000)
		for budget > 0 && len(got) < want.Len() {
			frame, ok := client.next()
			if !ok {
				t.Fatalf("cut %d: connection closed at %d", cuts, len(got))
			}
			if frame.Kind != KindOutput {
				continue
			}
			take := min(budget, len(frame.Payload))
			got = append(got, frame.Payload[:take]...)
			budget -= take
		}
		client.conn.Close()
		cuts++
	}
	if !bytes.Equal(got, want.Bytes()) {
		at := 0
		for at < len(got) && at < want.Len() && got[at] == want.Bytes()[at] {
			at++
		}
		t.Fatalf("stream differs at byte %d of %d after %d cuts", at, want.Len(), cuts)
	}
	if cuts < 20 {
		t.Fatalf("only %d cuts; the test is not exercising reattach", cuts)
	}
	t.Logf("%d bytes reassembled across %d reattaches", len(got), cuts)
}

func TestStoredCheckpointComesBackOnPlainAttach(t *testing.T) {
	_, socket, _ := startSession(t, `stty -echo; printf '0123456789'; read line; printf 'tail'; sleep 30`, nil)
	first := dialSession(t, socket)
	_, replay, _ := first.attach(nil)
	first.outputUntil(replay, contains("0123456789"))
	first.send(KindCheckpoint, Checkpoint{Offset: 4, Cols: 100, Rows: 30, HasGap: true, Blob: []byte("STATE")}.Encode())
	first.send(KindSetAttributes, []byte("owner"))
	first.send(KindInput, []byte("\n"))
	first.outputUntil(nil, contains("tail"))
	first.conn.Close()

	// 手里什么都没有的客户端（App 被杀过、换了设备）：拿回检查点和它之后的字节。
	second := dialSession(t, socket)
	second.send(KindHello, nil)
	hello, ok := DecodeHelloReply(second.expect(KindHelloReply).Payload)
	if !ok || string(hello.Attributes) != "owner" || hello.ExitStatus != nil || hello.Version != ProtocolVersion {
		t.Fatalf("hello %+v", hello)
	}
	checkpoint, replay, end := second.attach(nil)
	if checkpoint.Offset != 4 || checkpoint.Cols != 100 || checkpoint.Rows != 30 || string(checkpoint.Blob) != "STATE" {
		t.Fatalf("checkpoint %+v", checkpoint)
	}
	// 上传时带的 hasGap 不算数：有没有缺口由保持进程按缓冲范围判断。
	if checkpoint.HasGap {
		t.Fatal("gap flag from the client was kept")
	}
	if string(replay) != "456789tail" || end != 14 {
		t.Fatalf("replay %q end %d", replay, end)
	}

	// 自己留着状态的客户端：不带检查点内容，只补字节。
	third := dialSession(t, socket)
	checkpoint, replay, _ = third.attach(EncodeAttachFromOffset(12))
	if checkpoint.Offset != 12 || len(checkpoint.Blob) != 0 || checkpoint.HasGap || string(replay) != "il" {
		t.Fatalf("checkpoint %+v replay %q", checkpoint, replay)
	}
}

func TestGapIsReportedWhenTheBufferOverflowed(t *testing.T) {
	_, socket, _ := startSession(t, `stty -echo; head -c 300000 /dev/zero | tr '\0' 'x'; printf 'END'; sleep 30`,
		func(config *Config) { config.LogCapacity = 64 << 10 })
	probe := dialSession(t, socket)
	_, replay, _ := probe.attach(nil)
	probe.outputUntil(replay, contains("END"))
	probe.conn.Close()

	client := dialSession(t, socket)
	checkpoint, replay, end := client.attach(EncodeAttachFromOffset(1000))
	if !checkpoint.HasGap || checkpoint.Offset != 1000 {
		t.Fatalf("checkpoint %+v", checkpoint)
	}
	if end != 300003 || len(replay) != 64<<10 || !bytes.HasSuffix(replay, []byte("xEND")) {
		t.Fatalf("end %d, replay %d bytes, tail %q", end, len(replay), tail(replay)[190:])
	}

	// 位置比这条流还靠后：客户端手里的不是这个会话的状态。
	stranger := dialSession(t, socket)
	checkpoint, replay, _ = stranger.attach(EncodeAttachFromOffset(999_999_999))
	if !checkpoint.HasGap || len(replay) != 0 {
		t.Fatalf("checkpoint %+v, replay %d bytes", checkpoint, len(replay))
	}
}

func TestSecondClientReplacesTheFirst(t *testing.T) {
	_, socket, _ := startSession(t, `stty -echo; cat`, nil)
	first := dialSession(t, socket)
	first.attach(nil)
	second := dialSession(t, socket)
	second.attach(nil)

	first.expect(KindReplaced)
	if _, open := first.next(); open {
		t.Fatal("replaced client stayed connected")
	}
	// 被换下的客户端再发输入不算数。
	second.send(KindInput, []byte("ping\n"))
	second.outputUntil(nil, contains("ping"))
}

// MARK: - 输入、尺寸

func TestResizeAndRedrawReachTheShell(t *testing.T) {
	// trap 在两条命令之间才跑，所以用短 sleep 轮着。
	_, socket, _ := startSession(t,
		`trap 'echo "winch $(stty size)"' WINCH; stty size; while :; do sleep 0.05; done`, nil)
	client := dialSession(t, socket)
	_, replay, _ := client.attach(nil)
	client.outputUntil(replay, contains("24 80"))

	client.send(KindResize, EncodeGridSize(100, 30))
	output := client.outputUntil(nil, contains("winch 30 100"))

	// 尺寸没变时内核不发 SIGWINCH，redraw 帧补一个。
	client.send(KindRedraw, nil)
	client.outputUntil(output, func(data []byte) bool { return bytes.Count(data, []byte("winch 30 100")) >= 2 })

	client.send(KindHello, nil)
	for {
		frame, _ := client.next()
		if frame.Kind != KindHelloReply {
			continue
		}
		hello, _ := DecodeHelloReply(frame.Payload)
		if hello.Cols != 100 || hello.Rows != 30 {
			t.Fatalf("hello reports %dx%d", hello.Cols, hello.Rows)
		}
		break
	}
}

func TestLargePasteArrivesIntact(t *testing.T) {
	const size = 400_000
	_, socket, directory := startSession(t, `stty raw -echo; head -c 400000 > "$DIR/out"; sleep 30`, nil)
	client := dialSession(t, socket)
	client.attach(nil)
	// stty 生效之前写进去的字节会被行规程改写，等它起来。
	time.Sleep(300 * time.Millisecond)
	payload := bytes.Repeat([]byte("0123456789abcdef"), size/16)
	for sent := 0; sent < size; sent += 50_000 {
		client.send(KindInput, payload[sent:sent+50_000])
	}
	var written []byte
	waitFor(t, "the paste to land", func() bool {
		written, _ = os.ReadFile(filepath.Join(directory, "out"))
		return len(written) == size
	})
	if !bytes.Equal(written, payload) {
		t.Fatal("paste arrived corrupted")
	}
}

// 前台程序不读 stdin 时，积压的输入不能把后面的帧（这里是 terminate）永远挡在外面。
func TestStalledInputDoesNotBlockTerminate(t *testing.T) {
	server, socket, _ := startSession(t, `stty raw -echo; sleep 30`,
		func(config *Config) { config.InputStallTimeout = 300 * time.Millisecond })
	client := dialSession(t, socket)
	client.attach(nil)
	time.Sleep(300 * time.Millisecond)
	go func() {
		chunk := bytes.Repeat([]byte("x"), 64<<10)
		for i := 0; i < 40; i++ {
			if _, err := client.conn.Write(AppendFrame(nil, KindInput, chunk)); err != nil {
				return
			}
		}
		_, _ = client.conn.Write(AppendFrame(nil, KindTerminate, nil))
	}()
	waitDone(t, server)
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatalf("socket still there: %v", err)
	}
}

// MARK: - 客户端那头死了

// 客户端一个字节都不收（手机被挂起、连接半死）：shell 不能被它堵住，过了时限断开它接着跑；
// 之后按位置接回，缓冲里还有的一个字节都不少。
func TestStalledClientIsDroppedAndTheShellKeepsRunning(t *testing.T) {
	const flood = 6_000_000
	_, socket, directory := startSession(t,
		`stty -echo; head -c 6000000 /dev/zero | tr '\0' 'x'; echo done > "$DIR/marker"; printf 'END'; sleep 30`,
		func(config *Config) { config.ClientStallTimeout = 300 * time.Millisecond })

	// 接入后不读。不用 dialSession：它会一直读。
	stalled, err := Dial(socket)
	if err != nil {
		t.Fatal(err)
	}
	defer stalled.Close()
	if _, err := stalled.Write(AppendFrame(nil, KindAttach, nil)); err != nil {
		t.Fatal(err)
	}

	waitFor(t, "the shell to finish its output", func() bool {
		_, err := os.Stat(filepath.Join(directory, "marker"))
		return err == nil
	})

	client := dialSession(t, socket)
	checkpoint, replay, end := client.attach(EncodeAttachFromOffset(0))
	replay = client.outputUntil(replay, func(data []byte) bool { return len(data) >= flood+3 })
	if checkpoint.HasGap || end < flood || !bytes.HasSuffix(replay, []byte("xEND")) || len(replay) != flood+3 {
		t.Fatalf("gap=%v end=%d replay=%d tail=%q", checkpoint.HasGap, end, len(replay), tail(replay)[190:])
	}
	if strings.Trim(string(replay[:flood]), "x") != "" {
		t.Fatal("flood content corrupted")
	}
}

// MARK: - 退出与结束

func TestExitStatusReachesTheAttachedClientAndTheSessionEnds(t *testing.T) {
	server, socket, _ := startSession(t, `stty -echo; read line; printf 'bye'; exit 7`, nil)
	client := dialSession(t, socket)
	client.attach(nil)
	client.send(KindInput, []byte("\n"))
	var output []byte
	for {
		frame, ok := client.next()
		if !ok {
			t.Fatal("closed before exited frame")
		}
		if frame.Kind == KindOutput {
			output = append(output, frame.Payload...)
		}
		if frame.Kind == KindExited {
			status := syscall.WaitStatus(binary.LittleEndian.Uint32(frame.Payload))
			if !status.Exited() || status.ExitStatus() != 7 {
				t.Fatalf("wait status %#x", uint32(status))
			}
			break
		}
	}
	// 退出前写的最后一点输出排在退出帧前面。
	if !bytes.Contains(output, []byte("bye")) {
		t.Fatalf("last output missing: %q", output)
	}
	waitDone(t, server)
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatalf("socket still there: %v", err)
	}
}

// 没人接着时 shell 退出：留着最后一屏，等客户端回来看过再结束。
func TestExitWhileDetachedKeepsTheLastScreenForTheNextClient(t *testing.T) {
	server, socket, _ := startSession(t, `printf 'last words'; exit 3`, nil)
	probe := dialSession(t, socket)
	waitFor(t, "the shell to exit", func() bool {
		probe.send(KindHello, nil)
		hello, _ := DecodeHelloReply(probe.expect(KindHelloReply).Payload)
		return hello.ExitStatus != nil
	})
	select {
	case <-server.Done():
		t.Fatal("session ended before anyone saw the last screen")
	case <-time.After(300 * time.Millisecond):
	}

	client := dialSession(t, socket)
	_, replay, _ := client.attach(nil)
	if !bytes.Contains(replay, []byte("last words")) {
		t.Fatalf("replay %q", replay)
	}
	status := syscall.WaitStatus(binary.LittleEndian.Uint32(client.expect(KindExited).Payload))
	if status.ExitStatus() != 3 {
		t.Fatalf("wait status %#x", uint32(status))
	}
	waitDone(t, server)
}

func TestExitedSessionWithNoVisitorEndsAfterTheLinger(t *testing.T) {
	server, _, _ := startSession(t, `exit 0`, func(config *Config) { config.ExitedLinger = 200 * time.Millisecond })
	waitDone(t, server)
}

func TestTerminateEndsAShellThatIgnoresHangup(t *testing.T) {
	server, socket, directory := startSession(t, `trap '' HUP; echo $$ > "$DIR/pid"; sleep 30 & wait`, nil)
	client := dialSession(t, socket)
	client.attach(nil)
	var pid int
	waitFor(t, "the shell to write its pid", func() bool {
		data, _ := os.ReadFile(filepath.Join(directory, "pid"))
		_, err := fmt.Sscan(string(data), &pid)
		return err == nil
	})
	client.send(KindTerminate, nil)
	// 结束中的会话立刻不再接客：同一个 id 马上重开要得到新的会话。
	waitFor(t, "the socket to go away", func() bool {
		_, err := os.Stat(socket)
		return os.IsNotExist(err)
	})
	waitDone(t, server)
	waitFor(t, "the shell to die", func() bool { return syscall.Kill(pid, 0) == syscall.ESRCH })
}

// 不认识的帧忽略，连接不断：新版 App 可能连着旧的保持进程。
func TestUnknownFramesAreIgnored(t *testing.T) {
	_, socket, _ := startSession(t, `stty -echo; cat`, nil)
	client := dialSession(t, socket)
	client.send(Kind(9), nil)
	client.send(Kind(10), []byte("relay"))
	client.send(Kind(200), []byte("future"))
	client.attach(nil)
	client.send(KindInput, []byte("still here\n"))
	client.outputUntil(nil, contains("still here"))
}

// App 被系统杀掉后没人回来接：过了时限会话自己结束。期间有人接着就不算。
func TestSessionEndsAfterStayingDetachedTooLong(t *testing.T) {
	server, socket, _ := startSession(t, `stty -echo; cat`,
		func(config *Config) { config.DetachedTimeout = 400 * time.Millisecond })

	// 接着的时候不计时。
	client := dialSession(t, socket)
	client.attach(nil)
	select {
	case <-server.Done():
		t.Fatal("session ended while a client was attached")
	case <-time.After(700 * time.Millisecond):
	}
	client.send(KindInput, []byte("alive\n"))
	client.outputUntil(nil, contains("alive"))

	// 断开后重新计：没到时限前接回来，计时作废。
	client.conn.Close()
	time.Sleep(200 * time.Millisecond)
	again := dialSession(t, socket)
	again.attach(nil)
	select {
	case <-server.Done():
		t.Fatal("session ended although a client came back in time")
	case <-time.After(500 * time.Millisecond):
	}

	again.conn.Close()
	waitDone(t, server)
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatalf("socket still there: %v", err)
	}
}

func TestSessionNobodyEverAttachedToEndsAfterTheTimeout(t *testing.T) {
	server, _, _ := startSession(t, `sleep 30`,
		func(config *Config) { config.DetachedTimeout = 300 * time.Millisecond })
	waitDone(t, server)
}
