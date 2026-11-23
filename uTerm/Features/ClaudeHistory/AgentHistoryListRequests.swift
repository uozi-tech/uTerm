import Foundation

/// 「＋」新会话：默认开在哪个目录、选好工具之后怎么开（新开一个终端标签页跑 `command`）。两端的列表都收它。
struct AgentHistoryNewSession {
    /// 终端当前目录；不知道为 nil（按钮不可用，说明原因）。
    let directory: String?
    let start: (_ tool: AgentHistoryTool, _ command: String, _ directory: String) -> Void
}

/// 要列表定位到哪个目录（展开那一组并滚过去）。每次请求换一个 `generation`，同一个目录再要一次也会再滚。
nonisolated struct AgentHistoryReveal: Equatable, Sendable {
    let directory: String
    let generation: Int
}
