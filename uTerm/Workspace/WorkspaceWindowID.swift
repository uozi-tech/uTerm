import Foundation

/// 一个工作区窗口的身份。`WindowGroup(for:)` 以此作 presented value，
/// 由 macOS 窗口状态恢复持久化。
///
/// `id` 每次打开新生成 —— `WindowGroup(for:)` 对相同值会复用窗口，
/// 唯一的 `id` 保证「同一服务器开多个窗口」时各窗口互为独立身份。
/// `serverID` 是该窗口绑定的服务器。
nonisolated struct WorkspaceWindowID: Codable, Hashable, Sendable {
    let id: UUID
    let serverID: UUID
}
