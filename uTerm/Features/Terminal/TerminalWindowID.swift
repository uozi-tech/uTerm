import Foundation

/// 一个独立「纯终端」窗口的身份。`id` 让同一服务器可开多个终端窗口；`serverID`
/// 指向绑定的 `ServerProfile`。Codable/Hashable 供 `WindowGroup(for:)` 状态恢复。
///
/// 与 `WorkspaceWindowID`（完整工作区）/ `SFTPWindowID`（纯文件浏览）并列：
/// 终端窗口只含「终端 ⇄ Agent」两态，无 SFTP 侧栏 / 无预览区。
nonisolated struct TerminalWindowID: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let serverID: UUID
}
