import Foundation

/// 把「AI 介入」快捷命令从欢迎页传给（已开或将开的）工作区窗口 Agent 会话的单例信箱。
/// 仿 `ImportInbox`：窗口已开时 `openWindow` 不重跑 onAppear，靠 `onChange(serial)` 消费。
///
/// **按 serverID 分槽**：多条 AI 命令路由到不同服务器时各自排队、互不覆盖（单槽会丢命令）。
/// 普通（非 AI）命令走 `QuickCommandRunner` 真实并行执行，不经此信箱。
@MainActor @Observable final class QuickCommandInbox {
    static let shared = QuickCommandInbox()
    private init() {}

    /// serverID → 待交给该服务器工作区 Agent 的命令文本。
    private(set) var pending: [UUID: String] = [:]
    /// 每次入队 +1。工作区窗口已开时靠 `onChange(serial)` 消费。
    private(set) var serial: Int = 0

    func enqueue(serverID: UUID, command: String) {
        pending[serverID] = command
        serial &+= 1
    }

    /// 取出并清空属于 `serverID` 的待办（无则返回 nil，其它服务器的待办保留）。
    func take(for serverID: UUID) -> String? {
        guard let command = pending[serverID] else { return nil }
        pending[serverID] = nil
        return command
    }
}
