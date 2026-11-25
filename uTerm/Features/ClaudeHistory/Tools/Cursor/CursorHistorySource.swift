import Foundation

/// 一台主机上 Cursor 命令行（`cursor-agent`）的历史会话，经任意 `SFTPProviding` 只读地访问。
///
/// 记录在 `~/.cursor/chats/<工作目录的 MD5>/<会话 ID>/store.db`（SQLite，WAL 模式；设了 `XDG_CONFIG_HOME` 的主机上是
/// `$XDG_CONFIG_HOME/cursor/chats`，这里只认常见的 `~/.config`）。一个项目 = 一个工作目录哈希；库的格式见 `CursorChatStore`，
/// 读法见 `SQLiteRemoteReader`（整份读进内存，不往主机上写任何东西）。
///
/// 只管命令行的记录：Cursor 编辑器自己的对话在别处（`state.vscdb`、`~/.cursor/projects/*/agent-transcripts`），不读。
/// 搜索不支持：主机上没有不写文件就能查 SQLite 的办法（`sqlite3` 会写 `-shm`）。
actor CursorHistorySource: AgentHistorySource {
    nonisolated var tool: AgentHistoryTool { .cursor }
    nonisolated var supportsSearch: Bool { false }

    let provider: any SFTPProviding
    let limits: SQLiteReadLimits
    /// 「全部项目」时同时列几个目录；每个会话还要再列一次自己的目录。
    static let listConcurrency = 6
    /// 列项目时为了找出工作目录，每个项目最多读几份记录。
    static let workspaceProbeSessions = 3
    static let workspaceProbeConcurrency = 4

    private var home: String?
    private var cache: [AgentHistorySessionFile.CacheKey: AgentHistorySessionMetadata] = [:]
    private var summaries: [AgentHistorySessionFile.CacheKey: CursorChatStore.Summary] = [:]
    /// 工作目录哈希 → 核对过的工作目录。MD5 对上了就不会再变，读到一次就记住。
    private var workspaces: [String: String] = [:]
    /// 找过却没找到工作目录的项目（按项目目录的修改时间：有新会话了再找）。
    private var unresolved: [String: Date?] = [:]

    /// `home`：主目录。不给就问 `provider`（`realPath(".")`）；测试给一个临时目录。
    init(provider: any SFTPProviding, home: String? = nil, limits: SQLiteReadLimits = .standard) {
        self.provider = provider
        self.home = home
        self.limits = limits
    }

    /// 记录可能在的几个根目录：`cursor-agent` 按 `CURSOR_CONFIG_DIR` → `$XDG_CONFIG_HOME/cursor` → `~/.cursor` 找。
    func chatRoots() async throws -> [String] {
        let resolved: String
        if let home {
            resolved = home
        } else {
            resolved = try await provider.realPath(".")
            home = resolved
        }
        let base = resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
        return [base + "/.cursor/chats", base + "/.config/cursor/chats"]
    }

    func projects() async throws -> [AgentHistoryProject] {
        var found: [AgentHistoryProject] = []
        var seen = Set<String>()
        for root in try await chatRoots() {
            let entries: [RemoteEntry]
            do {
                entries = try await provider.list(path: root)
            } catch {
                // 目录不存在 = 没用过（或者不在这个根下）。只认明确的「不存在」，别的错误（没权限、断线）照常报。
                if await AgentHistoryMissingPath.confirmsAbsent(root, after: error, provider: provider) { continue }
                throw error
            }
            for entry in entries where (entry.isDirectory || entry.isSymlink) && CursorWorkspace.isHashName(entry.name) {
                guard seen.insert(entry.name).inserted else { continue }
                found.append(AgentHistoryProject(id: entry.name, path: root + "/" + entry.name, modifiedAt: entry.modifiedAt,
                                                 directory: workspaces[entry.name], tool: .cursor))
            }
        }
        let pending = found.filter { $0.directory == nil && !isKnownUnresolved($0) }
        if !pending.isEmpty { await resolveWorkspaces(pending) }
        return found
            .map { project in
                var project = project
                project.directory = workspaces[project.id]
                return project
            }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    private func isKnownUnresolved(_ project: AgentHistoryProject) -> Bool {
        guard let when = unresolved[project.id] else { return false }
        return when == project.modifiedAt
    }

    /// 每个项目读最新的几份记录，直到有一份里提到的目录 MD5 对上目录名。读到的摘要顺手缓存（列表一会儿就要）。
    private func resolveWorkspaces(_ projects: [AgentHistoryProject]) async {
        var next = 0
        await withTaskGroup(of: (AgentHistoryProject, String?).self) { group in
            func launch() {
                let project = projects[next]
                next += 1
                group.addTask { (project, await self.probeWorkspace(of: project)) }
            }
            while next < min(Self.workspaceProbeConcurrency, projects.count) { launch() }
            while let result = await group.next() {
                let (project, directory) = result
                if let directory {
                    workspaces[project.id] = directory
                    unresolved[project.id] = nil
                } else {
                    unresolved[project.id] = project.modifiedAt
                }
                if next < projects.count { launch() }
            }
        }
    }

    private func probeWorkspace(of project: AgentHistoryProject) async -> String? {
        guard let files = try? await sessions(in: project) else { return nil }
        for file in files.prefix(Self.workspaceProbeSessions) {
            guard let summary = try? await summary(for: file) else { continue }
            if let directory = CursorWorkspace.verified(summary.workspaceCandidates, hash: project.id) { return directory }
        }
        return nil
    }

    /// 终端的当前目录（或它的上级）的 MD5 正好是某个项目的目录名：这就是它的项目，目录也就确定了。
    func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject? {
        guard directory.hasPrefix("/") else { return nil }
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current = directory
        while current.count > 1, current.hasSuffix("/") { current.removeLast() }
        while true {
            if var project = byID[CursorWorkspace.hash(of: current)] {
                project.directory = current
                workspaces[project.id] = current
                return project
            }
            guard current != "/" else { return nil }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { return nil }
        }
    }

    func sessions(in project: AgentHistoryProject) async throws -> [AgentHistorySessionFile] {
        let entries = try await provider.list(path: project.path)
        let chats = entries.filter { ($0.isDirectory || $0.isSymlink) && ClaudeResumeCommand.isSessionID($0.name) }
        var project = project
        if project.directory == nil { project.directory = workspaces[project.id] }
        let owner = project
        var files: [AgentHistorySessionFile] = []
        var next = 0
        try await withThrowingTaskGroup(of: AgentHistorySessionFile?.self) { group in
            func launch() {
                let chat = chats[next]
                next += 1
                group.addTask { try await self.sessionFile(named: chat.name, in: owner) }
            }
            while next < min(Self.listConcurrency, chats.count) { launch() }
            while let file = try await group.next() {
                if let file { files.append(file) }
                if next < chats.count { launch() }
            }
        }
        return files.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 一个会话目录里的 `store.db` 与 `store.db-wal`：大小与时间都算上 WAL（会话开着时新内容都在 WAL 里）。
    /// 还没有库的（刚建、正在建）跳过；目录在列的时候被删了也跳过。
    private func sessionFile(named name: String, in project: AgentHistoryProject) async throws -> AgentHistorySessionFile? {
        let directory = project.path + "/" + name
        let path = directory + "/store.db"
        let fingerprint: SQLiteRemoteFingerprint
        do {
            fingerprint = try await SQLiteRemoteReader(provider: provider, path: path, limits: limits).fingerprint()
        } catch SQLiteRemoteReadError.missing {
            return nil
        }
        return AgentHistorySessionFile(sessionID: name, project: project, path: path, size: fingerprint.totalBytes,
                                       modifiedAt: fingerprint.modifiedAt ?? .distantPast)
    }

    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile] {
        await listAllSessions(in: projects).files
    }

    /// 同上，另报出列不出来的项目（断线、辅助程序一时连不上）：后台重列留着它们上一次列到的会话。
    /// 项目目录已经不在了（明确不存在）的不算失败。
    func listAllSessions(in projects: [AgentHistoryProject]) async -> AgentHistorySessionListing {
        var result: [AgentHistorySessionFile] = []
        var failed: Set<AgentHistoryProjectKey> = []
        var next = 0
        await withTaskGroup(of: (AgentHistoryProject, [AgentHistorySessionFile]?).self) { group in
            func launch() {
                let project = projects[next]
                next += 1
                group.addTask {
                    do {
                        return (project, try await self.sessions(in: project))
                    } catch where AgentHistoryMissingPath.isNotFound(error) {
                        return (project, [])
                    } catch {
                        return (project, nil)
                    }
                }
            }
            while next < min(Self.listConcurrency, projects.count) { launch() }
            while let (project, files) = await group.next() {
                if let files { result.append(contentsOf: files) } else { failed.insert(AgentHistoryProjectKey(project)) }
                if next < projects.count { launch() }
            }
        }
        return AgentHistorySessionListing(files: result.sorted { $0.modifiedAt > $1.modifiedAt }, failedProjects: failed)
    }

    private func summary(for file: AgentHistorySessionFile) async throws -> CursorChatStore.Summary? {
        if let cached = summaries[file.cacheKey] { return cached }
        let reader = SQLiteRemoteReader(provider: provider, path: file.path, limits: limits)
        guard let read = try await reader.read({ try CursorChatStore.summary(in: $0) }), let summary = read.value else {
            return nil
        }
        summaries[file.cacheKey] = summary
        return summary
    }

    /// 要读整份库（标题与是否为空都在库里）。读过的按 `cacheKey` 缓存。
    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata {
        if let cached = cache[file.cacheKey] { return cached }
        let summary = try await summary(for: file)
        var directory = workspaces[file.project.id] ?? file.project.directory
        if let summary, let verified = CursorWorkspace.verified(summary.workspaceCandidates, hash: file.project.id) {
            directory = verified
            workspaces[file.project.id] = verified
        }
        let title = summary?.meta.title
            ?? summary?.firstUserText.map { ClaudeSessionScan.singleLine($0) }.flatMap { $0.isEmpty ? nil : $0 }
        // 还没说过话的会话（`cursor-agent` 退出时会把它删掉，正开着的还在）不列：点开什么都没有。
        let isListed = (summary?.turnCount ?? 0) > 0
        let metadata = AgentHistorySessionMetadata(title: title, isListed: isListed, lastDirectory: directory,
                                                   resumeDirectory: directory, gitBranch: nil,
                                                   lastActivity: file.modifiedAt == .distantPast ? nil : file.modifiedAt)
        cache[file.cacheKey] = metadata
        return metadata
    }

    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging {
        CursorTranscriptPager(reader: SQLiteRemoteReader(provider: provider, path: file.path, limits: limits))
    }

    /// 不支持搜索，也就没有「从命中处打开」：一律从末尾读。
    nonisolated func transcript(for file: AgentHistorySessionFile, around anchor: AgentTranscriptAnchor) -> any AgentTranscriptPaging {
        transcript(for: file)
    }

    func search(_ query: AgentHistorySearchQuery, in files: [AgentHistorySessionFile], limits: AgentHistorySearchLimits,
                onEvent: @escaping @Sendable (AgentHistorySearchEvent) async -> Void) async throws {
        throw AgentHistorySearchError.cannotExecute
    }

    /// 子代理（`Task` 工具）的过程嵌在派它的那次调用的结果里，没有单独的记录。
    func subagents(of target: AgentTranscriptTarget) async throws -> [AgentSubagentFile] { [] }

    func info(of subagent: AgentSubagentFile) async -> AgentSubagentInfo? { nil }

    nonisolated func subagentTranscript(for subagent: AgentSubagentFile) -> any AgentTranscriptPaging {
        CursorTranscriptPager(reader: SQLiteRemoteReader(provider: provider, path: subagent.path, limits: limits))
    }

    nonisolated func resumeCommand(sessionID: String, directory: String) -> String? {
        CursorAgentCommand.resume(sessionID: sessionID, directory: directory)
    }

    nonisolated func newSessionCommand(directory: String) -> String? {
        CursorAgentCommand.newSession(directory: directory)
    }
}

/// 在终端里敲的命令。会话 ID 只收 UUID 的形状（`cursor-agent` 用 `randomUUID()` 起的名），目录按 POSIX shell 的单引号
/// 规则引起来（同 `ClaudeResumeCommand`）；不合规矩就不给命令。必须先进那个目录：`--resume` 按当前目录的 MD5 找会话。
nonisolated enum CursorAgentCommand {
    static func resume(sessionID: String, directory: String) -> String? {
        guard ClaudeResumeCommand.isSessionID(sessionID),
              let quoted = ClaudeResumeCommand.quotedDirectory(directory) else { return nil }
        return "cd -- \(quoted) && cursor-agent --resume \(sessionID)"
    }

    static func newSession(directory: String) -> String? {
        guard let quoted = ClaudeResumeCommand.quotedDirectory(directory) else { return nil }
        return "cd -- \(quoted) && cursor-agent"
    }
}

/// 一份 Cursor 会话的对话。库整份读进内存，分页在内存里做；跟随 = 库的两个文件大小或时间变了就重读
/// （`SQLiteRemoteReader` 只读 WAL 新长出来的那段），和已经交出去的条目比：原样都在就把新的交出去，
/// 对不上（改过、少了、插到中间的不是工具结果）就整份重来。
actor CursorTranscriptPager: AgentTranscriptPaging {
    private let reader: SQLiteRemoteReader
    private let pageItems: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private var items: [AgentTranscriptItem] = []
    private var loaded = false
    /// 已经交出去的部分从哪开始；前面的等着往前翻。
    private var start = 0
    private var fingerprint: SQLiteRemoteFingerprint?
    private var lastRebuild: ContinuousClock.Instant?

    init(reader: SQLiteRemoteReader, pageItems: Int = AgentTranscriptLimits.pageItems,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.reader = reader
        self.pageItems = max(1, pageItems)
        self.now = now
    }

    /// 大库重建一次（盖 WAL、打开、解析整份）要花些时间：会话开着、库一直在变时，按大小拉开两次重读的间隔。
    /// 8 MB 以下每次都读；再大的每 8 MB 隔 2 秒，最多 15 秒。
    nonisolated static func rebuildInterval(forBytes bytes: UInt64) -> Duration {
        let unit: UInt64 = 8 * 1024 * 1024
        guard bytes >= unit else { return .zero }
        return min(.seconds(15), .seconds(2 * Int(bytes / unit)))
    }

    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool) {
        if !loaded {
            guard let read = try await reader.read({ try CursorTranscriptParser.items(in: $0) }) else { return ([], true) }
            items = read.value
            fingerprint = read.fingerprint
            lastRebuild = now()
            start = items.count
            loaded = true
        }
        let from = max(0, start - pageItems)
        let page = Array(items[from..<start])
        start = from
        return (page, from == 0)
    }

    func loadNewer() async throws -> AgentTranscriptGrowth {
        guard loaded else { return .unchanged }
        if let lastRebuild, let fingerprint,
           now() - lastRebuild < Self.rebuildInterval(forBytes: fingerprint.totalBytes) { return .unchanged }
        guard let read = try await reader.read(ifChangedFrom: fingerprint, { try CursorTranscriptParser.items(in: $0) }) else {
            return .unchanged
        }
        fingerprint = read.fingerprint
        lastRebuild = now()
        switch Self.difference(old: items, new: read.value, start: start) {
        case .appended(let fresh, let newStart):
            items = read.value
            start = newStart
            return fresh.isEmpty ? .unchanged : .appended(fresh, hasMore: false)
        case .replaced:
            items = read.value
            start = items.count
            return .replaced
        }
    }

    nonisolated enum Difference: Equatable {
        /// 旧的原样都在：`fresh` 是交出去的那段里新出现的（按新的顺序），`start` 是新列表里交出去的部分从哪开始。
        case appended(fresh: [AgentTranscriptItem], start: Int)
        case replaced
    }

    /// 旧列表的每一条都要在新列表里原样出现、先后不变。新出现的条目落在旧的最后一条之后的照常接上；落在中间的只允许是
    /// 工具结果（并行调用的结果后到，挂到各自的调用下面），别的说明对话被改过，整份重来。
    /// 落在还没往前翻到的那段里的新条目留给往前翻。
    nonisolated static func difference(old: [AgentTranscriptItem], new: [AgentTranscriptItem], start: Int) -> Difference {
        var position: [String: Int] = [:]
        for (index, item) in new.enumerated() where position[item.id] == nil { position[item.id] = index }
        var last = -1
        for item in old {
            guard let index = position[item.id], index > last, new[index] == item else { return .replaced }
            last = index
        }
        let newStart = start < old.count ? position[old[start].id]! : (old.isEmpty ? 0 : last + 1)
        let oldIDs = Set(old.map(\.id))
        var fresh: [AgentTranscriptItem] = []
        for index in newStart..<new.count where !oldIDs.contains(new[index].id) {
            if index < last {
                guard case .toolResult = new[index].kind else { return .replaced }
            }
            fresh.append(new[index])
        }
        return .appended(fresh: fresh, start: newStart)
    }
}
