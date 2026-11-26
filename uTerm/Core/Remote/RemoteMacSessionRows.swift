import Foundation

/// 一台 Mac 的终端列表里的一行（手机上那台 Mac 的面板「Mac 上的终端」）：一个普通终端，或 Mac 的 Code 标签页——
/// 里面跑着的会话收成一行，不再一个会话一行（接管后它们本来也是手机上的一个 Code 标签页）。两端共用，界面只画。
nonisolated enum RemoteMacSessionRow: Identifiable, Equatable, Sendable {
    case session(RemoteSessionInfo)
    /// `sessions`：Code 标签页里的会话在会话列表里的那几条（按列表的先后）。
    case codeTab(RemoteCodeTabInfo, sessions: [RemoteSessionInfo])

    var id: UUID {
        switch self {
        case .session(let session): session.id
        case .codeTab(let info, _): info.id
        }
    }

    /// 排好的行。`sessions` 是 Mac 推来的会话列表（按 Mac 的标签顺序）；`codeTab` 是设备会开成 Code 标签页的那一个
    /// （`Array.mirrored`，老 Mac 为 nil）。归它的会话 = 它报的、认得出工具的那几个（同 `RemoteMacClient.codeRunSessionIDs`；
    /// 认不出的照旧各一行）。它排在第 `slot` 个普通终端前面（没报位置时排在最后），里面一个会话都没有也照样有这一行。
    static func rows(sessions: [RemoteSessionInfo], codeTab: RemoteCodeTabInfo?) -> [RemoteMacSessionRow] {
        guard let codeTab else { return sessions.map(RemoteMacSessionRow.session) }
        let owned = Set(codeTab.runs.filter { AgentHistoryTool(rawValue: $0.tool) != nil }.map(\.session))
        let plain = sessions.filter { !owned.contains($0.id) }
        var rows = plain.map(RemoteMacSessionRow.session)
        let index = min(max(codeTab.slot ?? rows.count, 0), rows.count)
        rows.insert(.codeTab(codeTab, sessions: sessions.filter { owned.contains($0.id) }), at: index)
        return rows
    }

    /// 点这一行接管时落在哪个会话：普通终端是它自己；Code 标签页是 Mac 右边看着的那个会话，没在看哪个就是里面第一个
    /// 还在跑的、再没有就是第一个。Code 标签页里一个会话都没有时为 nil。
    var focus: UUID? {
        switch self {
        case .session(let session):
            return session.id
        case .codeTab(let info, let sessions):
            let listed = Set(sessions.map(\.id))
            let runs = info.runs.filter { listed.contains($0.session) }
            if let selected = info.selectedRun, listed.contains(selected) { return selected }
            return (runs.first { $0.endedAt == nil } ?? runs.first)?.session
        }
    }
}
