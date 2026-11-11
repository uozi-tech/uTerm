package main

import (
	"os"
	"os/exec"
	"os/user"
	"strings"
	"time"
)

// 退出登录后会话进程能不能留下，取决于 systemd-logind 的两个设置（2026-11 在 Ubuntu 24.04 / systemd 255 上实测）：
//
//	KillUserProcesses  linger  起法            退出登录后
//	no（各发行版默认）  no      普通（新会话）   留下
//	yes                no      普通            被杀
//	yes                no      用户级 scope    被杀（最后一个登录结束后用户级 systemd 也停了）
//	yes                yes     用户级 scope    留下
//	yes                yes     普通            被杀
//
// 所以：开了 linger 就放进用户级 scope（两种 KillUserProcesses 下都留得下）；没开就用普通起法。
// linger 要管理员开（`loginctl enable-linger <用户>`），普通用户自己开会被 polkit 拒绝。

const systemdQueryTimeout = 2 * time.Second

func commandOutput(name string, arguments ...string) (string, bool) {
	path, err := exec.LookPath(name)
	if err != nil {
		return "", false
	}
	command := exec.Command(path, arguments...)
	timer := time.AfterFunc(systemdQueryTimeout, func() { _ = command.Process.Kill() })
	defer timer.Stop()
	output, err := command.Output()
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(string(output)), true
}

func currentUserName() string {
	if name := os.Getenv("USER"); name != "" {
		return name
	}
	if current, err := user.Current(); err == nil {
		return current.Username
	}
	return ""
}

// 这个用户开没开 linger。查不到（没有 systemd）返回 known=false。
func lingerEnabled() (enabled, known bool) {
	name := currentUserName()
	if name == "" {
		return false, false
	}
	output, ok := commandOutput("loginctl", "show-user", name, "-p", "Linger", "--value")
	if !ok {
		return false, false
	}
	return output == "yes", true
}

// 退出登录时 logind 会不会杀这个用户留下的进程。查不到返回 known=false。
func logindKillsUserProcesses() (kills, known bool) {
	property := func(name string) (string, bool) {
		return commandOutput("busctl", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1",
			"org.freedesktop.login1.Manager", name)
	}
	enabled, ok := property("KillUserProcesses")
	if !ok {
		return false, false
	}
	if enabled != "b true" {
		return false, true
	}
	name := currentUserName()
	// busctl 的字符串数组写成：as 2 "alice" "bob"。
	listed := func(output string) bool { return strings.Contains(output, `"`+name+`"`) }
	if excluded, ok := property("KillExcludeUsers"); ok && listed(excluded) {
		return false, true
	}
	if only, ok := property("KillOnlyUsers"); ok && strings.HasPrefix(only, "as ") && !strings.HasPrefix(only, "as 0") {
		return listed(only), true
	}
	return true, true
}

// 能不能把会话进程放进用户级 scope：要有 systemd-run 和用户级 systemd 的运行目录。
func userScopeAvailable() bool {
	if os.Getenv("XDG_RUNTIME_DIR") == "" {
		return false
	}
	_, err := exec.LookPath("systemd-run")
	return err == nil
}

// 起会话进程用的命令。开了 linger 时套一层 systemd-run：它把自己登记进新的 scope 再 exec 成会话进程。
func sessionCommand(self string, arguments []string) (command *exec.Cmd, inUserScope bool) {
	if enabled, _ := lingerEnabled(); enabled && userScopeAvailable() {
		wrapped := append([]string{"--user", "--scope", "--quiet", "--collect", "--", self}, arguments...)
		return exec.Command("systemd-run", wrapped...), true
	}
	return exec.Command(self, arguments...), false
}
