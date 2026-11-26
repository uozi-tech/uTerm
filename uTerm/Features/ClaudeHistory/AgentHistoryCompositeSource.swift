import Foundation

/// 建数据源只在这里：要哪几种工具的记录，就给哪几种建一份，再合起来交给 `AgentHistoryModel`。
///
/// 只建出一种时直接给它本身（不包一层），行为和只认 Claude Code 的时候一模一样。
nonisolated enum AgentHistorySources {
    /// `home`：主目录，不给就各自问 `provider`（见 `ClaudeHistorySource.init`）。
    static func make(tools: [AgentHistoryTool], provider: any SFTPProviding, home: String? = nil) -> any AgentHistorySource {
        var seen: Set<AgentHistoryTool> = []
        let made = tools.filter { seen.insert($0).inserted }.compactMap { make($0, provider: provider, home: home) }
        if made.count == 1 { return made[0] }
        // 一种都没建出来（只要了还没接上的工具）：退回 Claude Code，至少有个能列的。
        if made.isEmpty { return ClaudeHistorySource(provider: provider, home: home) }
        return AgentHistoryCompositeSource(made)
    }

    /// 一种工具的数据源；还没有实现的为 nil（跳过）。
    static func make(_ tool: AgentHistoryTool, provider: any SFTPProviding, home: String?) -> (any AgentHistorySource)? {
        switch tool {
        case .claude:
            return ClaudeHistorySource(provider: provider, home: home)
        case .codex:
            return CodexHistorySource(provider: provider, home: home)
        case .cursor:
            return CursorHistorySource(provider: provider, home: home)
        case .antigravity:
            // 工作区和标题在它的 SQLite 摘要库里，读不出来时数据源自己退回只靠记录。
            return AntigravityHistorySource(provider: provider, home: home, index: AntigravitySummaryIndex())
        }
    }
}

