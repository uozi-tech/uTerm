import Foundation

/// 一个「并行执行窗口」的身份。`WindowGroup(for:)` 以此作 presented value。
/// 只携带 `commandID`（外键 → `QuickCommand.id`）——窗口内据此解析命令文本 / 名称 /
/// AI 介入 / 目标服务器，与 `WorkspaceWindowID` 携 `serverID` 同范式。
///
/// 相等/哈希只看 `commandID`：同一条快捷命令复用同一个并行执行窗口（再次点「运行」
/// 聚焦既有窗口，靠窗口内「重新运行」重跑，避免窗口刷屏）。
nonisolated struct ParallelRunWindowID: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let commandID: UUID

    nonisolated init(commandID: UUID) {
        self.id = commandID
        self.commandID = commandID
    }

    nonisolated static func == (lhs: ParallelRunWindowID, rhs: ParallelRunWindowID) -> Bool {
        lhs.commandID == rhs.commandID
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(commandID)
    }
}
