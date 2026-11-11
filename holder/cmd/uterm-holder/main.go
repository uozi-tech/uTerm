// uterm-holder：主机上的会话保持进程。uTerm 经 SSH 的 exec 通道调用它，用户不直接用。
//
//	uterm-holder attach --id ID [--create --cols N --rows N --term T --detached-timeout 24h --env K=V…]
//	    接入会话（--create：没有就新建），之后标准输入输出上走帧协议。
//	    --detached-timeout：这么久没有客户端接着就结束会话（0 = 不限）。
//	uterm-holder list        每行一个会话（JSON）。
//	uterm-holder kill --id ID
//	uterm-holder version
//	uterm-holder serve …     内部用：会话进程本身。
package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"uterm.local/holder/internal/holder"
)

const version = "0.1.0"

// 退出码：App 据此区分「没有这个会话」和别的失败。
const (
	exitFailure   = 1
	exitUsage     = 2
	exitNoSession = 3
)

var sessionIDPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "attach":
		attach(os.Args[2:])
	case "serve":
		serve(os.Args[2:])
	case "list":
		list()
	case "kill":
		kill(os.Args[2:])
	case "probe":
		probe()
	case "version":
		fmt.Printf("%s protocol=%d\n", version, holder.ProtocolVersion)
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: uterm-holder attach|list|kill|version")
	os.Exit(exitUsage)
}

func fail(code int, format string, arguments ...any) {
	fmt.Fprintf(os.Stderr, "uterm-holder: "+format+"\n", arguments...)
	os.Exit(code)
}

// 会话的 socket 放在这里。目录只有自己能进。
func sessionsDirectory() string {
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			fail(exitFailure, "找不到主目录：%v", err)
		}
		base = filepath.Join(home, ".local", "state")
	}
	directory := filepath.Join(base, "uterm", "sessions")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		fail(exitFailure, "建不了会话目录：%v", err)
	}
	info, err := os.Stat(directory)
	if err != nil {
		fail(exitFailure, "会话目录不可用：%v", err)
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Getuid() {
		fail(exitFailure, "会话目录不属于当前用户：%s", directory)
	}
	if info.Mode().Perm()&0o077 != 0 {
		if err := os.Chmod(directory, 0o700); err != nil {
			fail(exitFailure, "会话目录权限不对：%v", err)
		}
	}
	return directory
}

// 切进会话目录，之后用相对路径：完整路径可能超过 sun_path 的上限（主目录很长时）。
func enterSessionsDirectory() {
	if err := os.Chdir(sessionsDirectory()); err != nil {
		fail(exitFailure, "进不去会话目录：%v", err)
	}
}

func socketName(id string) string { return id + ".sock" }

func requireID(id string) {
	if !sessionIDPattern.MatchString(id) {
		fail(exitUsage, "会话 id 不合法")
	}
}

type environmentFlag []string

func (e *environmentFlag) String() string { return strings.Join(*e, " ") }
func (e *environmentFlag) Set(value string) error {
	if !strings.Contains(value, "=") {
		return errors.New("要写成 NAME=VALUE")
	}
	*e = append(*e, value)
	return nil
}

// MARK: - attach

func attach(arguments []string) {
	flags := flag.NewFlagSet("attach", flag.ExitOnError)
	id := flags.String("id", "", "")
	create := flags.Bool("create", false, "")
	cols := flags.Uint("cols", 80, "")
	rows := flags.Uint("rows", 24, "")
	term := flags.String("term", "xterm-256color", "")
	detachedTimeout := flags.Duration("detached-timeout", 0, "")
	var environment environmentFlag
	flags.Var(&environment, "env", "")
	_ = flags.Parse(arguments)
	requireID(*id)
	enterSessionsDirectory()

	conn, err := holder.Dial(socketName(*id))
	if errors.Is(err, holder.ErrNoSession) && *create {
		conn, err = createSession(*id, *cols, *rows, *term, *detachedTimeout, environment)
	}
	if errors.Is(err, holder.ErrNoSession) {
		fail(exitNoSession, "没有这个会话")
	}
	if err != nil {
		fail(exitFailure, "连不上会话：%v", err)
	}

	// 两个方向各拷各的，任一头结束就退出：SSH 通道关了（标准输入结束）或会话那头关了。
	finished := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(conn, os.Stdin)
		finished <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(os.Stdout, conn)
		finished <- struct{}{}
	}()
	<-finished
	conn.Close()
}

