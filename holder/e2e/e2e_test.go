// 经真实 sshd 的端到端用例：uterm-holder 放在容器里，客户端是本机的 ssh，走 exec 通道。
// 由 scripts/e2e.sh 起容器并设好环境变量；直接 go test 时全部跳过。
package e2e

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"uterm.local/holder/internal/holder"
)

func sshArguments(t *testing.T) []string {
	t.Helper()
	command := os.Getenv("UTERM_HOLDER_E2E_SSH")
	if command == "" {
		t.Skip("需要测试 sshd：用 scripts/e2e.sh 跑")
	}
	return strings.Fields(command)
}

func holderPath() string { return os.Getenv("UTERM_HOLDER_E2E_BIN") }

func newSessionID(t *testing.T) string {
	t.Helper()
	raw := make([]byte, 8)
	if _, err := rand.Read(raw); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(raw)
}

// 在主机上跑一条命令，返回标准输出和退出码。
func remote(t *testing.T, command string) (string, int) {
	t.Helper()
	arguments := append(sshArguments(t), command)
	output, err := exec.Command(arguments[0], arguments[1:]...).Output()
	if exit, ok := err.(*exec.ExitError); ok {
		return string(output), exit.ExitCode()
	}
	if err != nil {
		t.Fatalf("ssh: %v", err)
	}
	return string(output), 0
}

// 一条字节流：本机 ssh 进程的标准输入输出。
type pipe struct {
	t       *testing.T
	command *exec.Cmd
	stdin   io.WriteCloser
	chunks  chan []byte
}

func startPipe(t *testing.T, extraSSHOptions []string, remoteCommand string) *pipe {
	t.Helper()
	arguments := sshArguments(t)
	// 选项要放在主机名前面。
	host := arguments[len(arguments)-1]
	arguments = append(append(arguments[:len(arguments)-1:len(arguments)-1], extraSSHOptions...), host)
	if remoteCommand != "" {
		arguments = append(arguments, remoteCommand)
	}
	command := exec.Command(arguments[0], arguments[1:]...)
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	command.Stderr = os.Stderr
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	p := &pipe{t: t, command: command, stdin: stdin, chunks: make(chan []byte, 1024)}
	go func() {
		defer close(p.chunks)
		for {
			buffer := make([]byte, 64<<10)
			count, err := stdout.Read(buffer)
			if count > 0 {
				p.chunks <- buffer[:count]
			}
			if err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	})
	return p
}

func (p *pipe) write(data []byte) {
	p.t.Helper()
	if _, err := p.stdin.Write(data); err != nil {
		p.t.Fatalf("write: %v", err)
	}
}

func (p *pipe) Read(buffer []byte) (int, error) {
	select {
	case chunk, ok := <-p.chunks:
		if !ok {
			return 0, io.EOF
		}
		if len(chunk) > len(buffer) {
			p.t.Fatal("chunk larger than the read buffer")
		}
		return copy(buffer, chunk), nil
	case <-time.After(30 * time.Second):
		p.t.Fatal("timed out reading from ssh")
		return 0, io.EOF
	}
}

// 突然断开：直接杀掉本机的 ssh，不走任何收尾。
func (p *pipe) kill() {
	_ = p.command.Process.Signal(syscall.SIGKILL)
	_ = p.command.Wait()
}

// 接着一个会话的客户端：exec 通道上跑 `uterm-holder attach`，两头说帧协议。
type session struct {
	*pipe
	frames chan holder.Frame
	// 到目前为止处理过的输出在整条流里的位置。
	offset uint64
}

func attachCommand(id string, create bool) string {
	command := holderPath() + " attach --id " + id
	if create {
		command += " --create --cols 80 --rows 24 --env LANG=C.UTF-8"
	}
	return command
}

func openSession(t *testing.T, id string, create bool, fromOffset uint64) *session {
	t.Helper()
	s := &session{pipe: startPipe(t, nil, attachCommand(id, create)), frames: make(chan holder.Frame, 4096)}
	go func() {
		defer close(s.frames)
		reader := &chunkReader{source: s.pipe}
		for {
			frame, err := holder.ReadFrame(reader)
			if err != nil {
				return
			}
			s.frames <- frame
		}
	}()
	s.send(holder.KindAttach, holder.EncodeAttachFromOffset(fromOffset))
	frame := s.next()
	checkpoint, ok := holder.DecodeCheckpoint(frame.Payload)
	if frame.Kind != holder.KindReplayCheckpoint || !ok || checkpoint.HasGap || checkpoint.Offset != fromOffset {
		t.Fatalf("attach reply: kind %d %+v", frame.Kind, checkpoint)
	}
	s.offset = fromOffset
	return s
}

// io.ReadFull 一次要的可能比一个 chunk 少，剩下的留着。
type chunkReader struct {
	source  *pipe
	pending []byte
}

func (r *chunkReader) Read(buffer []byte) (int, error) {
	if len(r.pending) == 0 {
		chunk, ok := <-r.source.chunks
		if !ok {
			return 0, io.EOF
		}
		r.pending = chunk
	}
	count := copy(buffer, r.pending)
	r.pending = r.pending[count:]
	return count, nil
}

