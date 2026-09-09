import Foundation
import Observation

/// 一条跨窗口可见的终端会话。字段与 `ControlTerminalSnapshot` 一一对应
/// （那边是线上形状：UUID 变字符串、Date 变 ISO8601）。
nonisolated struct TerminalSessionEntry: Identifiable, Sendable, Equatable {
    /// 会话 id（= `PaneModel` 的 id）。CLI 支持用唯一前缀指定。
    let id: UUID
    let serverID: UUID
    let serverName: String
    /// `workspace` / `terminal` —— 会话所在窗口的种类。
    let windowKind: String
    let title: String
    /// 该会话是否在当前 key window 里被聚焦（`terminal-send` 前值得提示用户）。
    let isKeyWindowFocused: Bool
    let connectedAt: Date?

    init(
        id: UUID,
        serverID: UUID,
        serverName: String,
        windowKind: String,
        title: String,
        isKeyWindowFocused: Bool = false,
        connectedAt: Date? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.windowKind = windowKind
        self.title = title
        self.isKeyWindowFocused = isKeyWindowFocused
        self.connectedAt = connectedAt
    }
}

/// 跨窗口的终端会话注册表（app 级单例，注入 environment）。
///
/// uTerm 的终端会话住在各自窗口的 `WorkspaceModel` / `PaneModel` 里，彼此不可见；
/// CLI 的 `terminals` / `terminal-read` / `terminal-send` 需要一个应用级的枚举面，
/// 这就是它。`PaneModel.connect` 注册、`dispose` 注销。
///
/// Wave 3 待填：`register` / `unregister` 的真实实现，以及 `PaneModel` 两处调用点。
/// 现在留空实现，让接线与协议先落地（`terminals` 返回空列表而不是崩）。
@MainActor
@Observable
final class TerminalSessionRegistry {

    /// 当前活着的会话，按注册顺序。
    private(set) var entries: [TerminalSessionEntry] = []

    /// 开一个新终端窗口并返回新会话 id（拿不到时 nil）。
    ///
    /// 由 Welcome scene 的 `.task` 捕获 `openWindow` 后注入 —— 与 `WelcomeView` 里
    /// 既有的 `let open = openWindow` 写法同款。`TerminalWindowID` 只能在 Scene 环境里开，
    /// 所以注册表自己不能直接调。
    var openTerminalWindow: (@MainActor (UUID) -> UUID?)?

    init() {}

    /// 会话连接成功后登记。同 id 重复登记视为更新。
    func register(_ entry: TerminalSessionEntry) {}

    /// 会话销毁时注销。
    func unregister(id: UUID) {}
}
