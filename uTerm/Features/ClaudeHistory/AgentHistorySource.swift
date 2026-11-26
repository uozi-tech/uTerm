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
    /// 哪种工具的记录。数据源建项目时填自己的；不同工具的项目 `id` 可能相同，比较与去重要连它一起看。
    var tool: AgentHistoryTool = .claude
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

    /// 哪种工具的记录（跟着所在的项目走）。
    var tool: AgentHistoryTool { project.tool }

    /// 内存缓存的键：路径、大小、修改时间都没变才算同一份。
    var cacheKey: CacheKey { CacheKey(path: path, size: size, modifiedAt: modifiedAt) }

    nonisolated struct CacheKey: Hashable, Sendable {
        let path: String
        let size: UInt64
        let modifiedAt: Date
    }
}

extension AgentHistorySessionFile {
    /// 列表的先后：修改时间新的在前；同一刻的按工具、路径定。
    /// 只比修改时间不够：同步、备份恢复、批量清理会把几百份记录改成同一刻（实测 548 份落在同一纳秒），
    /// 打平的谁先谁后就看这一趟各项目、各工具列完的先后，每次重列都换个样。
    nonisolated static func newestFirst(_ a: Self, _ b: Self) -> Bool {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
        if a.tool != b.tool { return a.tool.rawValue < b.tool.rawValue }
        return a.path < b.path
    }
}

extension AgentHistoryProject {
    /// 项目的先后：修改时间新的在前（没有的最后）；同一刻的按工具、路径定（理由同 `AgentHistorySessionFile.newestFirst`）。
    nonisolated static func newestFirst(_ a: Self, _ b: Self) -> Bool {
        let left = a.modifiedAt ?? .distantPast, right = b.modifiedAt ?? .distantPast
        if left != right { return left > right }
        if a.tool != b.tool { return a.tool.rawValue < b.tool.rawValue }
        return a.path < b.path
    }
}