func (s *session) send(kind holder.Kind, payload []byte) {
	s.t.Helper()
	s.write(holder.AppendFrame(nil, kind, payload))
}

func (s *session) next() holder.Frame {
	s.t.Helper()
	select {
	case frame, ok := <-s.frames:
		if !ok {
			s.t.Fatal("session connection closed")
		}
		return frame
	case <-time.After(30 * time.Second):
		s.t.Fatal("timed out waiting for a frame")
		return holder.Frame{}
	}
}

// 收输出直到满足条件，返回这段时间收到的字节。
func (s *session) outputUntil(done func([]byte) bool) []byte {
	s.t.Helper()
	var collected []byte
	for !done(collected) {
		frame := s.next()
		if frame.Kind == holder.KindOutput {
			collected = append(collected, frame.Payload...)
			s.offset += uint64(len(frame.Payload))
		}
	}
	return collected
}

func contains(text string) func([]byte) bool {
	return func(data []byte) bool { return bytes.Contains(data, []byte(text)) }
}

func endSession(t *testing.T, id string) {
	t.Helper()
	remote(t, holderPath()+" kill --id "+id)
}

// MARK: - 用例

// 整件事的核心：ssh 被突然掐断后 shell 还在跑，重新连上按位置接回，断开期间的输出一行不少、一行不重。
func TestSessionSurvivesAbruptDisconnectAndResumesAtOffset(t *testing.T) {
	id := newSessionID(t)
	defer endSession(t, id)

	first := openSession(t, id, true, 0)
	first.send(holder.KindInput, []byte(
		"stty -echo; echo PID=$$; for i in $(seq 1 40); do echo tick$i.; sleep 0.1; done; echo FINISHED\n"))
	stream := first.outputUntil(contains("tick5."))
	offset := first.offset
	first.kill()

	// 断开期间 shell 接着跑（约 2 秒的输出没人收）。
	time.Sleep(2 * time.Second)

	second := openSession(t, id, false, offset)
	stream = append(stream, second.outputUntil(contains("FINISHED"))...)
	for i := 1; i <= 40; i++ {
		if count := bytes.Count(stream, []byte(fmt.Sprintf("tick%d.", i))); count != 1 {
			t.Fatalf("tick%d appears %d times in %q", i, count, stream)
		}
	}
	pid := regexp.MustCompile(`PID=(\d+)`).FindSubmatch(stream)
	if pid == nil {
		t.Fatalf("no pid in %q", stream)
	}
	// 还是同一个 shell。
	second.send(holder.KindInput, []byte("echo AGAIN=$$\n"))
	again := second.outputUntil(contains("AGAIN="))
	if !bytes.Contains(again, []byte("AGAIN="+string(pid[1]))) {
		t.Fatalf("shell changed: was %s, now %q", pid[1], again)
	}
	// 会话进程脱离了 sshd：父进程是 1，不在任何一次登录下面。
	parent, _ := remote(t, "ps -o ppid= -p $(ps -o ppid= -p "+string(pid[1])+")")
	if strings.TrimSpace(parent) != "1" {
		t.Fatalf("session process is parented to %q, want 1", strings.TrimSpace(parent))
	}
}

func TestShellEnvironmentLooksLikeALoginOverSSH(t *testing.T) {
	id := newSessionID(t)
	defer endSession(t, id)
	s := openSession(t, id, true, 0)
	s.send(holder.KindInput, []byte(
		"stty -echo; echo \"T=$TERM L=$LANG H=$HOME U=$USER S=$SHELL D=$PWD\"; tty; echo \"SSH_TTY=$SSH_TTY\"; "+
			"shopt -q login_shell && echo LOGIN; [ -n \"$SSH_CONNECTION\" ] && echo CONN; echo E''ND\n"))
	// 标记在命令里拆开写：回显的命令行里没有它，只有真的输出才有。
	output := string(s.outputUntil(contains("END\r\n")))
	for _, want := range []string{
		"T=xterm-256color L=C.UTF-8 H=/home/dev U=dev S=/bin/bash D=/home/dev", "/dev/pts/", "LOGIN", "CONN",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("missing %q in %q", want, output)
		}
	}
	tty := regexp.MustCompile(`(/dev/pts/\d+)`).FindString(output)
	if !strings.Contains(output, "SSH_TTY="+tty) {
		t.Fatalf("SSH_TTY does not match the tty %s: %q", tty, output)
	}
}

func TestAttachWithoutASessionReportsNoSession(t *testing.T) {
	_, code := remote(t, attachCommand(newSessionID(t), false)+" </dev/null 2>/dev/null")
	if code != 3 {
		t.Fatalf("exit code %d, want 3", code)
	}
}

