import Foundation

/// 一个项目：Agent 在某个工作目录下的全部会话。
nonisolated struct AgentHistoryProject: Hashable, Sendable, Identifiable {
    /// 记录目录的名字（Claude：工作目录换出来的 `-Users-a-proj`）。
    let id: String
    /// 记录目录的绝对路径。
    let path: String
    let modifiedAt: Date?
    /// 能确定的工作目录（由终端的当前目录对上的）；对不上为 nil。
    var directory: String?
}

/// 一个会话的记录文件。
nonisolated struct AgentHistorySessionFile: Hashable, Sendable, Identifiable {
    /// 会话 ID（文件名去掉扩展名）。
    let sessionID: String
    let project: AgentHistoryProject
    let path: String
    let size: UInt64
    let modifiedAt: Date

    var id: String { path }

    /// 内存缓存的键：路径、大小、修改时间都没变才算同一份。
    var cacheKey: CacheKey { CacheKey(path: path, size: size, modifiedAt: modifiedAt) }

    nonisolated struct CacheKey: Hashable, Sendable {
        let path: String
        let size: UInt64
        let modifiedAt: Date
    }
}

/// 列表一行要的东西。只读记录的末尾（必要时加开头）一小块得到。
nonisolated struct AgentHistorySessionMetadata: Equatable, Sendable {
    var title: String?
    /// 要不要列出来（Claude：只列命令行起的）。
    var isListed: Bool
    /// 记录里最近一次的工作目录。
    var lastDirectory: String?
    /// 该在哪个目录里继续这个会话；确定不了为 nil。
    var resumeDirectory: String?
    var gitBranch: String?
    var lastActivity: Date?
}

/// 一份对话里派出的一个子代理留下的记录。怎么找到它是数据源的事（Claude：会话目录下的 `subagents/`），
/// 界面与模型只认这个值。
nonisolated struct AgentSubagentFile: Hashable, Sendable, Identifiable {
    /// 子代理的 ID（结果里报的那个，用来和派它的调用对上）。
    let agentID: String
    let path: String
    /// 列目录时拿到的大小；拿不到为 nil（只用来在入口上提示多大）。
    let size: UInt64?
    let modifiedAt: Date?
    /// 有没有一份附带的小文件写着它是哪次调用派出的（Claude：`agent-<ID>.meta.json`）。没有就只能靠调用的结果对上。
    let hasInfo: Bool

    var id: String { path }
}

/// 子代理附带的信息：哪次调用派出的、什么类型、派的时候写的描述。
nonisolated struct AgentSubagentInfo: Equatable, Sendable {
    var toolUseID: String?
    var agentType: String?
    var description: String?
}

/// 打开的是哪一份记录：主对话，或者其中派出的某个子代理的记录。
nonisolated enum AgentTranscriptTarget: Hashable, Sendable {
    case session(AgentHistorySessionFile)
    case subagent(AgentSubagentFile)

    var path: String {
        switch self {
        case .session(let file): return file.path
        case .subagent(let subagent): return subagent.path
        }
    }
}

/// 某个 Agent 的历史记录在一台主机上怎么找、怎么读。现在只有 Claude Code（`ClaudeHistorySource`）；
/// 以后加 Codex 再写一份实现，界面与模型（`AgentHistoryModel`）不用动。
///
/// 只读：实现不能往主机上写任何东西。
protocol AgentHistorySource: Actor {
    /// 这台主机上有没有这个 Agent 的记录。没有时 `projects()` 也返回空，界面据此显示空态。
    func projects() async throws -> [AgentHistoryProject]
    /// 终端当前目录落在哪个项目里（自己或最近的上级目录）。
    func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject?
    /// 项目里的会话，新的在前。
    func sessions(in project: AgentHistoryProject) async throws -> [AgentHistorySessionFile]
    /// 「全部项目」：所有项目的会话合在一起，新的在前；列不了的项目跳过。
    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile]
    /// 列表一行的信息。实现自己按 `cacheKey` 缓存。
    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata
    /// 一页一页往前读对话。
    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging
    /// 子代理的记录，和主对话同一套读法与显示。
    nonisolated func subagentTranscript(for subagent: AgentSubagentFile) -> any AgentTranscriptPaging
    /// 这份记录（主对话或子代理的）派出的子代理留下了哪些记录。**懒**：打开对话、读到派子代理的调用时才调，
    /// 列表阶段不碰。没有记录（目录不存在、被清了）返回空；别的错误（断线、没权限）照常抛，下次再试。
    func subagents(of target: AgentTranscriptTarget) async throws -> [AgentSubagentFile]
    /// 子代理附带的信息（`hasInfo` 为 true 的才有）。实现自己缓存；读不了为 nil。
    func info(of subagent: AgentSubagentFile) async -> AgentSubagentInfo?
    /// 在终端里继续这个会话要敲的命令；ID 或目录不合法时为 nil。
    nonisolated func resumeCommand(sessionID: String, directory: String) -> String?
}

/// 一页一页往前读一份对话；读到末尾之后还能接着读文件新长出来的部分（会话还开着）。
protocol AgentTranscriptPaging: Actor {
    /// 再往前读一页，返回按时间先后排的条目。`reachedStart` 为 true 时前面没有了。
    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool)
    /// 看一次文件末尾，读新写进来的部分。第一次 `loadPrevious` 读过末尾之前什么都不做（`.unchanged`）。
    func loadNewer() async throws -> AgentTranscriptGrowth
}

/// 看一次文件末尾的结果。
nonisolated enum AgentTranscriptGrowth: Equatable, Sendable {
    /// 没变长。
    case unchanged
    /// 变长了：新读到的条目（可能为空——新写的只是不显示的行，或者最后一行还没写完）。
    /// `hasMore`：一下子长了很多、这次只读了一部分，接着读，不用等下一拍。
    case appended([AgentTranscriptItem], hasMore: Bool)
    /// 比已经读到的位置还短：文件被截断或换掉了，整份要从末尾重读。
    case replaced
}
