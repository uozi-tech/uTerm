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
    /// 在终端里继续这个会话要敲的命令；ID 或目录不合法时为 nil。
    nonisolated func resumeCommand(sessionID: String, directory: String) -> String?
}

/// 一页一页往前读一份对话。
protocol AgentTranscriptPaging: Actor {
    /// 再往前读一页，返回按时间先后排的条目。`reachedStart` 为 true 时前面没有了。
    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool)
}
