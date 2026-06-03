import Foundation

/// 一个 SFTP 独立窗口的身份。`id` 让同一服务器可开多个窗口；`serverID` 指向
/// 绑定的 `ServerProfile`。Codable/Hashable 供 `WindowGroup(for:)` 状态恢复。
nonisolated struct SFTPWindowID: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let serverID: UUID
}
