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

    /// 排好的行。`sessions` 是 Mac 推来的会话列表（按 Mac 的标签顺序）；`codeTabs` 是 Mac 的 Code 标签页（63，老 Mac 为 nil），
    /// 每台主机一行（`mirroredPerHost`：本机的、各台 SSH 主机的）。归它的会话 = 它报的、认得出工具的那几个（同
    /// `RemoteMacClient.codeRunSessionIDs(serverIDs:)`；认不出的照旧各一行）。每个排在第 `slot` 个普通终端前面（没报位置的排在
    /// 最后，`insertingCodeTabs`），里面一个会话都没有也照样有这一行。
    static func rows(sessions: [RemoteSessionInfo], codeTabs: [RemoteCodeTabInfo]?) -> [RemoteMacSessionRow] {
        let tabs = (codeTabs ?? []).mirroredPerHost
        guard !tabs.isEmpty else { return sessions.map(RemoteMacSessionRow.session) }
        var owner: [UUID: UUID] = [:]
        for tab in tabs {
            for run in tab.runs where AgentHistoryTool(rawValue: run.tool) != nil && owner[run.session] == nil {
                owner[run.session] = tab.id
            }
        }
        let plain = sessions.filter { owner[$0.id] == nil }
        let byID = Dictionary(plain.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tabByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 没报位置的排在最后（按 Mac 报的先后）。
        let order = plain.map(\.id).insertingCodeTabs(tabs.map { ($0.id, $0.slot ?? plain.count) })
        return order.compactMap { id in
            if let session = byID[id] { return .session(session) }
            guard let tab = tabByID[id] else { return nil }
            return .codeTab(tab, sessions: sessions.filter { owner[$0.id] == tab.id })
        }
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
