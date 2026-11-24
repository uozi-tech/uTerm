import Foundation

/// Code 标签页里一个跑着的会话怎么记下来：App 重启后按它把会话接回原来的 Code 标签页。两端共用这一个类型——
/// Mac 存进保持进程里的窗口布局（`HeldSessionLayout.codeTabs`），iOS 存进标签归档（`MobileTerminalTabArchive`）。
///
/// 只记「是哪一个」：终端会话的 id、哪种工具、对上了的那份记录的会话 ID（和置顶 `AgentHistoryPinKey` 同一种认法，
/// 列表读出来之后再对回记录）；还没对上记录的新会话记工具、目录和起的时间，接回后照旧走对记录的规则。
/// 不存标题、对话内容、记录文件的路径。
///
/// 存储格式只加不改：加的字段一律可选。工具存原始值：以后删掉的工具解不出来时整条照样读得出（那个会话退回普通终端标签页）。
nonisolated struct CodeRunRecord: Codable, Equatable, Sendable {
    /// 终端会话的 id。Mac：保持进程里的会话 id（就是终端面板的 id）；iOS：主机上保持进程的会话 id（`hostSessionID`）。
    var session: UUID
    /// `AgentHistoryTool.rawValue`。
    var tool: String
    /// 对上了的那份记录的会话 ID；还没对上的新会话为 nil。
    var sessionID: String?
    /// 在哪个目录里起的。
    var directory: String
    var startedAt: Date
    /// Mac：命令起止标记的编号（`TerminalTrackedRun.id`）。接回后终端里的程序退出时打出的结束标记还认得出来。
    /// iOS 不用（命令后面接 `; exit`，程序退出会话就跟着结束）。
    var marker: String?
    /// 右边看的是它的记录（「终端 / 记录」切到了「记录」）。没有 = 看终端。
    var showsTranscript: Bool?

    init(session: UUID, tool: AgentHistoryTool, sessionID: String?, directory: String, startedAt: Date,
         marker: String? = nil, showsTranscript: Bool? = nil) {
        self.session = session
        self.tool = tool.rawValue
        self.sessionID = sessionID
        self.directory = directory
        self.startedAt = startedAt
        self.marker = marker
        self.showsTranscript = showsTranscript
    }

    /// 认不出的工具为 nil。
    var agentTool: AgentHistoryTool? { AgentHistoryTool(rawValue: tool) }

    /// 对上了的那份记录（工具 + 会话 ID）；新会话、认不出的工具为 nil。
    var key: AgentHistoryPinKey? {
        guard let agentTool, let sessionID, !sessionID.isEmpty else { return nil }
        return AgentHistoryPinKey(tool: agentTool, sessionID: sessionID)
    }
}

/// 一个 Code 标签页记下来的样子：它在哪台主机、里面跑着哪些会话、右边当时看的是哪一个。
nonisolated struct CodeTabRecord: Codable, Equatable, Sendable {
    /// 标签页的 id。Mac 的布局树里记的就是它（和终端标签的会话 id 并列），重启后用同一个 id 开回来。
    var id: UUID
    /// 哪台主机（`ServerProfile.id`）。Mac 本机终端窗口里的为 nil。
    var host: UUID?
    /// 主机名（Mac 的 SSH 终端区用作标签页的名字，同保持进程归属里记的终端标签名）。
    var hostName: String?
    /// 「＋」新会话默认开在哪个目录。
    var directory: String?
    var runs: [CodeRunRecord]
    /// 右边看的是哪个跑着的会话（`CodeRunRecord.session`）。
    var selectedRun: UUID?
    /// 右边看的是哪份只读记录（`AgentHistoryPinKey.stored`，`工具:会话 ID`）。
    var selectedRecord: String?

    init(id: UUID, host: UUID? = nil, hostName: String? = nil, directory: String? = nil, runs: [CodeRunRecord] = [],
         selectedRun: UUID? = nil, selectedRecord: String? = nil) {
        self.id = id
        self.host = host
        self.hostName = hostName
        self.directory = directory
        self.runs = runs
        self.selectedRun = selectedRun
        self.selectedRecord = selectedRecord
    }

    /// 接回时放进这个标签页的会话：工具认得出、会话还活着（`live`）。同一个会话只算一次。其余的（认不出的工具）
    /// 留给宿主照普通终端标签页接回，不丢。
    func adoptableRuns(live: Set<UUID>) -> [CodeRunRecord] {
        var seen: Set<UUID> = []
        return runs.filter { run in
            run.agentTool != nil && live.contains(run.session) && seen.insert(run.session).inserted
        }
    }

    /// 几个 Code 标签页一起接回时各自放进去的会话：一个会话只进一个标签页（先到先得）。
    static func adoptableRuns(_ tabs: [CodeTabRecord], live: Set<UUID>) -> [UUID: [CodeRunRecord]] {
        var remaining = live
        var result: [UUID: [CodeRunRecord]] = [:]
        for tab in tabs where result[tab.id] == nil {
            let runs = tab.adoptableRuns(live: remaining)
            remaining.subtract(runs.map(\.session))
            result[tab.id] = runs
        }
        return result
    }
}
