import Foundation

/// 一个工作区窗口的身份。`WindowGroup(for:)` 以此作 presented value。
/// 相等/哈希只看 `serverID`，因此同一服务器只会复用同一个工作区窗口。
nonisolated struct WorkspaceWindowID: Codable, Hashable, Sendable {
    let id: UUID
    let serverID: UUID

    nonisolated init(id: UUID, serverID: UUID) {
        self.id = id
        self.serverID = serverID
    }

    nonisolated init(serverID: UUID) {
        self.id = serverID
        self.serverID = serverID
    }

    nonisolated static func == (lhs: WorkspaceWindowID, rhs: WorkspaceWindowID) -> Bool {
        lhs.serverID == rhs.serverID
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(serverID)
    }
}
