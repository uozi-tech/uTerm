import Foundation

// uTerm 的本机 shell 辅助进程：由 launchd 按 `Contents/Library/LaunchAgents/com.uozi.uTerm.ShellAgent.plist`
// 的 `MachServices` 按需拉起（主程序经 `SMAppService.agent` 注册），不带沙盒。见 `ShellAgentServer`。
let server = ShellAgentServer()
let listener = NSXPCListener(machServiceName: LocalShellAgent.machServiceName)
listener.delegate = server
listener.resume()
dispatchMain()