// 起会话进程并连上它。
func createSession(id string, cols, rows uint, term string, detachedTimeout time.Duration,
	environment []string) (*net.UnixConn, error) {
	self, err := os.Executable()
	if err != nil {
		fail(exitFailure, "找不到自己的路径：%v", err)
	}
	arguments := []string{"serve", "--id", id, "--cols", fmt.Sprint(cols), "--rows", fmt.Sprint(rows), "--term", term,
		"--detached-timeout", detachedTimeout.String()}
	for _, entry := range environment {
		arguments = append(arguments, "--env", entry)
	}
	command, inUserScope := sessionCommand(self, arguments)
	if !inUserScope {
		startDetached(command)
		return waitForSession(socketName(id), 5*time.Second)
	}
	startDetached(command)
	conn, err := waitForSession(socketName(id), 3*time.Second)
	if errors.Is(err, holder.ErrNoSession) {
		// 用户级 systemd 没接上：退回普通起法，起不来才算失败。
		startDetached(exec.Command(self, arguments...))
		return waitForSession(socketName(id), 5*time.Second)
	}
	return conn, err
}

// 新的会话（脱离 sshd 给这次 exec 的会话），标准输入输出都不接这次 exec 的管道，否则 SSH 通道等不到关闭。
func startDetached(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		fail(exitFailure, "起不了会话：%v", err)
	}
	_ = command.Process.Release()
}