/// 几种工具的数据源合成一个：项目、会话、子代理都带着 `tool`，按它分给对应的那一份。
///
/// 一种出错不拖累别的：`projects()` 里某一种列不出来，记进 `failures`，其余照常列；只有全都失败、
/// 或者成功的那几种一条记录都没有时才把错误抛出去（界面显示失败与重试，而不是「没有历史会话」）。
actor AgentHistoryCompositeSource: AgentHistorySource {
    nonisolated let sources: [any AgentHistorySource]
    /// 上一次 `projects()` 里列不出来的工具 → 给用户看的原因。
    private(set) var failures: [AgentHistoryTool: String] = [:]

    /// 同一种工具只留第一份。`sources` 不能为空。
    init(_ sources: [any AgentHistorySource]) {
        precondition(!sources.isEmpty, "合成的数据源至少要有一份")
        var seen: Set<AgentHistoryTool> = []
        self.sources = sources.filter { seen.insert($0.tool).inserted }
    }

    /// 协议要一个「哪种工具」：合成的没有单一的工具，报第一份的。按工具分派一律看 `source(for:)`。
    nonisolated var tool: AgentHistoryTool { sources[0].tool }
    nonisolated var tools: [AgentHistoryTool] { sources.map(\.tool) }
    /// 有一种能搜就算能搜；具体哪几种不能，见 `supportsSearch(for:)`。
    nonisolated var supportsSearch: Bool { sources.contains { $0.supportsSearch } }

    nonisolated func source(for tool: AgentHistoryTool) -> (any AgentHistorySource)? {
        sources.first { $0.tool == tool }
    }

    nonisolated func supportsSearch(for tool: AgentHistoryTool) -> Bool {
        source(for: tool)?.supportsSearch ?? false
    }

    /// 有一种能删就算能删；具体一个会话能不能删看它那种工具的数据源。
    nonisolated var supportsDelete: Bool { sources.contains { $0.supportsDelete } }

    func delete(_ file: AgentHistorySessionFile) async throws {
        guard let source = source(for: file.tool), source.supportsDelete else { throw AgentHistoryDeleteError.unsupported }
        try await source.delete(file)
    }

    // MARK: 列表

    func projects() async throws -> [AgentHistoryProject] {
        // 几种工具同时列，谁先列完谁先回来。每份结果带着它是哪种工具，按工具对号入座，不按回来的先后、也不靠排序还原：
        // build 1548–1556 实测装着的 Release 版里，Codex 那一格拿到的是 Cursor 列出来的项目（后面两格依次错开），
        // Claude Code 慢一步时它的项目也被当成 Codex 的，交给 Codex 去列，列出空的、不报错，侧栏整个空掉。
        let results = await withTaskGroup(of: (AgentHistoryTool, Result<[AgentHistoryProject], any Error>).self) { group in
            for source in sources {
                group.addTask {
                    do { return (source.tool, .success(try await source.projects())) } catch { return (source.tool, .failure(error)) }
                }
            }
            var collected: [AgentHistoryTool: Result<[AgentHistoryProject], any Error>] = [:]
            for await (tool, result) in group { collected[tool] = result }
            return collected
        }
        var found: [AgentHistoryProject] = []
        var errors: [(AgentHistoryTool, any Error)] = []
        // 诊断：每种工具的数据源各回了几个项目、路径是不是在它自己的目录下（`.claude/`、`.codex/` 这类，只记对错）。
        var perTool: [String] = []
        for source in sources {
            switch results[source.tool] {
            case .success(let projects)?:
                let marker = "/." + source.tool.rawValue
                let own = projects.filter { $0.path.contains(marker) }.count
                perTool.append("\(source.tool.rawValue) \(projects.count)（自己目录下 \(own)，回来时标的 "
                               + "\(Set(projects.map(\.tool.rawValue)).sorted().joined(separator: "/"))）")
                // 数据源该自己填 `tool`；万一漏了，按它是哪一份补上，免得分派到别的工具去。
                found += projects.map { project in
                    var project = project
                    project.tool = source.tool
                    return project
                }
            case .failure(let error)?:
                errors.append((source.tool, error))
            case nil:
                errors.append((source.tool, AgentHistoryCompositeError.noSource(source.tool)))
            }
        }
        let message = "历史会话：各工具列项目 " + perTool.joined(separator: "，")
        AppLogger.notice(message, category: AgentHistoryLog.category)
        failures = Dictionary(errors.map { ($0.0, FriendlyError.describe($0.1)) }, uniquingKeysWith: { first, _ in first })
        if found.isEmpty, let first = errors.first { throw first.1 }
        return found.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// 协议要一个同步的版本，合成的数据源没法在这里等每一份：只按项目上已知的工作目录找（自己或最近的上级）。
    /// `AgentHistoryModel` 不调它，而是拆开 `sources` 逐份去问（Claude Code 的项目要按目录名换算才对得上）。
    func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject? {
        for candidate in ClaudeProjectPath.lineage(of: directory) {
            if let hit = projects.first(where: { $0.directory.flatMap(ClaudeProjectPath.normalized) == candidate }) {
                return hit
            }
        }
        return nil
    }

    func sessions(in project: AgentHistoryProject) async throws -> [AgentHistorySessionFile] {
        guard let source = source(for: project.tool) else { throw AgentHistoryCompositeError.noSource(project.tool) }
        return try await source.sessions(in: project)
    }

    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile] {
        await listAllSessions(in: projects).files
    }

    func listAllSessions(in projects: [AgentHistoryProject]) async -> AgentHistorySessionListing {
        let byTool = Dictionary(grouping: projects, by: \.tool)
        var perTool: [String] = []
        let lists = await withTaskGroup(of: (AgentHistoryTool, AgentHistorySessionListing).self) { group in
            for source in sources {
                guard let mine = byTool[source.tool], !mine.isEmpty else { continue }
                group.addTask { (source.tool, await source.listAllSessions(in: mine)) }
            }
            var collected = AgentHistorySessionListing(files: [])
            for await (tool, listing) in group {
                perTool.append("\(tool.rawValue) \(byTool[tool]?.count ?? 0)→\(listing.files.count)/失败\(listing.failedProjects.count)")
                collected.files += listing.files
                collected.failedProjects.formUnion(listing.failedProjects)
            }
            return collected
        }
        // 诊断：每种工具列了几个项目、列到几份（侧栏整个空掉时看是哪一种、哪一步）。
        let message = "历史会话：各工具列会话 " + perTool.sorted().joined(separator: "，")
        AppLogger.notice(message, category: AgentHistoryLog.category)
        return AgentHistorySessionListing(files: lists.files.sorted { $0.modifiedAt > $1.modifiedAt },
                                          failedProjects: lists.failedProjects)
    }

    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata {
        guard let source = source(for: file.tool) else { throw AgentHistoryCompositeError.noSource(file.tool) }
        return try await source.metadata(for: file)
    }

    // MARK: 对话

    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging {
        source(for: file.tool)?.transcript(for: file) ?? AgentHistoryMissingPager(tool: file.tool)
    }

    nonisolated func transcript(for file: AgentHistorySessionFile, around anchor: AgentTranscriptAnchor) -> any AgentTranscriptPaging {
        source(for: file.tool)?.transcript(for: file, around: anchor) ?? AgentHistoryMissingPager(tool: file.tool)
    }

    nonisolated func subagentTranscript(for subagent: AgentSubagentFile) -> any AgentTranscriptPaging {
        source(for: subagent.tool)?.subagentTranscript(for: subagent) ?? AgentHistoryMissingPager(tool: subagent.tool)
    }

    func subagents(of target: AgentTranscriptTarget) async throws -> [AgentSubagentFile] {
        let tool: AgentHistoryTool
        switch target {
        case .session(let file): tool = file.tool
        case .subagent(let subagent): tool = subagent.tool
        }
        guard let source = source(for: tool) else { return [] }
        return try await source.subagents(of: target)
    }

    func info(of subagent: AgentSubagentFile) async -> AgentSubagentInfo? {
        await source(for: subagent.tool)?.info(of: subagent)
    }

    /// 协议里的这两个不带工具，只能按第一份答。要按会话的工具出命令用 `source(for:)`（`AgentHistoryModel` 就是这么做的）。
    nonisolated func resumeCommand(sessionID: String, directory: String) -> String? {
        sources[0].resumeCommand(sessionID: sessionID, directory: directory)
    }

    nonisolated func newSessionCommand(directory: String) -> String? {
        sources[0].newSessionCommand(directory: directory)
    }

    // MARK: 搜索

    /// 每种能搜的工具各搜各的那几份（同时跑），结果一条条转出去；命中的总数到了上限就叫停（各自在下一批之前停）。
    /// 不能搜的工具的会话不交出去。进度是几种加起来的。只有全都出错时才抛错。
    func search(_ query: AgentHistorySearchQuery, in files: [AgentHistorySessionFile], limits: AgentHistorySearchLimits,
                onEvent: @escaping @Sendable (AgentHistorySearchEvent) async -> Void) async throws {
        let byTool = Dictionary(grouping: files, by: \.tool)
        let jobs: [(source: any AgentHistorySource, files: [AgentHistorySessionFile])] = sources.compactMap { source in
            guard source.supportsSearch, let mine = byTool[source.tool], !mine.isEmpty else { return nil }
            return (source, mine)
        }
        guard !jobs.isEmpty else {
            await onEvent(.progress(searched: 0, total: 0))
            await onEvent(.finished(truncated: false))
            return
        }
        if jobs.count == 1 {
            try await jobs[0].source.search(query, in: jobs[0].files, limits: limits, onEvent: onEvent)
            return
        }
        let merger = AgentHistorySearchMerger(totals: jobs.map(\.files.count), totalHits: limits.totalHits, onEvent: onEvent)
        await withTaskGroup(of: Void.self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    do {
                        try await job.source.search(query, in: job.files, limits: limits) { event in
                            if await merger.receive(event, from: index) == .stop {
                                // 命中够了：这一路在下一批之前停（数据源被取消后不再往主机上发命令）。
                                withUnsafeCurrentTask { $0?.cancel() }
                            }
                        }
                        await merger.finished(index, error: nil)
                    } catch {
                        await merger.finished(index, error: error)
                    }
                }
            }
        }
        try Task.checkCancellation()
        try await merger.finish()
    }
}

