import Darwin
import Foundation

// uterm-ssh：跑在 `uterm-holder` 的 PTY 里，相当于我们自己的 ssh 命令。stdin/stdout 是 PTY，
// 窗口变化靠 SIGWINCH，连接断了就退出，holder 上报，App 显示现有的「已断开」和重连。
// 升级 SSH 栈只影响之后新开的会话。见 `SSHBridgeSession`。
// 探活信号在连上之前就可能到（App 接回了一个还在握手的会话），默认处置会杀掉进程。
signal(SIGUSR1, SIG_IGN)
let controlFD = Int32(ProcessInfo.processInfo.environment["UTERM_SSH_CONTROL_FD"] ?? "") ?? 3
let session = SSHBridgeSession(controlFD: controlFD)
Task { await session.run() }
dispatchMain()
