import Foundation

// uTerm 的本机 shell 辅助程序：uTerm 内嵌的 XPC 服务（Contents/XPCServices/uTermShellAgent.xpc），
// 主程序连接时由系统按需拉起，不带沙盒。见 `ShellAgentServer`。
// 生命周期归系统管（主程序退出时一起结束）。会话归 holder，所以这里退出不影响任何 shell。
let server = ShellAgentServer()
let listener = NSXPCListener.service()
listener.delegate = server
listener.resume()