extension AgentSubagentFile {
    /// 子代理的先后：修改时间新的在前（没有的最后）；同一刻的按路径定（理由同 `AgentHistorySessionFile.newestFirst`）。
    nonisolated static func newestFirst(_ a: Self, _ b: Self) -> Bool {
        let left = a.modifiedAt ?? .distantPast, right = b.modifiedAt ?? .distantPast
        return left != right ? left > right : a.path < b.path
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
    /// 这段对话后来接着在哪一份记录里往下聊（那一份的会话 ID）。Claude Code 上下文满了接着来时不往原来的文件里续写，
    /// 另起一份新记录，在旧的末尾记一行 `continued-in`。没有为 nil。
    var continuedIn: String? = nil
    /// 记录里最后一次记下的账号额度与它的时间（Codex 每次回答都带一份）。侧栏底部取所有会话里最新的一份。
    var rateLimits: AgentRateLimits? = nil
    var rateLimitsAt: Date? = nil
}

/// 「接着往下聊」串起来的几份记录（Claude Code 上下文满了另起一份新记录，标题照抄）：列表里只出最新那一份，
/// 前面的藏起来、从记录顶上翻回去。两端共用，纯函数。
nonisolated enum AgentHistoryContinuation {
    /// 一份记录在这条链上的前后。
    enum Link: Equatable, Sendable {
        /// 这一份是接着前面那份往下聊的。
        case previous(AgentHistorySessionFile)
        /// 这一份后来接着在别的记录里往下聊（顺着走到最新那一份）。
        case next(AgentHistorySessionFile)
    }

    /// 顺着 `continuedIn` 走到最新那一份（同一种工具、在 `files` 里的）；没有接着的、接着的那份不在列表里为 nil。
    static func latest(of file: AgentHistorySessionFile, in files: [AgentHistorySessionFile],
                       metadata: [String: AgentHistorySessionMetadata]) -> AgentHistorySessionFile? {
        var current = file
        var seen: Set<String> = [file.path]
        while let id = metadata[current.path]?.continuedIn,
              let next = files.first(where: { $0.tool == current.tool && $0.sessionID == id }),
              seen.insert(next.path).inserted {
            current = next
        }
        return current.path == file.path ? nil : current
    }

    /// 列表里不出这一行：它后来接着在列表里的另一份记录里往下聊了。
    static func isSuperseded(_ file: AgentHistorySessionFile, in files: [AgentHistorySessionFile],
                             metadata: [String: AgentHistorySessionMetadata]) -> Bool {
        guard let id = metadata[file.path]?.continuedIn else { return false }
        return files.contains { $0.tool == file.tool && $0.sessionID == id && $0.path != file.path }
    }

    /// 这一份是接着哪一份往下聊的（那一份的信息读到了才知道）。
    static func previous(of file: AgentHistorySessionFile, in files: [AgentHistorySessionFile],
                         metadata: [String: AgentHistorySessionMetadata]) -> AgentHistorySessionFile? {
        files.first { $0.tool == file.tool && $0.path != file.path && metadata[$0.path]?.continuedIn == file.sessionID }
    }

    /// 记录顶上要给的那个入口：后来接着聊了的给「看后来的」，接着前面聊的给「看之前的」。
    static func link(of file: AgentHistorySessionFile, in files: [AgentHistorySessionFile],
                     metadata: [String: AgentHistorySessionMetadata]) -> Link? {
        if let next = latest(of: file, in: files, metadata: metadata) { return .next(next) }
        return previous(of: file, in: files, metadata: metadata).map(Link.previous)
    }
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
    /// 哪种工具的记录。
    var tool: AgentHistoryTool = .claude

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

/// 某一种编码工具（`AgentHistoryTool`）的历史记录在一台主机上怎么找、怎么读。每种工具一份实现
/// （Claude Code 是 `ClaudeHistorySource`），界面与模型（`AgentHistoryModel`）只认这个协议。
///
/// 只读：实现不能往主机上写任何东西（包括临时文件），唯一的例外是用户在列表里点了「删除」（`delete`）。读到的对话内容只放内存。
///
/// 记录不是「一个会话一个按行写的文件」的工具（SQLite、压缩过的文件）照样套这几个类型：
/// `AgentHistorySessionFile.path` 是那份记录的文件，`AgentTranscriptAnchor.lineOffset` 是数据源自己定的位置
/// （按行写的文件是行的偏移，别的可以是第几条），条目 ID 在一份记录里唯一且稳定即可。
protocol AgentHistorySource: Actor {
    /// 这份实现读的是哪种工具的记录。它建出来的项目、子代理记录都要带上（`AgentHistoryProject.tool` /
    /// `AgentSubagentFile.tool`），几种工具合在一起列的时候靠它分给对应的数据源。
    nonisolated var tool: AgentHistoryTool { get }
    /// 能不能跨会话搜索。不能的（记录的格式没法在主机上找）界面会说明这种工具的会话不参与搜索，也不会调 `search`。
    nonisolated var supportsSearch: Bool { get }
    /// 这台主机上有没有这个 Agent 的记录。没有时 `projects()` 也返回空，界面据此显示空态。
    func projects() async throws -> [AgentHistoryProject]
    /// 终端当前目录落在哪个项目里（自己或最近的上级目录）。
    func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject?
    /// 项目里的会话，新的在前。
    func sessions(in project: AgentHistoryProject) async throws -> [AgentHistorySessionFile]
    /// 「全部项目」：所有项目的会话合在一起，新的在前；列不了的项目跳过。
    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile]
    /// 同 `allSessions`，另外报出这一趟列不出来的项目（`AgentHistoryProject.id` + 工具）。后台重列时据此留着那些项目上一次
    /// 列到的会话，一次没列出来（断线、辅助程序重启）不能让它们从侧栏上消失。不能逐个项目报的实现用默认的（不报失败）。
    func listAllSessions(in projects: [AgentHistoryProject]) async -> AgentHistorySessionListing
    /// 列表一行的信息。实现自己按 `cacheKey` 缓存。
    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata
    /// 一页一页往前读对话。
    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging
    /// 从某一行打开（搜索命中处）：先读那一行和它前面一页，后面的按需往后一页一页读（`loadNext`），读到文件末尾之后
    /// 才接上实时跟随。条目 ID 与 `transcript(for:)` 读出来的一致。
    nonisolated func transcript(for file: AgentHistorySessionFile, around anchor: AgentTranscriptAnchor) -> any AgentTranscriptPaging
    /// 在这些会话里搜（只搜主对话；只出列表里会列出来的），最近的会话先报，一批一批交给 `onEvent`。在主机上跑命令找，
    /// 不把记录下载回来。任务被取消后不再发新的命令。跑不了命令的主机抛 `AgentHistorySearchError.cannotExecute`。
    func search(_ query: AgentHistorySearchQuery, in files: [AgentHistorySessionFile], limits: AgentHistorySearchLimits,
                onEvent: @escaping @Sendable (AgentHistorySearchEvent) async -> Void) async throws
    /// 子代理的记录，和主对话同一套读法与显示。
    nonisolated func subagentTranscript(for subagent: AgentSubagentFile) -> any AgentTranscriptPaging
    /// 这份记录（主对话或子代理的）派出的子代理留下了哪些记录。**懒**：打开对话、读到派子代理的调用时才调，
    /// 列表阶段不碰。没有记录（目录不存在、被清了）返回空；别的错误（断线、没权限）照常抛，下次再试。
    func subagents(of target: AgentTranscriptTarget) async throws -> [AgentSubagentFile]
    /// 子代理附带的信息（`hasInfo` 为 true 的才有）。实现自己缓存；读不了为 nil。
    func info(of subagent: AgentSubagentFile) async -> AgentSubagentInfo?
    /// 在终端里继续这个会话要敲的命令；ID 或目录不合法时为 nil。这种工具没法在终端里继续的一律 nil（界面不出按钮）。
    nonisolated func resumeCommand(sessionID: String, directory: String) -> String?
    /// 在这个目录里新开一个会话要敲的命令；目录不合法、或者这种工具不是在终端里用的为 nil。
    nonisolated func newSessionCommand(directory: String) -> String?
    /// 能不能删掉一个会话的记录。一个会话就是一个（或一组）只属于它的文件的工具能；好几个会话存在同一个数据库里的
    /// （Antigravity）不能：删文件会连别的会话一起删掉。
    nonisolated var supportsDelete: Bool { get }
    /// 删掉这个会话在主机上的记录（用户在列表里点了「删除」、确认过）。删不掉照常抛；主记录删了、附带的文件
    /// （子代理的记录等）没删干净不算失败。
    func delete(_ file: AgentHistorySessionFile) async throws
    /// 能不能改会话的名字（写回记录，这种工具自己也认）。
    nonisolated var supportsRename: Bool { get }
    /// 把会话的名字改成 `title`（已去掉首尾空白、非空）。改不了照常抛。
    func rename(_ file: AgentHistorySessionFile, to title: String) async throws
}

extension AgentHistorySource {
    func listAllSessions(in projects: [AgentHistoryProject]) async -> AgentHistorySessionListing {
        AgentHistorySessionListing(files: await allSessions(in: projects))
    }

