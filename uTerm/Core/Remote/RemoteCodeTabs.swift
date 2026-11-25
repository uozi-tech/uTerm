import Foundation

/// Mac 上的一个 Code 标签页（63 号消息里的一项）：接管这台 Mac 的设备据此把它开成自己的 Code 标签页，里面跑着的会话
/// 不再各开一个终端标签页。
///
/// 哪些会话归它只认这一份（不往 `RemoteSessionInfo` 上加字段）。远控进程也编这个文件（转发 App 交来的那份），
/// 所以只用 Foundation：工具存原始值（`AgentHistoryTool.rawValue`），认不出的工具由设备自己跳过。
/// 线格式只加不改：新加的字段一律可选。
nonisolated struct RemoteCodeTabInfo: Codable, Equatable, Sendable {
    /// Mac 上 Code 标签页的 id（`CodeTabRecord.id`，重启后不变）。
    var id: UUID
    /// 哪台主机：本机终端窗口里的是 `RemoteConstants.localShellServerID`。
    var serverID: UUID
    var serverName: String
    /// 「＋」新会话默认开在哪个目录。
    var directory: String?
    /// 它在 Mac 的标签顺序里排在第几个会话之前（同 `RemoteSessionInfo.order` 的那份顺序）；nil = 不排。
    var slot: Int?
    var runs: [Run]
    /// Mac 上右边看着的是哪个跑着的会话（会话 id）。设备只在第一次开出这个标签页时照它选。
    var selectedRun: UUID?
    /// Mac 上右边看着的是哪份只读记录（`AgentHistoryPinKey.stored`，`工具:会话 ID`）。
    var selectedRecord: String?

    /// 一个在这个标签页里跑着的会话。
    struct Run: Codable, Equatable, Sendable {
        /// 终端会话的 id（`RemoteSessionInfo.id`，按它接入）。
        var session: UUID
        /// `AgentHistoryTool.rawValue`。
        var tool: String
        /// 在哪个目录里起的。
        var directory: String
        var startedAt: Date
        /// 对上了的那份记录的会话 ID；还没对上的新会话为 nil。
        var sessionID: String?
        /// 对上了的那份记录在 Mac 上的路径（设备经文件通道读的也是这条路径）。
        var path: String?
        /// Mac 侧栏上这个会话的名字（`CodeTabModel.title(of:)`）。
        var title: String?
        /// 程序已经退出、终端留着最后的画面的时刻；还在跑为 nil。
        var endedAt: Date?
    }

    /// 只差标题与记录路径：这两样跟着 Claude Code 写记录一直在变，合并到标签名的推送节奏里发（`tabTitlePushInterval`）。
    /// 其余的（会话增减、结束、选中、位置）要马上到设备上。
    func sameShape(as other: RemoteCodeTabInfo) -> Bool {
        var mine = self, theirs = other
        for index in mine.runs.indices { mine.runs[index].title = nil; mine.runs[index].path = nil }
        for index in theirs.runs.indices { theirs.runs[index].title = nil; theirs.runs[index].path = nil }
        return mine == theirs
    }
}

/// 63 号消息的负载：Mac 上全部的 Code 标签页，每次整份替换。
nonisolated struct RemoteCodeTabsUpdate: Codable, Equatable, Sendable {
    var tabs: [RemoteCodeTabInfo]
}

extension Array where Element == RemoteCodeTabInfo {
    /// 两份只差标题与路径（见 `RemoteCodeTabInfo.sameShape`）。一份为 nil（还没有）算不一样。
    nonisolated func sameShape(as other: [RemoteCodeTabInfo]?) -> Bool {
        guard let other, count == other.count else { return false }
        return zip(self, other).allSatisfy { $0.sameShape(as: $1) }
    }

    /// 设备上开成 Code 标签页的那一个：每台主机至多一个，碰到老布局里有几个的，取第一个（其余的会话照旧是终端标签页）。
    nonisolated func mirrored(serverID: UUID = RemoteConstants.localShellServerID) -> RemoteCodeTabInfo? {
        first { $0.serverID == serverID }
    }
}