/// 合成的数据源里没有这种工具（不该发生：项目、会话都是它自己列出来的）。
nonisolated enum AgentHistoryCompositeError: LocalizedError {
    case noSource(AgentHistoryTool)

    var errorDescription: String? {
        switch self {
        case .noSource(let tool): return String(localized: "读不了 \(tool.displayName) 的记录")
        }
    }
}

/// 找不到数据源时的对话：一读就报错（界面显示失败与重试）。
actor AgentHistoryMissingPager: AgentTranscriptPaging {
    let tool: AgentHistoryTool

    init(tool: AgentHistoryTool) { self.tool = tool }

    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool) {
        throw AgentHistoryCompositeError.noSource(tool)
    }

    func loadNewer() async throws -> AgentTranscriptGrowth { .unchanged }
}

/// 几路搜索的事件合成一路：进度相加，会话照来的先后转出，命中到了上限就让各路停下。
actor AgentHistorySearchMerger {
    enum Verdict { case keepGoing, stop }

    private let onEvent: @Sendable (AgentHistorySearchEvent) async -> Void
    private let totalHits: Int
    private var searched: [Int]
    private var totals: [Int]
    private var hits = 0
    private var truncated = false
    private var errors: [(Int, any Error)] = []
    private var done = 0

    init(totals: [Int], totalHits: Int, onEvent: @escaping @Sendable (AgentHistorySearchEvent) async -> Void) {
        self.totals = totals
        searched = Array(repeating: 0, count: totals.count)
        self.totalHits = totalHits
        self.onEvent = onEvent
    }

    func receive(_ event: AgentHistorySearchEvent, from index: Int) async -> Verdict {
        guard !isFull else { return .stop }
        switch event {
        case .progress(let done, let total):
            searched[index] = done
            totals[index] = total
            await onEvent(.progress(searched: searched.reduce(0, +), total: totals.reduce(0, +)))
        case .session(var session):
            let room = totalHits - hits
            if session.hits.count > room {
                session.hits = Array(session.hits.prefix(room))
                session.hasMoreHits = true
            }
            hits += session.hits.count
            if !session.hits.isEmpty { await onEvent(.session(session)) }
            if hits >= totalHits { truncated = true }
        case .finished(let wasTruncated):
            if wasTruncated { truncated = true }
        }
        return isFull ? .stop : .keepGoing
    }

    private var isFull: Bool { hits >= totalHits }

    func finished(_ index: Int, error: (any Error)?) {
        done += 1
        if let error, !(error is CancellationError) { errors.append((index, error)) }
    }

    /// 都停了之后：全都出错就抛第一个错，否则报搜完了。
    func finish() async throws {
        if !errors.isEmpty, errors.count == totals.count, let first = errors.min(by: { $0.0 < $1.0 }) { throw first.1 }
        await onEvent(.finished(truncated: truncated))
    }
}
