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

    /// 每台主机一个（同 `mirrored(serverID:)`，按 Mac 报的先后）：本机的和各台 SSH 主机的。
    nonisolated var mirroredPerHost: [RemoteCodeTabInfo] {
        var seen: Set<UUID> = []
        return filter { seen.insert($0.serverID).inserted }
    }
}

extension Array where Element == UUID {
    /// 往 Mac 的标签顺序（只有会话）里插进 Code 标签页：每个排在第 `slot` 个会话之前（`RemoteCodeTabInfo.slot`，数的是会话，
    /// 不数别的 Code 标签页；超出范围排在最后），同一个位置的按给的先后。顺序里已经有它的先拿掉再插。没报位置（nil）的不插。
    nonisolated func insertingCodeTabs(_ tabs: [(id: UUID, slot: Int?)]) -> [UUID] {
        let ids = Set(tabs.map(\.id))
        let sessions = filter { !ids.contains($0) }
        let placed = tabs.enumerated().compactMap { index, tab in tab.slot.map { (index, tab.id, Swift.min(Swift.max($0, 0), sessions.count)) } }
            .sorted { ($0.2, $0.0) < ($1.2, $1.0) }
        var result: [UUID] = []
        var next = placed.makeIterator()
        var pending = next.next()
        for (position, id) in sessions.enumerated() {
            while let tab = pending, tab.2 == position { result.append(tab.1); pending = next.next() }
            result.append(id)
        }
        while let tab = pending { result.append(tab.1); pending = next.next() }
        return result
    }
}

/// 64 号消息的负载：设备请 Mac 在它的 Code 标签页里做一件事（设备 → Mac，通道 0）。Mac 回 65 号
/// （`RemoteCodeTabActionResult`），做完照常推新的 Code 标签页（63）与会话列表（20），设备按回复里的会话 id 在 63 里认出
/// 新起的那个会话。只发给 `features` 带 `code-tab-actions` 的 Mac（老 Mac 收到未知消息会断开整条连接）。
///
/// 动作存原始值（`Action.rawValue`），线格式只加不改：新加的动作 Mac 不认时回错误，不会解码失败断开；新字段一律可选。
nonisolated struct RemoteCodeTabAction: Codable, Equatable, Sendable {
    nonisolated enum Action: String, Codable, Sendable {
        /// 继续一份记录（`path` / `tool` / `sessionID`；`directory` 是设备算的继续目录，Mac 对不上记录时用它）。
        /// 这份记录已经在 Code 标签页里跑着就回到它。
        case resume
        /// 新开一个会话（`tool` / `directory`）。
        case start
        /// 已结束的会话「重新开始」（`session`）：同一种工具、同一个目录，放回原来的位置，回复里是新会话。
        case restart
        /// 「移到新标签页」（`session`）：开成 Code 标签页所在组里的普通终端标签页，回复里是同一个会话。
        case moveToTab
    }

    /// 回复里原样带回。
    var requestID: UUID
    /// `Action.rawValue`。
    var action: String
    /// 设备镜像着的那个 Mac Code 标签页（`RemoteCodeTabInfo.id`）；nil = 设备还没有镜像（Mac 上还没有 Code 标签页），
    /// `resume` / `start` 时 Mac 先开一个。
    var tab: UUID?
    /// `restart` / `moveToTab`：哪个会话（`RemoteCodeTabInfo.Run.session`）。
    var session: UUID?
    /// `resume`：那份记录在 Mac 上的路径（`AgentHistorySessionFile.path`）。
    var path: String?
    /// `resume` / `start`：`AgentHistoryTool.rawValue`。
    var tool: String?
    /// `resume`：记录的会话 ID。
    var sessionID: String?
    /// `resume`：继续的目录；`start`：新开在哪个目录。
    var directory: String?
    /// 哪台主机的 Code 标签页（`RemoteCodeTabInfo.serverID`）；nil 或 `localShellServerID` = Mac 本机。SSH 主机的只发给声明了
    /// `code-tab-hosts` 的 Mac（之前的 Mac 不读这个键，会当成本机的做）。
    var server: UUID?

    init(requestID: UUID = UUID(), action: Action, tab: UUID? = nil, session: UUID? = nil, path: String? = nil,
         tool: String? = nil, sessionID: String? = nil, directory: String? = nil, server: UUID? = nil) {
        self.requestID = requestID
        self.action = action.rawValue
        self.tab = tab
        self.session = session
        self.path = path
        self.tool = tool
        self.sessionID = sessionID
        self.directory = directory
        self.server = server
    }

    /// 认不出的动作（更新的设备发来的）为 nil。
    var knownAction: Action? { Action(rawValue: action) }
}

/// 65 号消息的负载（Mac → 设备，通道 0）。
nonisolated struct RemoteCodeTabActionResult: Codable, Equatable, Sendable {
    var requestID: UUID
    /// 做完之后的那个会话（`resume` / `start` / `restart` 是新起的或回到的，`moveToTab` 是挪出去的）；失败时 nil。
    var session: UUID?
    /// 失败原因（给人看的），成功时 nil。
    var error: String?
}
