import Foundation

/// 一个端口转发独立窗口的身份。`id` 让同一服务器可开多个窗口；`serverID` 指向
/// 绑定的 `ServerProfile`。Codable/Hashable 供 `WindowGroup(for:)` 状态恢复。
nonisolated struct PortForwardWindowID: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let serverID: UUID
}