func TestListShowsSessionsAndKillEndsThem(t *testing.T) {
	id := newSessionID(t)
	s := openSession(t, id, true, 0)
	s.send(holder.KindSetAttributes, []byte("tab-1"))
	s.send(holder.KindInput, []byte("echo SHELL_PID=$$\n"))
	pid := regexp.MustCompile(`SHELL_PID=(\d+)`).FindSubmatch(s.outputUntil(func(data []byte) bool {
		return regexp.MustCompile(`SHELL_PID=\d+\r`).Match(data)
	}))

	listing, _ := remote(t, holderPath()+" list")
	if !strings.Contains(listing, `"id":"`+id+`"`) || !strings.Contains(listing, `"pid":`+string(pid[1])) ||
		!strings.Contains(listing, `"attributes":"dGFiLTE="`) {
		t.Fatalf("listing: %q", listing)
	}

	if _, code := remote(t, holderPath()+" kill --id "+id); code != 0 {
		t.Fatalf("kill exit code %d", code)
	}
	listing, _ = remote(t, holderPath()+" list")
	if strings.Contains(listing, id) {
		t.Fatalf("session still listed: %q", listing)
	}
	if _, code := remote(t, "kill -0 "+string(pid[1])+" 2>/dev/null"); code == 0 {
		t.Fatal("shell still running after kill")
	}
	if leftovers, _ := remote(t, "ls ~/.local/state/uterm/sessions"); strings.Contains(leftovers, id) {
		t.Fatalf("socket left behind: %q", leftovers)
	}
}

// MARK: - 测量（UTERM_HOLDER_MEASURE=1）

// 一条能打字、能看输出的终端：要么是保持进程的会话，要么是 sshd 自己的 PTY 通道（对照组）。
type terminal interface {
	typeBytes(data []byte)
	// 收输出直到满足条件。
	waitFor(done func([]byte) bool) []byte
}

type heldTerminal struct{ *session }

func (h heldTerminal) typeBytes(data []byte) { h.send(holder.KindInput, data) }
func (h heldTerminal) waitFor(done func([]byte) bool) []byte {
	return h.outputUntil(done)
}

type plainTerminal struct{ *pipe }

func (p plainTerminal) typeBytes(data []byte) { p.write(data) }
func (p plainTerminal) waitFor(done func([]byte) bool) []byte {
	var collected []byte
	buffer := make([]byte, 64<<10)
	for !done(collected) {
		count, err := p.Read(buffer)
		collected = append(collected, buffer[:count]...)
		if err != nil {
			p.t.Fatalf("pty channel closed; collected %d bytes", len(collected))
		}
	}
	return collected
}

// 对照组关掉 OpenSSH 客户端的击键时序混淆：它把按键攒成 20 ms 一拍发，App 用的 SSH 库没有这个行为。
var plainTerminalOptions = []string{"-tt", "-o", "ObscureKeystrokeTiming=no"}

func measureTerminals(t *testing.T) map[string]terminal {
	t.Helper()
	if os.Getenv("UTERM_HOLDER_MEASURE") == "" {
		t.Skip("测量用例：UTERM_HOLDER_MEASURE=1 打开")
	}
	id := newSessionID(t)
	t.Cleanup(func() { endSession(t, id) })
	return map[string]terminal{
		"exec 通道 + 保持进程":    heldTerminal{openSession(t, id, true, 0)},
		"sshd 的 PTY 通道（对照）": plainTerminal{startPipe(t, plainTerminalOptions, "")},
	}
}

// 按一个键到看见回显：行规程的回显，不经过 shell。
func TestMeasureEchoLatency(t *testing.T) {
	for name, term := range measureTerminals(t) {
		term.typeBytes([]byte("cat\n"))
		time.Sleep(500 * time.Millisecond)
		term.typeBytes([]byte("warmup\n"))
		term.waitFor(func(data []byte) bool { return bytes.Count(data, []byte("warmup")) >= 2 })

		const samples = 500
		latencies := make([]time.Duration, 0, samples)
		for i := 0; i < samples; i++ {
			start := time.Now()
			term.typeBytes([]byte("k"))
			term.waitFor(contains("k"))
			latencies = append(latencies, time.Since(start))
			time.Sleep(2 * time.Millisecond)
		}
		sort.Slice(latencies, func(a, b int) bool { return latencies[a] < latencies[b] })
		t.Logf("%s：回显 p50 %v，p95 %v，p99 %v", name,
			latencies[samples/2], latencies[samples*95/100], latencies[samples*99/100])
	}
}

func TestMeasureThroughput(t *testing.T) {
	const megabytes = 200
	for name, term := range measureTerminals(t) {
		term.typeBytes([]byte("stty -echo; echo READY\n"))
		term.waitFor(contains("READY\r\n"))
		start := time.Now()
		term.typeBytes([]byte(fmt.Sprintf("head -c %d /dev/zero | tr '\\0' 'x'; echo; echo FLOOD_DONE\n", megabytes<<20)))
		received := term.waitFor(func(data []byte) bool {
			return len(data) >= megabytes<<20 && bytes.Contains(data[len(data)-64:], []byte("FLOOD_DONE"))
		})
		elapsed := time.Since(start)
		t.Logf("%s：%d MiB 用时 %v，%.0f MiB/s", name, len(received)>>20, elapsed.Round(time.Millisecond),
			float64(len(received))/(1<<20)/elapsed.Seconds())
	}
}
