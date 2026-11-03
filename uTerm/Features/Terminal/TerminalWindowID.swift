import Foundation

/// 一个独立终端窗口的身份。Codable/Hashable 供 `WindowGroup(for:)` 状态恢复。
///
/// 终端窗口**不绑定单台服务器**：不同标签可以连不同主机，「在终端中打开」把主机作为
/// 新标签送进已有窗口（见 `TerminalWindowRouter`）。`serverID` 只是窗口首次出现时
/// 第一个标签连的主机（字段名沿用旧版，状态恢复的旧数据照样能解）。
///
/// 与 `WorkspaceWindowID`（完整工作区）/ `SFTPWindowID`（纯文件浏览）并列：
/// 终端窗口只含「终端 ⇄ Agent」两态，无 SFTP 侧栏 / 无预览区。
nonisolated struct TerminalWindowID: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let serverID: UUID
}
