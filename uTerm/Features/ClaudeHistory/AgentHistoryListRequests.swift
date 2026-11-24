import Foundation

/// 「＋」新会话。两端的列表都收它，有两种：
/// - 直接开（独立的历史会话窗口）：默认开在哪个目录、选好工具之后怎么开（新开一个终端标签页跑 `command`）；
/// - 先选（Code 标签页）：「＋」只叫出选目录、选工具的那一页 / 面板（`present`），开不开由那里决定。
struct AgentHistoryNewSession {
    /// 终端当前目录；不知道为 nil（按钮不可用，说明原因）。先选的那种不用它。
    let directory: String?
    let start: (_ tool: AgentHistoryTool, _ command: String, _ directory: String) -> Void
    /// 先选的那种：点「＋」叫出起始页 / 面板。nil = 直接开。
    let present: (() -> Void)?

    init(directory: String?, start: @escaping (_ tool: AgentHistoryTool, _ command: String, _ directory: String) -> Void) {
        self.directory = directory
        self.start = start
        present = nil
    }

    /// 「＋」不直接开，叫出选目录、选工具的地方。
    init(presenting present: @escaping () -> Void) {
        directory = nil
        start = { _, _, _ in }
        self.present = present
    }
}

/// 要列表定位到哪个目录（展开那一组并滚过去）。每次请求换一个 `generation`，同一个目录再要一次也会再滚。
nonisolated struct AgentHistoryReveal: Equatable, Sendable {
    let directory: String
    let generation: Int
}
