import Foundation
import Synchronization

/// 一台主机上 Antigravity 的历史会话，经任意 `SFTPProviding` 只读地访问。
///
/// 两个数据目录，记录格式相同：
/// - `~/.gemini/antigravity`：桌面版。会话没法在终端里继续（`agentapi` 只是给 Agent 用的接口，要桌面版开着）。
/// - `~/.gemini/antigravity-cli`：命令行 `agy`。能 `agy --conversation <会话 ID>` 接着用（公开文档的写法）。
///
/// 每个会话一个目录 `brain/<会话 ID>/`，对话在 `.system_generated/logs/transcript_full.jsonl`（一行一步、只往后追加；
/// 旁边的 `chunks/` 是同一份按 100 KB 切开的副本，不用读）。会话属于哪个工作区、标题，`brain/` 里都没有，
/// 要问 `AntigravityConversationIndex`（数据目录里的 SQLite）；问不到时标题取第一句你说的话（或 `annotations/` 里的），
/// 会话都归到「没有工作区」那一组（`noWorkspaceProjectID`）。
///
/// 项目 = 工作区目录：几个数据目录里同一个工作区的会话并在一组。
actor AntigravityHistorySource: AgentHistorySource {
    nonisolated var tool: AgentHistoryTool { .antigravity }

    /// 数据目录是哪个入口写的。
    nonisolated enum Origin: Sendable, Equatable {
        case app, cli
    }

    nonisolated struct DataRoot: Sendable, Equatable {
        /// 相对主目录。
        let relativePath: String
        let origin: Origin
    }

    nonisolated static let dataRoots = [DataRoot(relativePath: ".gemini/antigravity", origin: .app),
                            DataRoot(relativePath: ".gemini/antigravity-cli", origin: .cli)]

    /// 没有打开文件夹的会话归在这一组（`directory` 为 nil）。界面显示它的名字时别用这个 ID。
    nonisolated static let noWorkspaceProjectID = "antigravity:no-workspace"

    /// 会话目录下记录的相对位置。先找完整的那份，没有再用删节版。
    nonisolated static let logsDirectory = ".system_generated/logs"
    nonisolated static let fullTranscriptName = "transcript_full.jsonl"
    nonisolated static let shortTranscriptName = "transcript.jsonl"

    /// 列表一行读末尾这么多（最后的时间、有没有对话），开头再读这么多（第一句你说的话当标题）。本机实测一行最长 50 KB。
    nonisolated static let tailBytes = 64 * 1024
    nonisolated static let headBytes = 64 * 1024
    /// 标题文件只有一两百字节。
    nonisolated static let annotationBytes = 4 * 1024
    /// 同时列几个会话目录。
    nonisolated static let listConcurrency = 6

    let provider: any SFTPProviding
    let index: any AntigravityConversationIndex
    let roots: [DataRoot]
    /// 搜索时一批交多少份（测试换成小的，好看出分批）。
    let searchBatching: ClaudeSearchBatching

    private var home: String?
    /// 上一次 `projects()` 列到的会话。
    private var conversations: [Conversation]?
    private var cache: [AgentHistorySessionFile.CacheKey: AgentHistorySessionMetadata] = [:]
    /// 命令行写的会话 ID、有没有命令行的数据目录：`resumeCommand` / `newSessionCommand` 是 nonisolated 的，放锁里。
    private let cliState = Mutex(CLIState())

    private nonisolated struct CLIState: Sendable {
        var sessionIDs: Set<String> = []
        var isInstalled = false
    }

    /// 一个会话：在哪个数据目录、`brain/` 下的目录、Antigravity 记着的信息。
    nonisolated struct Conversation: Sendable, Equatable {
        let id: String
        let root: String
        let origin: Origin
        let modifiedAt: Date?
        let info: AntigravityConversationInfo?

        var directory: String { root + "/brain/" + id }
        var logs: String { directory + "/" + AntigravityHistorySource.logsDirectory }
        var projectID: String { info?.workspace ?? AntigravityHistorySource.noWorkspaceProjectID }
    }

    /// `home`：主目录。不给就问 `provider`（`realPath(".")`）；测试给一个临时目录。
    /// `index`：数据目录里 SQLite 的读取（工作区、标题）；不给就只靠 `brain/` 下的记录。
    init(provider: any SFTPProviding, home: String? = nil,
         index: any AntigravityConversationIndex = AntigravityNoConversationIndex(),
         roots: [DataRoot] = AntigravityHistorySource.dataRoots,
         searchBatching: ClaudeSearchBatching = .standard) {
        self.provider = provider
        self.home = home
        self.index = index
        self.roots = roots
        self.searchBatching = searchBatching
    }

    func homeDirectory() async throws -> String {
        if let home { return home }
        let resolved = try await provider.realPath(".")
        home = resolved
        return resolved
    }

    // MARK: 项目与会话

    func projects() async throws -> [AgentHistoryProject] {
        let found = try await listConversations()
        conversations = found
        var projects: [String: AgentHistoryProject] = [:]
        for conversation in found {
            let id = conversation.projectID
            if let existing = projects[id] {
                if (conversation.modifiedAt ?? .distantPast) > (existing.modifiedAt ?? .distantPast) {
                    projects[id] = AgentHistoryProject(id: id, path: existing.path, modifiedAt: conversation.modifiedAt,
                                                       directory: existing.directory, tool: .antigravity)
                }
            } else {
                projects[id] = AgentHistoryProject(id: id, path: conversation.root + "/brain", modifiedAt: conversation.modifiedAt,
                                                   directory: conversation.info?.workspace, tool: .antigravity)
            }
        }
        return projects.values.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// 列每个数据目录的 `brain/`，问一次 SQLite。目录不存在 = 没用过那个入口；别的错误（没权限、断线）照常报。
    private func listConversations() async throws -> [Conversation] {
        let home = try await homeDirectory()
        var found: [Conversation] = []
        var cliIDs: Set<String> = []
        for root in roots {
            let rootPath = home + "/" + root.relativePath
            let brain = rootPath + "/brain"
            let entries: [RemoteEntry]
            do {
                entries = try await provider.list(path: brain)
            } catch {
                if (try? await provider.stat(brain)) == nil { continue }
                throw error
            }
            let infos = (try? await index.conversations(root: rootPath, provider: provider)) ?? [:]
            for entry in entries where (entry.isDirectory || entry.isSymlink) && Self.isConversationName(entry.name) {
                let info = infos[entry.name]
                found.append(Conversation(id: entry.name, root: rootPath, origin: root.origin,
                                          modifiedAt: info?.lastModified ?? entry.modifiedAt, info: info))
                if root.origin == .cli { cliIDs.insert(entry.name.lowercased()) }
            }
        }
        // 「用过命令行」= 它的 `brain/` 里有会话（有的 SFTP 实现列不存在的目录不报错，只回空）。
        let hasCLI = !cliIDs.isEmpty
        cliState.withLock {
            $0.sessionIDs = cliIDs
            $0.isInstalled = hasCLI
        }
        return found
    }

    /// 目录名能当会话 ID 用：不是隐藏目录，没有控制字符（搜索时它要进命令）。
    nonisolated static func isConversationName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
            && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject? {
        let target = Self.normalized(directory)
        var best: AgentHistoryProject?
        for project in projects where project.tool == .antigravity {
            guard let candidate = project.directory.map(Self.normalized) else { continue }
            let inside = target == candidate || candidate == "/" || target.hasPrefix(candidate + "/")
            if inside, candidate.count > (best?.directory.map(Self.normalized)?.count ?? -1) { best = project }
        }
        return best
    }

    nonisolated static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    func sessions(in project: AgentHistoryProject) async throws -> [AgentHistorySessionFile] {
        let all = try await currentConversations()
        return await files(for: all.filter { $0.projectID == project.id }.map { ($0, project) })
    }

    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile] {
        guard let all = try? await currentConversations() else { return [] }
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return await files(for: all.compactMap { conversation in byID[conversation.projectID].map { (conversation, $0) } })
    }

    private func currentConversations() async throws -> [Conversation] {
        if let conversations { return conversations }
        let found = try await listConversations()
        conversations = found
        return found
    }

    /// 每个会话列一次 `logs/`（一趟拿到大小和修改时间），没有记录的跳过。新的在前。
    private func files(for members: [(Conversation, AgentHistoryProject)]) async -> [AgentHistorySessionFile] {
        var result: [AgentHistorySessionFile] = []
        var next = 0
        let provider = provider
        await withTaskGroup(of: AgentHistorySessionFile?.self) { group in
            func launch() {
                let (conversation, project) = members[next]
                next += 1
                group.addTask { await Self.file(of: conversation, in: project, provider: provider) }
            }
            while next < min(Self.listConcurrency, members.count) { launch() }
            while let file = await group.next() {
                if let file { result.append(file) }
                if next < members.count { launch() }
            }
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private nonisolated static func file(of conversation: Conversation, in project: AgentHistoryProject,
                                         provider: any SFTPProviding) async -> AgentHistorySessionFile? {
        guard let entries = try? await provider.list(path: conversation.logs) else { return nil }
        let byName = Dictionary(entries.filter { !$0.isDirectory }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard let entry = byName[fullTranscriptName] ?? byName[shortTranscriptName] else { return nil }
        let path = conversation.logs + "/" + entry.name
        var size = entry.size
        var modified = entry.modifiedAt
        if size == nil || modified == nil, let stat = try? await provider.stat(path) {
            size = UInt64(max(0, stat.size))
            modified = stat.mtime
        }
        return AgentHistorySessionFile(sessionID: conversation.id, project: project, path: path,
                                       size: size ?? 0, modifiedAt: modified ?? .distantPast)
    }

    /// 记录文件 → 它的会话目录（`…/brain/<ID>`）。
    nonisolated static func conversationDirectory(ofTranscript path: String) -> String? {
        let suffix = "/" + logsDirectory + "/"
        guard let range = path.range(of: suffix, options: .backwards) else { return nil }
        return String(path[..<range.lowerBound])
    }

    // MARK: 列表一行

    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata {
        if let cached = cache[file.cacheKey] { return cached }
        let conversation = Self.conversationDirectory(ofTranscript: file.path).flatMap { directory in
            conversations?.first { $0.directory == directory }
        }
        let scan = try await Self.scan(file: file, provider: provider)
        var title = conversation?.info?.title
        if title == nil, let conversation {
            title = await annotationTitle(of: conversation)
        }
        title = title ?? scan.firstUserText.map { ClaudeSessionScan.singleLine($0) }
        let workspace = conversation?.info?.workspace ?? file.project.directory
        let metadata = AgentHistorySessionMetadata(
            title: title.flatMap { $0.isEmpty ? nil : $0 },
            // 整份都读过了却没有一句对话的不列：点开也什么都没有。
            isListed: scan.hasConversation || !scan.coversWholeFile,
            lastDirectory: workspace,
            resumeDirectory: workspace,
            gitBranch: nil,
            lastActivity: scan.lastTimestamp ?? conversation?.info?.lastModified)
        cache[file.cacheKey] = metadata
        return metadata
    }

    /// 桌面版给会话起的标题：`<数据目录>/annotations/<会话 ID>.pbtxt`。没有这个文件很正常。
    private func annotationTitle(of conversation: Conversation) async -> String? {
        let path = conversation.root + "/annotations/" + conversation.id + ".pbtxt"
        guard let data = try? await provider.readRange(path, offset: 0, length: Self.annotationBytes) else { return nil }
        return AntigravityAnnotation.title(in: data)
    }

    /// 读末尾一块和开头一块（文件小就只读一次）。
    nonisolated static func scan(file: AgentHistorySessionFile, provider: any SFTPProviding) async throws -> AntigravitySessionScan {
        let size = file.size
        let tailLength = Int(min(size, UInt64(tailBytes)))
        let tailOffset = size - UInt64(tailLength)
        let tail = try await provider.readRange(file.path, offset: tailOffset, length: tailLength)
        var scan = AntigravitySessionScan.scan(tail, dropsLeadingPartial: tailOffset > 0, dropsTrailingPartial: false)
        scan.coversWholeFile = tailOffset == 0
        guard tailOffset > 0 else { return scan }
        let headLength = Int(min(tailOffset, UInt64(headBytes)))
        let head = try await provider.readRange(file.path, offset: 0, length: headLength)
        let early = AntigravitySessionScan.scan(head, dropsLeadingPartial: false, dropsTrailingPartial: true)
        scan.firstUserText = early.firstUserText ?? scan.firstUserText
        scan.hasConversation = scan.hasConversation || early.hasConversation
        scan.coversWholeFile = UInt64(headLength) >= tailOffset
        return scan
    }

    // MARK: 对话

    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging {
        Self.pager(provider: provider, path: file.path, anchor: nil)
    }

    nonisolated func transcript(for file: AgentHistorySessionFile, around anchor: AgentTranscriptAnchor) -> any AgentTranscriptPaging {
        Self.pager(provider: provider, path: file.path, anchor: anchor)
    }

    nonisolated static func pager(provider: any SFTPProviding, path: String, anchor: AgentTranscriptAnchor?) -> ClaudeTranscriptPager {
        let encodedArgs = path.hasSuffix("/" + shortTranscriptName)
        return ClaudeTranscriptPager(provider: provider, path: path, anchor: anchor, lineParser: { line in
            AntigravityTranscriptParser.items(from: line, encodedArgs: encodedArgs)
        })
    }

    // MARK: 子会话

    // 派生的会话（`parent_conversation_id`）在 `brain/` 里也是一个普通的会话目录，记录里没有哪次调用派出了它，
    // 对不上调用就挂不到对话里。所以照常列成一个会话，这里不报子代理。

    func subagents(of target: AgentTranscriptTarget) async throws -> [AgentSubagentFile] { [] }

    func info(of subagent: AgentSubagentFile) async -> AgentSubagentInfo? { nil }

    nonisolated func subagentTranscript(for subagent: AgentSubagentFile) -> any AgentTranscriptPaging {
        Self.pager(provider: provider, path: subagent.path, anchor: nil)
    }

    // MARK: 继续 / 新开

    /// 只有命令行（`~/.gemini/antigravity-cli`）写的会话能继续；桌面版的要先在 `agy` 里导入（会复制成新会话），没法直接接上。
    nonisolated func resumeCommand(sessionID: String, directory: String) -> String? {
        guard cliState.withLock({ $0.sessionIDs.contains(sessionID.lowercased()) }) else { return nil }
        return AntigravityResumeCommand.resume(sessionID: sessionID, directory: directory)
    }

    /// 这台主机上用过命令行才给。
    nonisolated func newSessionCommand(directory: String) -> String? {
        guard cliState.withLock({ $0.isInstalled }) else { return nil }
        return AntigravityResumeCommand.newSession(directory: directory)
    }
}

/// 在终端里接着用 / 新开 `agy`。会话 ID 只收 UUID 的形状，目录按 POSIX shell 的单引号规则引起来（同 `ClaudeResumeCommand`）。
nonisolated enum AntigravityResumeCommand {
    static func resume(sessionID: String, directory: String) -> String? {
        guard ClaudeResumeCommand.isSessionID(sessionID),
              let quoted = ClaudeResumeCommand.quotedDirectory(directory) else { return nil }
        return "cd -- \(quoted) && agy --conversation \(sessionID.lowercased())"
    }

    static func newSession(directory: String) -> String? {
        guard let quoted = ClaudeResumeCommand.quotedDirectory(directory) else { return nil }
        return "cd -- \(quoted) && agy"
    }
}

/// 一块记录字节里捞到的会话信息：列表一行只读文件末尾和开头各一块，不完整解析。
nonisolated struct AntigravitySessionScan: Equatable, Sendable {
    /// 有没有真正的对话（你说的话、回答、工具调用）。
    var hasConversation = false
    /// 块里第一句你说的话（去掉系统附上的部分之后）。
    var firstUserText: String?
    var lastTimestamp: Date?
    /// 整份文件都在读过的块里。
    var coversWholeFile = false

    /// 你说的话最多多大才解析（本机实测四千字以内）。
    static let maxUserLineBytes = 256 * 1024

    static func scan(_ data: Data, dropsLeadingPartial: Bool, dropsTrailingPartial: Bool) -> AntigravitySessionScan {
        var scan = AntigravitySessionScan()
        scan.lastTimestamp = ClaudeJSONLScan.stringValues(forKey: "created_at", in: data)
            .reversed().lazy.compactMap(ClaudeTimestamp.parse).first
        for line in ClaudeJSONLScan.lines(in: data, dropsLeadingPartial: dropsLeadingPartial,
                                          dropsTrailingPartial: dropsTrailingPartial) {
            switch AntigravityTranscriptParser.type(ofHead: line) {
            case "PLANNER_RESPONSE", "GENERIC":
                scan.hasConversation = true
            case "USER_INPUT":
                guard scan.firstUserText == nil, line.count <= maxUserLineBytes else {
                    scan.hasConversation = true
                    continue
                }
                for item in AntigravityTranscriptParser.items(fromJSON: line, idPrefix: "") {
                    if case .userText(let text) = item.kind {
                        scan.firstUserText = text
                        scan.hasConversation = true
                        break
                    }
                }
            default:
                break
            }
        }
        return scan
    }
}
