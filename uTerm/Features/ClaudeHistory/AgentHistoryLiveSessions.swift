import Foundation

/// 主机上正在运行的一个会话（不管是在哪开的：本设备的 Code 标签页、普通终端、iTerm、另一台设备）。
/// 由数据源读出来（`AgentHistorySource.liveSessions`；Claude Code 是 `~/.claude/sessions/<pid>.json`，见 `ClaudeLiveSessions`），
/// 侧栏只用它排序和在行的右端标状态，不能拿它点回终端、结束会话（那些只对本设备 Code 标签页里的会话有）。
///
/// 只放不常变的字段：列表露着时隔几秒读一次，带着「最后更新时间」这类每次都变的字段，表就每次都不一样、列表跟着重画。
nonisolated struct AgentLiveSession: Hashable, Sendable {
    /// 会话此刻在干什么（工具报的原样归成这几种）。
    enum State: Hashable, Sendable {
        /// 正在干活（Claude Code 的 `busy`）。
        case working
        /// 停在输入框（`idle`）。
        case idle
        /// 等人处理（等确认、等回答）。
        case waiting
        /// 没报、或者报了不认识的（`shell` 之类）：同 Code 标签页里还没报过状态的会话。
        case unknown
    }

    let tool: AgentHistoryTool
    /// 会话 ID（记录文件名去掉扩展名的那个）。
    let sessionID: String
    let pid: Int
    /// 它的工作目录；没写为 nil。
    let directory: String?
    let state: State

    /// 侧栏里按什么画、怎么排（规则同 Code 标签页里的会话，见 `CodeRunStatus`）：正在干活 = 运行中（灰色呼吸灯），
    /// 空闲不标，等人处理 = 黄点，没报 = 同还没报过状态的会话（不标，排在停在输入框的那一档）。
    var runStatus: CodeRunStatus {
        let app = tool == .claude ? "claude-code" : nil
        switch state {
        case .working: return .program(ProgramStatusRecord(state: .working, app: app))
        case .idle: return .program(ProgramStatusRecord(state: .idle, app: app))
        case .waiting: return .program(ProgramStatusRecord(state: .blocked, app: app))
        case .unknown: return .unreported
        }
    }

    /// 同一工具、同一会话 ID（大小写不论）。
    var key: Key { Key(tool: tool, sessionID: sessionID.lowercased()) }

    struct Key: Hashable, Sendable {
        let tool: AgentHistoryTool
        let sessionID: String
    }

    /// 列表里比较、去重用的先后：工具、会话 ID。数据源读出来的先后取决于目录列出来的先后，排一下再交给模型，
    /// 没变就不算变。
    static func ordered(_ sessions: [AgentLiveSession]) -> [AgentLiveSession] {
        sessions.sorted { ($0.tool.rawValue, $0.sessionID.lowercased(), $0.pid) < ($1.tool.rawValue, $1.sessionID.lowercased(), $1.pid) }
    }
}

/// 主机上正在运行的会话对到列表里的记录上。两端共用，纯函数。
nonisolated enum AgentHistoryLiveRuns {
    /// 记录路径 → 那个会话在主机上此刻的状态。会话 ID 对上列表里的记录（同一种工具）；那份记录后来接着在另一份里
    /// 往下聊了的（`AgentHistoryContinuation`），算到最新那一份上（列表里只出它）。对不上的不要。同一份记录有几个
    /// 会话对上时取最要紧的那个。
    static func statuses(_ live: [AgentLiveSession], files: [AgentHistorySessionFile],
                         metadata: [String: AgentHistorySessionMetadata]) -> [String: CodeRunStatus] {
        guard !live.isEmpty else { return [:] }
        let wanted = Set(live.map(\.key))
        var byKey: [AgentLiveSession.Key: AgentHistorySessionFile] = [:]
        for file in files {
            let key = AgentLiveSession.Key(tool: file.tool, sessionID: file.sessionID.lowercased())
            if wanted.contains(key), byKey[key] == nil { byKey[key] = file }
        }
        var result: [String: CodeRunStatus] = [:]
        for session in live {
            guard let file = byKey[session.key] else { continue }
            let target = AgentHistoryContinuation.latest(of: file, in: files, metadata: metadata) ?? file
            result[target.path] = CodeRunStatus.merging(result[target.path], host: session.runStatus)
        }
        return result
    }
}

nonisolated extension CodeRunStatus {
    /// 侧栏一行的状态，两路合起来：本设备 Code 标签页里跑着的那个（`local`，经 OSC 7501 报的）与主机上读到的
    /// （`host`，`AgentLiveSession.runStatus`）。只有一路就用它；两路都有取更要紧的那个（`listRank` 高的；同一档两边都报了
    /// 状态时看 `ProgramState.priority`），一样要紧用本设备的（带着等的是什么、消息）。两路都没有 = 没在跑（`.unreported`，
    /// 行上不标；排序看 `listRank(local:host:)`）。
    static func merging(_ local: CodeRunStatus?, host: CodeRunStatus?) -> CodeRunStatus {
        guard let local else { return host ?? .unreported }
        guard let host else { return local }
        return host.urgency > local.urgency ? host : local
    }

    /// 排序用的档（`AgentHistoryListing.prioritizingRuns`）：两路都没有为 0（不往前挪），否则同合起来的那个。
    static func listRank(local: CodeRunStatus?, host: CodeRunStatus?) -> Int {
        max(local?.listRank ?? 0, host?.listRank ?? 0)
    }

    private var urgency: (Int, Int) {
        switch self {
        case .program(let record): (listRank, record.state.priority)
        case .unreported, .ended: (listRank, -1)
        }
    }
}

nonisolated extension AgentHistoryRunPlacement {
    /// 收起的组标题上那个点照哪些会话（`CodeRunGroupMark`）：本设备跑着、列表里没有记录行的那几个照它自己的状态；
    /// 组里每一行，本设备跑着的、主机上跑着的，两路合起来（`CodeRunStatus.merging`）。
    func statuses(in group: AgentHistoryGroup, status: (Run) -> CodeRunStatus,
                  host: (String) -> CodeRunStatus?) -> [CodeRunStatus] {
        leading(in: group).map(status) + group.files.compactMap { file in
            let local = inList[file.path].map(status)
            let remote = host(file.path)
            guard local != nil || remote != nil else { return nil }
            return CodeRunStatus.merging(local, host: remote)
        }
    }
}

/// 列表露着时隔多久读一次主机上在跑的会话（测试换成不真睡的）。
nonisolated struct AgentHistoryLiveTiming: Sendable {
    var interval: Duration
    /// 连续读不到时间隔翻倍，最多拉到这么长（断线、主机跑不了命令）。
    var maxBackoff: Duration
    var sleep: @Sendable (Duration) async throws -> Void

    /// 实测本机（31 个在跑，经辅助程序）读一次约 190 ms，几乎都花在每个进程起一次 `ps` 上；SSH 上再加一次 exec 往返。
    /// 4 秒一次：状态变了几秒内跟上，又不至于一直占着辅助程序。
    static let standard = AgentHistoryLiveTiming(interval: .seconds(4), maxBackoff: .seconds(60),
                                                 sleep: { try await Task.sleep(for: $0) })

    func delay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return interval }
        var delay = interval
        for _ in 0..<min(failures, 16) {
            delay *= 2
            if delay >= maxBackoff { return maxBackoff }
        }
        return delay
    }
}