    nonisolated var supportsSearch: Bool { true }
    nonisolated func newSessionCommand(directory: String) -> String? { nil }
    nonisolated var supportsDelete: Bool { false }
    func delete(_ file: AgentHistorySessionFile) async throws { throw AgentHistoryDeleteError.unsupported }
    nonisolated var supportsRename: Bool { false }
    func rename(_ file: AgentHistorySessionFile, to title: String) async throws { throw AgentHistoryDeleteError.renameUnsupported }
}

nonisolated enum AgentHistoryDeleteError: LocalizedError {
    /// 这种工具的会话不能单独删（见 `AgentHistorySource.supportsDelete`）。
    case unsupported
    /// 这种工具的会话不能在 uTerm 里改名（见 `AgentHistorySource.supportsRename`）。
    case renameUnsupported

    var errorDescription: String? {
        switch self {
        case .unsupported: return String(localized: "这种工具的会话不能在 uTerm 里删除")
        case .renameUnsupported: return String(localized: "这种工具的会话不能在 uTerm 里重命名")
        }
    }
}

/// 「全部项目」列一趟的结果：会话（新的在前）与列不出来的项目。
nonisolated struct AgentHistorySessionListing: Sendable {
    var files: [AgentHistorySessionFile]
    /// 列不出来的项目：`AgentHistoryProjectKey`。
    var failedProjects: Set<AgentHistoryProjectKey> = []
}

/// 一个项目的身份（不同工具的项目 `id` 可能相同，要连工具一起认）。
nonisolated struct AgentHistoryProjectKey: Hashable, Sendable {
    let tool: AgentHistoryTool
    let id: String

    init(_ project: AgentHistoryProject) {
        tool = project.tool
        id = project.id
    }
}

/// 一页一页往前读一份对话；读到末尾之后还能接着读文件新长出来的部分（会话还开着）。
protocol AgentTranscriptPaging: Actor {
    /// 再往前读一页，返回按时间先后排的条目。`reachedStart` 为 true 时前面没有了。
    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool)
    /// 看一次文件末尾，读新写进来的部分。第一次 `loadPrevious` 读过末尾之前什么都不做（`.unchanged`）；
    /// 从某一行打开的，往后一页页读到文件末尾之前也什么都不做。
    func loadNewer() async throws -> AgentTranscriptGrowth
    /// 从某一行打开的：再往后读一页。`.appended(_, hasMore: false)` = 读到了文件末尾（之后交给 `loadNewer`）；
    /// 从末尾打开的一律 `.unchanged`。
    func loadNext() async throws -> AgentTranscriptGrowth
}

extension AgentTranscriptPaging {
    func loadNext() async throws -> AgentTranscriptGrowth { .unchanged }
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