func waitForSession(name string, timeout time.Duration) (conn *net.UnixConn, err error) {
	deadline := time.Now().Add(timeout)
	for {
		conn, err = holder.Dial(name)
		if err == nil || !errors.Is(err, holder.ErrNoSession) || time.Now().After(deadline) {
			return conn, err
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// MARK: - serve

func serve(arguments []string) {
	flags := flag.NewFlagSet("serve", flag.ExitOnError)
	id := flags.String("id", "", "")
	cols := flags.Uint("cols", 80, "")
	rows := flags.Uint("rows", 24, "")
	term := flags.String("term", "xterm-256color", "")
	detachedTimeout := flags.Duration("detached-timeout", 0, "")
	var environment environmentFlag
	flags.Var(&environment, "env", "")
	_ = flags.Parse(arguments)
	requireID(*id)
	enterSessionsDirectory()

	shell := loginShell()
	home, _ := os.UserHomeDir()
	workDir := home
	if info, err := os.Stat(workDir); err != nil || !info.IsDir() {
		workDir = "/"
	}
	env := append(os.Environ(), "TERM="+*term)
	env = append(env, environment...)
	server := holder.NewServer(holder.Config{
		SocketPath: socketName(*id),
		Cols:       uint16(*cols),
		Rows:       uint16(*rows),
		Shell:      shell,
		// 登录 shell：argv0 以 - 开头。
		Args:            []string{"-" + filepath.Base(shell)},
		Env:             env,
		WorkDir:         workDir,
		DetachedTimeout: *detachedTimeout,
	})
	if err := server.Start(); err != nil {
		fail(exitFailure, "起不了会话：%v", err)
	}
	// SIGHUP 接住不处理（不能设成忽略：忽略会被 shell 继承，结束会话时发给它的 SIGHUP 就不灵了）。
	signals := make(chan os.Signal, 4)
	signal.Notify(signals, syscall.SIGHUP, syscall.SIGTERM)
	go func() {
		for received := range signals {
			if received == syscall.SIGTERM {
				server.Terminate()
			}
		}
	}()
	<-server.Done()
}

// 用户的登录 shell：sshd 给 exec 的环境里有 SHELL；没有就查 /etc/passwd。
func loginShell() string {
	if shell := os.Getenv("SHELL"); shell != "" {
		if _, err := os.Stat(shell); err == nil {
			return shell
		}
	}
	if data, err := os.ReadFile("/etc/passwd"); err == nil {
		uid := fmt.Sprint(os.Getuid())
		for _, line := range strings.Split(string(data), "\n") {
			fields := strings.Split(line, ":")
			if len(fields) >= 7 && fields[2] == uid && fields[6] != "" {
				if _, err := os.Stat(fields[6]); err == nil {
					return fields[6]
				}
			}
		}
	}
	return "/bin/sh"
}

// MARK: - probe

// App 第一次用这台主机前问一次：版本对不对得上，退出登录后会话留不留得下。
type probeReport struct {
	Version  string `json:"version"`
	Protocol uint32 `json:"protocol"`
	// yes / no / unknown。no 时要管理员给这个用户开 linger。
	SurvivesLogout string `json:"survivesLogout"`
	// 查不到时省略。
	Linger            *bool `json:"linger,omitempty"`
	KillUserProcesses *bool `json:"killUserProcesses,omitempty"`
}

func probe() {
	report := probeReport{Version: version, Protocol: holder.ProtocolVersion, SurvivesLogout: "unknown"}
	linger, lingerKnown := lingerEnabled()
	if lingerKnown {
		report.Linger = &linger
	}
	kills, killsKnown := logindKillsUserProcesses()
	if killsKnown {
		report.KillUserProcesses = &kills
	}
	_, err := os.Stat("/run/systemd/system")
	switch {
	case err != nil:
		// 没有 systemd：退出登录时没有谁来清进程。
		report.SurvivesLogout = "yes"
	case linger && userScopeAvailable():
		report.SurvivesLogout = "yes"
	case killsKnown && !kills:
		report.SurvivesLogout = "yes"
	case killsKnown && kills:
		report.SurvivesLogout = "no"
	}
	_ = json.NewEncoder(os.Stdout).Encode(report)
}

// MARK: - list / kill

type sessionSummary struct {
	ID         string `json:"id"`
	PID        int32  `json:"pid"`
	CreatedAt  uint64 `json:"createdAt"`
	Cols       uint16 `json:"cols"`
	Rows       uint16 `json:"rows"`
	Exited     bool   `json:"exited"`
	Attributes string `json:"attributes"`
}

func list() {
	enterSessionsDirectory()
	entries, err := os.ReadDir(".")
	if err != nil {
		fail(exitFailure, "读不了会话目录：%v", err)
	}
	encoder := json.NewEncoder(os.Stdout)
	for _, entry := range entries {
		id, isSocket := strings.CutSuffix(entry.Name(), ".sock")
		if !isSocket || !sessionIDPattern.MatchString(id) {
			continue
		}
		reply, ok := hello(entry.Name())
		if !ok {
			continue
		}
		_ = encoder.Encode(sessionSummary{
			ID: id, PID: reply.ShellPID, CreatedAt: reply.CreatedAt, Cols: reply.Cols, Rows: reply.Rows,
			Exited: reply.ExitStatus != nil, Attributes: base64.StdEncoding.EncodeToString(reply.Attributes),
		})
	}
}

func hello(name string) (holder.HelloReply, bool) {
	conn, err := holder.Dial(name)
	if err != nil {
		return holder.HelloReply{}, false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write(holder.AppendFrame(nil, holder.KindHello, nil)); err != nil {
		return holder.HelloReply{}, false
	}
	for {
		frame, err := holder.ReadFrame(conn)
		if err != nil {
			return holder.HelloReply{}, false
		}
		if frame.Kind == holder.KindHelloReply {
			return holder.DecodeHelloReply(frame.Payload)
		}
	}
}

func kill(arguments []string) {
	flags := flag.NewFlagSet("kill", flag.ExitOnError)
	id := flags.String("id", "", "")
	_ = flags.Parse(arguments)
	requireID(*id)
	enterSessionsDirectory()
	conn, err := holder.Dial(socketName(*id))
	if errors.Is(err, holder.ErrNoSession) {
		fail(exitNoSession, "没有这个会话")
	}
	if err != nil {
		fail(exitFailure, "连不上会话：%v", err)
	}
	defer conn.Close()
	// 先等 hello 的回复再发结束：会话进程刚起来时，发完就关会让它来不及读到。
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	request := holder.AppendFrame(nil, holder.KindHello, nil)
	if _, err := conn.Write(request); err != nil {
		fail(exitFailure, "发不出去：%v", err)
	}
	if _, err := holder.ReadFrame(conn); err != nil {
		fail(exitFailure, "会话没有回应：%v", err)
	}
	if _, err := conn.Write(holder.AppendFrame(nil, holder.KindTerminate, nil)); err != nil {
		fail(exitFailure, "发不出去：%v", err)
	}
	// 会话进程退出时关连接；读到结束就是结束了。
	_, _ = io.Copy(io.Discard, conn)
}
