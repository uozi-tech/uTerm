import Foundation

/// 一台主机上 Claude Code 的历史会话（`~/.claude/projects`），经任意 `SFTPProviding` 只读地访问：
/// SSH 主机是 `SFTPSession`，本机是经辅助程序的那个（沙盒里的 App 读不到 `~/.claude`）。
actor ClaudeHistorySource: AgentHistorySource {
    nonisolated var tool: AgentHistoryTool { .claude }

    let provider: any SFTPProviding
    /// 列表一行先读末尾这么多。实测本机 1600 多份记录，64 KB 里有 `entrypoint` 的占 99%、有标题的也是 99%。
    static let tailBytes = 64 * 1024
    /// 末尾没定下来源时从开头往后找，最多读这么多（只在少数大文件开头全是快照行时用得到）。
    static let headScanLimit = 1024 * 1024
    static let headChunkBytes = 256 * 1024
    /// 「全部项目」时同时列几个目录。
    static let listConcurrency = 6

    /// 子代理的信息文件很小（实测几百字节），读这么多足够。
    static let subagentInfoBytes = 64 * 1024

    /// 末尾那一块里没有标题行时，往前最多再找这么多（真实的记录里两行标题之间隔过 1 MB 多，中间还有近 1 MB 的一行）。
    static let titleSearchLimit = 4 * 1024 * 1024
    static let titleSearchChunk = 256 * 1024

    private var home: String?
    private var cache: [AgentHistorySessionFile.CacheKey: AgentHistorySessionMetadata] = [:]
    /// 每份记录上一次读到的标题行与工作目录（按路径）。记录只往后长：下次末尾那一块里没有，就只往前找新写的那一段，
    /// 再没有就用这里记的。没有它，跑着的会话每次重读（文件变长了）标题都跟着末尾那一块跳。
    private var names: [String: ClaudeSessionNames] = [:]
    /// 子代理的信息文件读过就不再读（按路径；它在子代理派出时写好，之后基本不变）。
    private var infoCache: [String: AgentSubagentInfo] = [:]

    /// `home`：主目录。不给就问 `provider`（`realPath(".")`：SFTP 与远控文件服务都把它解析成登录用户的主目录）；
    /// 测试给一个临时目录。
    /// 搜索时一批交多少份（测试换成小的，好看出分批）。
    let searchBatching: ClaudeSearchBatching

    init(provider: any SFTPProviding, home: String? = nil, searchBatching: ClaudeSearchBatching = .standard) {
        self.provider = provider
        self.home = home
        self.searchBatching = searchBatching
    }

    func projectsRoot() async throws -> String {
        if let home { return ClaudeProjectPath.projectsRoot(home: home) }
        let resolved = try await provider.realPath(".")
        home = resolved
        return ClaudeProjectPath.projectsRoot(home: resolved)
    }

    func projects() async throws -> [AgentHistoryProject] {
        let root = try await projectsRoot()
        let entries: [RemoteEntry]
        do {
            entries = try await provider.list(path: root)
        } catch {
            // 目录不存在 = 这台主机上没用过 Claude Code。只认明确的「不存在」：辅助程序一时连不上、断线时
            // 列和 stat 都会失败，当成「没用过」会让后台重列把整个侧栏清空（见 `AgentHistoryMissingPath`）。
            if await AgentHistoryMissingPath.confirmsAbsent(root, after: error, provider: provider) { return [] }
            throw error
        }
        return entries
            .filter { ($0.isDirectory || $0.isSymlink) && !$0.name.hasPrefix(".") }
            .map { AgentHistoryProject(id: $0.name, path: root + "/" + $0.name, modifiedAt: $0.modifiedAt) }
            .sorted(by: AgentHistoryProject.newestFirst)
    }

    func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject? {
        let byName = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let hit = ClaudeProjectPath.project(containing: directory, among: Set(byName.keys)),
              var project = byName[hit.name] else { return nil }
        project.directory = hit.path
        return project
    }

    func sessions(in project: AgentHistoryProject) async throws -> [AgentHistorySessionFile] {
        let entries = try await provider.list(path: project.path)
        if entries.isEmpty {
            AppLogger.debug("历史会话：Claude Code 有一个项目目录列出来是空的", category: AgentHistoryLog.category)
        }
        var files: [AgentHistorySessionFile] = []
        for entry in entries where !entry.isDirectory && entry.name.hasSuffix(".jsonl") {
            let path = project.path + "/" + entry.name
            var size = entry.size
            var modified = entry.modifiedAt
            if size == nil || modified == nil, let stat = try? await provider.stat(path) {
                size = UInt64(max(0, stat.size))
                modified = stat.mtime
            }
            files.append(AgentHistorySessionFile(
                sessionID: String(entry.name.dropLast(".jsonl".count)), project: project, path: path,
                size: size ?? 0, modifiedAt: modified ?? .distantPast))
        }
        return files.sorted(by: AgentHistorySessionFile.newestFirst)
    }

    /// 全部项目的会话合在一起，新的在前。列不了的项目跳过。
    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile] {
        await listAllSessions(in: projects).files
    }

    /// 同上，另报出列不了的项目。
    func listAllSessions(in projects: [AgentHistoryProject]) async -> AgentHistorySessionListing {
        var result: [AgentHistorySessionFile] = []
        var failed: Set<AgentHistoryProjectKey> = []
        var firstError: String?
        var emptyProjects = 0
        var next = 0
        await withTaskGroup(of: (AgentHistoryProject, Result<[AgentHistorySessionFile], any Error>).self) { group in
            func launch() {
                let project = projects[next]
                next += 1
                group.addTask {
                    do { return (project, .success(try await self.sessions(in: project))) } catch { return (project, .failure(error)) }
                }
            }
            while next < min(Self.listConcurrency, projects.count) { launch() }
            while let (project, outcome) = await group.next() {
                switch outcome {
                case .success(let files):
                    result.append(contentsOf: files)
                    if files.isEmpty { emptyProjects += 1 }
                case .failure(let error):
                    failed.insert(AgentHistoryProjectKey(project))
                    if firstError == nil { firstError = AgentHistoryLog.kind(of: error) }
                }
                if next < projects.count { launch() }
            }
        }
        // 诊断（只有条数与错误种类）：侧栏在 Mac 上新开会话后整个空掉时，看是哪一步列出了空。
        let message = "历史会话：Claude Code 列 \(projects.count) 个项目，\(result.count) 份记录，"
            + "空项目 \(emptyProjects)，失败 \(failed.count)\(firstError.map { "（\($0)）" } ?? "")"
        AppLogger.notice(message, category: AgentHistoryLog.category)
        return AgentHistorySessionListing(files: result.sorted(by: AgentHistorySessionFile.newestFirst), failedProjects: failed)
    }

    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata {
        if let cached = cache[file.cacheKey] { return cached }
        let parts = try await Self.scanParts(file: file, provider: provider)
        var scan = parts.tail
        // 记下的只在文件只长不缩时可用（同一路径换成了别的文件就作废）。
        let known = names[file.path].flatMap { $0.size <= file.size ? $0 : nil }
        // 不列的（桌面版等，实测这类记录末尾常常没有标题行）不往前找：列表里不显示它们的标题。
        let origin = (parts.head.map { scan.merged(withEarlier: $0) } ?? scan).origin
        if !scan.hasNameLine, origin.isListed, let boundary = parts.searchEnd {
            let floor = max(known?.size ?? 0, boundary > UInt64(Self.titleSearchLimit) ? boundary - UInt64(Self.titleSearchLimit) : 0)
            if boundary > floor {
                let found = try await Self.searchNames(file.path, before: boundary, downTo: floor, provider: provider)
                scan.fillNames(from: found)
            }
        }
        if let known { scan.fillNames(from: known) }
        if scan.directories.isEmpty, let directory = known?.lastDirectory { scan.directories = [directory] }
        if let head = parts.head { scan = scan.merged(withEarlier: head) }
        names[file.path] = ClaudeSessionNames(size: file.size, customTitle: scan.customTitle, aiTitle: scan.aiTitle,
                                              lastPrompt: scan.lastPrompt, lastDirectory: scan.directories.last)
        let candidates = Array(scan.directories.reversed())
        // 整份都读过了却没有一句对话（只敲过 `/exit` 之类）的不列：点开也什么都没有。
        let isEmpty = file.size <= UInt64(Self.tailBytes) && !scan.hasConversation
        let metadata = AgentHistorySessionMetadata(
            title: scan.title,
            isListed: scan.origin.isListed && !isEmpty,
            lastDirectory: candidates.first,
            resumeDirectory: ClaudeProjectPath.resumeDirectory(projectName: file.project.id, candidates: candidates)
                ?? file.project.directory,
            gitBranch: scan.gitBranch,
            lastActivity: scan.lastTimestamp,
            continuedIn: scan.continuedIn)
        cache[file.cacheKey] = metadata
        return metadata
    }

    /// 读末尾一块；来源没定下来再从开头往后读几块。
    static func scan(file: AgentHistorySessionFile, provider: any SFTPProviding) async throws -> ClaudeSessionScan {
        let parts = try await scanParts(file: file, provider: provider)
        guard let head = parts.head else { return parts.tail }
        return parts.tail.merged(withEarlier: head)
    }

    /// `scan` 拆开交：末尾那一块读到的、（来源没定下来时）开头几块读到的，以及末尾那一块之前的部分到哪为止
    ///（末尾那一块第一行是半截时是那一行的结尾，往前找标题行从这里起；整份都在末尾那一块里为 nil）。
    static func scanParts(file: AgentHistorySessionFile, provider: any SFTPProviding) async throws
        -> (tail: ClaudeSessionScan, head: ClaudeSessionScan?, searchEnd: UInt64?) {
        let size = file.size
        let tailLength = Int(min(size, UInt64(tailBytes)))
        let tailOffset = size - UInt64(tailLength)
        let tail = try await provider.readRange(file.path, offset: tailOffset, length: tailLength)
        let scan = ClaudeSessionScan.scan(tail, dropsLeadingPartial: tailOffset > 0, dropsTrailingPartial: false)
        let searchEnd: UInt64? = tailOffset > 0 ? tail.firstIndex(of: 0x0A).map { tailOffset + UInt64($0 - tail.startIndex) } ?? size : nil
        guard !scan.isOriginDecided, tailOffset > 0 else { return (scan, nil, searchEnd) }

        var offset: UInt64 = 0
        var head = ClaudeSessionScan()
        while offset < tailOffset, offset < UInt64(headScanLimit) {
            let length = Int(min(UInt64(offset == 0 ? tailBytes : headChunkBytes), tailOffset - offset))
            let chunk = try await provider.readRange(file.path, offset: offset, length: length)
            guard !chunk.isEmpty else { break }
            let part = ClaudeSessionScan.scan(chunk, dropsLeadingPartial: offset > 0, dropsTrailingPartial: true)
            head = part.merged(withEarlier: head)
            offset += UInt64(chunk.count)
            if part.isOriginDecided { break }
        }
        // 开头读到的 entrypoint 比末尾更早；末尾什么都没有，用开头的。
        return (scan, head, searchEnd)
    }

    /// 从 `end` 往前倒着读，找 `[floor, end)` 里最近的标题行：找到 Claude Code 起的名字（用户改的或 AI 起的）就停，
    /// 顺带记下这一段里最近的 `last-prompt`。只认整行（跨块的行拼好再认），超长的行跳过。
    static func searchNames(_ path: String, before end: UInt64, downTo floor: UInt64,
                            provider: any SFTPProviding) async throws -> ClaudeSessionNames {
        var scanner = ClaudeReverseLineScanner(fileSize: end, maxLineBytes: ClaudeSessionScan.maxTitleLineBytes,
                                               headBytes: ClaudeTranscriptParser.headBytes)
        var found = ClaudeSessionNames(size: end)
        while scanner.cursor > floor, let range = scanner.nextRange(chunkSize: titleSearchChunk) {
            let chunk = try await provider.readRange(path, offset: range.offset, length: range.length)
            guard chunk.count == range.length else { break }
            var lines = scanner.feed(chunk)
            if scanner.cursor == 0, let first = scanner.finish() { lines.append(first) }
            for line in lines where !line.isTruncated && line.offset >= floor {
                let head = line.bytes.prefix(ClaudeTranscriptParser.headBytes)
                switch ClaudeSessionScan.titleLine(line.bytes, head: head) {
                case .customTitle(let value): if found.customTitle == nil { found.customTitle = value }
                case .aiTitle(let value): if found.aiTitle == nil { found.aiTitle = value }
                case .lastPrompt(let value): if found.lastPrompt == nil { found.lastPrompt = value }
                case nil: break
                }
            }
            if found.customTitle != nil || found.aiTitle != nil { break }
        }
        return found
    }

    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging {
        ClaudeTranscriptPager(provider: provider, path: file.path)
    }

    nonisolated func transcript(for file: AgentHistorySessionFile, around anchor: AgentTranscriptAnchor) -> any AgentTranscriptPaging {
        ClaudeTranscriptPager(provider: provider, path: file.path, anchor: anchor)
    }

    // MARK: 子代理

    /// 子代理的记录：`<项目目录>/<会话 ID>/subagents/agent-<代理 ID>.jsonl`，格式同主对话，只是每行都是
    /// `isSidechain`。旁边常有（不是每个都有）`agent-<代理 ID>.meta.json`，写着派它的那次调用（`toolUseId`）。
    /// 子代理再派的子代理也在同一个目录里。目录里别的东西（`*.prefix.json`、`workflows/`……）不管。
    nonisolated static func subagentsDirectory(of target: AgentTranscriptTarget) -> String? {
        switch target {
        case .session(let file):
            guard file.path.hasSuffix(".jsonl") else { return nil }
            return String(file.path.dropLast(".jsonl".count)) + "/subagents"
        case .subagent(let subagent):
            return (subagent.path as NSString).deletingLastPathComponent
        }
    }

    /// `agent-<ID>.jsonl` → ID；别的名字为 nil。
    nonisolated static func subagentID(fromFileName name: String) -> String? {
        guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { return nil }
        let id = name.dropFirst("agent-".count).dropLast(".jsonl".count)
        guard !id.isEmpty, !id.contains(".") else { return nil }
        return String(id)
    }

    func subagents(of target: AgentTranscriptTarget) async throws -> [AgentSubagentFile] {
        guard let directory = Self.subagentsDirectory(of: target) else { return [] }
        let entries: [RemoteEntry]
        do {
            entries = try await provider.list(path: directory)
        } catch {
            // 没有这个目录 = 没派过子代理，或者记录被清了。
            if (try? await provider.stat(directory)) == nil { return [] }
            throw error
        }
        let names = Set(entries.map(\.name))
        return entries.compactMap { entry -> AgentSubagentFile? in
            guard !entry.isDirectory, let id = Self.subagentID(fromFileName: entry.name) else { return nil }
            return AgentSubagentFile(agentID: id, path: directory + "/" + entry.name, size: entry.size,
                                     modifiedAt: entry.modifiedAt, hasInfo: names.contains("agent-\(id).meta.json"))
        }
        .sorted(by: AgentSubagentFile.newestFirst)
    }

    func info(of subagent: AgentSubagentFile) async -> AgentSubagentInfo? {
        guard subagent.hasInfo else { return nil }
        if let cached = infoCache[subagent.path] { return cached }
        let path = String(subagent.path.dropLast(".jsonl".count)) + ".meta.json"
        guard let data = try? await provider.readRange(path, offset: 0, length: Self.subagentInfoBytes),
              let info = Self.parseSubagentInfo(data) else { return nil }
        infoCache[subagent.path] = info
        return info
    }

    nonisolated static func parseSubagentInfo(_ data: Data) -> AgentSubagentInfo? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let line = ClaudeSessionScan.singleLine(value, limit: AgentTranscriptLimits.summaryCharacters)
            return line.isEmpty ? nil : line
        }
        return AgentSubagentInfo(toolUseID: string("toolUseId"), agentType: string("agentType"),
                                 description: string("description"))
    }

    nonisolated func subagentTranscript(for subagent: AgentSubagentFile) -> any AgentTranscriptPaging {
        ClaudeTranscriptPager(provider: provider, path: subagent.path, includesSidechain: true)
    }

    nonisolated func resumeCommand(sessionID: String, directory: String) -> String? {
        ClaudeResumeCommand.make(sessionID: sessionID, directory: directory)
    }

    nonisolated func newSessionCommand(directory: String) -> String? {
        ClaudeResumeCommand.makeNew(directory: directory)
    }

    // MARK: - 删除

    nonisolated var supportsDelete: Bool { true }

    /// 删一个会话：`<会话 ID>.jsonl`，再删它旁边同名的目录（子代理的记录、大的工具输出，`claude` 只在派过子代理、
    /// 输出很长时才建）。主记录先删：删掉它会话就从列表上没了；旁边的目录删不干净（断线）只是留下没人看的文件。
    func delete(_ file: AgentHistorySessionFile) async throws {
        guard let directory = Self.companionDirectory(of: file.path) else { throw AgentHistoryDeleteError.unsupported }
        try await provider.removeFile(file.path)
        cache[file.cacheKey] = nil
        names[file.path] = nil
        guard (try? await provider.list(path: directory)) != nil else { return }
        try? await RemoteFileOperations.removeTree(at: directory, provider: provider)
    }

    nonisolated var supportsRename: Bool { true }

    /// 同 Claude Code 的 `/rename`：往记录末尾追加一行 `custom-title`（它自己 `/resume` 时也认这一行，列表标题以它为准）。
    /// 会话可能正开着、Claude Code 还在往里写：用 shell 的 `>>`（O_APPEND，一行一次写完）追加，不按大小定位写，
    /// 免得盖掉它刚写进去的字节。
    func rename(_ file: AgentHistorySessionFile, to title: String) async throws {
        _ = try await provider.exec(Self.renameCommand(path: file.path, sessionID: file.sessionID, title: title))
        cache[file.cacheKey] = nil
        names[file.path] = nil
    }

    /// 追加 `custom-title` 那一行的命令。文件末尾不是换行（最后一行正写到一半）时先补一个换行。
    /// 路径和那一行都作为参数交给 `RemotePath.shScript`（名字不进命令文字；登录 shell 是 csh / fish 也照样跑）。
    nonisolated static func renameCommand(path: String, sessionID: String, title: String) -> String {
        let line = #"{"type":"custom-title","customTitle":"# + jsonString(title) + #","sessionId":"# + jsonString(sessionID) + "}"
        return RemotePath.shScript(
            "tail -c 1 \(argument: 0) | od -c | grep -q '\\\\n' || printf '\\n' >> \(argument: 0); printf '%s\\n' \(argument: 1) >> \(argument: 0)",
            arguments: [path, line], escapedNames: false)
    }

    private nonisolated static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// 一份记录旁边属于它的目录：`…/<会话 ID>.jsonl` → `…/<会话 ID>`。不是 `.jsonl` 为 nil。
    nonisolated static func companionDirectory(of path: String) -> String? {
        guard path.hasSuffix(".jsonl"), path.count > ".jsonl".count else { return nil }
        return String(path.dropLast(".jsonl".count))
    }
}

/// 从文件末尾往前一页一页读对话。文件在看的时候可能还在长（会话正开着）：往前翻只翻第一次打开时那么长，
/// 之后新长出来的由 `loadNewer` 从末尾往后接着读（`ClaudeForwardLineScanner`）。
///
/// 往后读从哪开始：第一次读到的那块文件末尾是换行就从文件末尾；不是（最后一行正写到一半）就从那一行的开头，
/// 写完之后整行再读一遍——倒着读时它要么解析不出来，要么解析出同样 ID 的条目（模型按 ID 去重）。
///
/// 从某一行打开（`anchor`，搜索命中处）：往前翻从那一行的末尾（含换行）开始，第一页里就有它；往后从同一个位置起，
/// 由 `loadNext` 一页一页读，读到文件末尾之后 `loadNewer` 才接着跟——不会为了定位把几十 MB 的记录整份读进来。
/// 行首偏移都是文件里的绝对位置，所以条目 ID 和从末尾读的一样。
actor ClaudeTranscriptPager: AgentTranscriptPaging {
    private let provider: any SFTPProviding
    private let path: String
    private let chunkBytes: Int
    private let pageItems: Int
    private let pageBytes: Int
    /// 子代理自己的记录每行都是 `isSidechain`，要照常显示。
    private let includesSidechain: Bool
    private var scanner: ClaudeReverseLineScanner?
    /// 往后读到哪了；读过文件末尾那一块之后才有。
    private var forward: ClaudeForwardLineScanner?
    /// 文件变短、整份重来时 +1：在途的读拿到的是旧文件的东西，丢掉。
    private var epoch = 0
    private let followBytes: Int

    /// 从哪一行打开；nil = 从末尾。文件被换掉、整份重来之后也变回从末尾。
    private var anchor: AgentTranscriptAnchor?
    /// 往后读已经到过文件末尾（从末尾打开的一开始就是）：这之后 `loadNewer` 才干活。
    private var caughtUp: Bool

    init(provider: any SFTPProviding, path: String, includesSidechain: Bool = false,
         anchor: AgentTranscriptAnchor? = nil,
         chunkBytes: Int = AgentTranscriptLimits.chunkBytes,
         pageItems: Int = AgentTranscriptLimits.pageItems,
         pageBytes: Int = AgentTranscriptLimits.pageBytes,
         maxLineBytes: Int = AgentTranscriptLimits.maxLineBytes,
         followBytes: Int = AgentTranscriptFollowLimits.bytesPerPoll,
         lineParser: (@Sendable (ClaudeReverseLineScanner.Line) -> [AgentTranscriptItem])? = nil) {
        self.lineParser = lineParser
        self.anchor = anchor
        caughtUp = anchor == nil
        self.followBytes = max(1, followBytes)
        self.provider = provider
        self.path = path
        self.chunkBytes = chunkBytes
        self.pageItems = pageItems
        self.pageBytes = pageBytes
        self.includesSidechain = includesSidechain
        self.maxLineBytes = maxLineBytes
    }

    private let maxLineBytes: Int
    /// 一行 → 条目。不给就按 Claude Code 的记录解。别的工具的记录也是按行写的 JSONL 时（Antigravity）传它自己的解析，
    /// 分页、跟随、从命中处打开都照用这一份。
    private let lineParser: (@Sendable (ClaudeReverseLineScanner.Line) -> [AgentTranscriptItem])?

    private func items(from line: ClaudeReverseLineScanner.Line) -> [AgentTranscriptItem] {
        if let lineParser { return lineParser(line) }
        return ClaudeTranscriptParser.items(from: line, includesSidechain: includesSidechain)
    }

    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool) {
        if scanner == nil {
            let size = UInt64(max(0, try await provider.stat(path).size))
            if let anchor {
                // 那一行连同换行；文件比它短（被截过）就到文件末尾为止。
                let end = min(size, anchor.lineOffset + UInt64(anchor.lineLength) + 1)
                scanner = ClaudeReverseLineScanner(fileSize: end, maxLineBytes: maxLineBytes)
                forward = ClaudeForwardLineScanner(position: end, maxLineBytes: maxLineBytes)
            } else {
                scanner = ClaudeReverseLineScanner(fileSize: size, maxLineBytes: maxLineBytes)
                if size == 0, forward == nil { forward = ClaudeForwardLineScanner(position: 0, maxLineBytes: maxLineBytes) }
            }
        }
        // 在副本上读，整页读完才写回：中途出错（断线）下次从同一个位置重读，不会漏行。
        guard var scanner else { return ([], true) }
        let epoch = self.epoch
        let fileEnd = scanner.cursor
        // 新的在前攒，最后整体翻过来。
        var newestFirst: [[AgentTranscriptItem]] = []
        var count = 0
        var bytesRead = 0
        while count < pageItems, bytesRead < pageBytes, let range = scanner.nextRange(chunkSize: chunkBytes) {
            let chunk = try await provider.readRange(path, offset: range.offset, length: range.length)
            guard chunk.count == range.length else {
                throw RemoteFileError(.failed, String(localized: "读取会话记录时文件变短了"))
            }
            bytesRead += chunk.count
            if forward == nil, range.offset + UInt64(range.length) == fileEnd, epoch == self.epoch {
                forward = Self.followStart(lastChunk: chunk, at: range.offset, fileEnd: fileEnd, maxLineBytes: maxLineBytes)
            }
            for line in scanner.feed(chunk) {
                let items = self.items(from: line)
                if !items.isEmpty {
                    newestFirst.append(items)
                    count += items.count
                }
            }
            if scanner.nextRange(chunkSize: chunkBytes) == nil, let first = scanner.finish() {
                let items = self.items(from: first)
                if !items.isEmpty { newestFirst.append(items) }
            }
        }
        if scanner.nextRange(chunkSize: chunkBytes) == nil, !scanner.isAtStart {
            _ = scanner.finish()   // 空文件
        }
        // 读的时候发现文件变短、整份重来了：这一页是旧文件的。
        guard epoch == self.epoch else { return ([], false) }
        self.scanner = scanner
        return (newestFirst.reversed().flatMap { $0 }, scanner.isAtStart)
    }

    /// 文件末尾那一块 `[offset, fileEnd)` 读回来之后，定下往后读从哪开始。
    nonisolated static func followStart(lastChunk: Data, at offset: UInt64, fileEnd: UInt64,
                                        maxLineBytes: Int) -> ClaudeForwardLineScanner {
        if lastChunk.last == 0x0A {
            return ClaudeForwardLineScanner(position: fileEnd, maxLineBytes: maxLineBytes)
        }
        if let newline = lastChunk.lastIndex(of: 0x0A) {
            let lineStart = offset + UInt64(newline - lastChunk.startIndex + 1)
            return ClaudeForwardLineScanner(position: lineStart, maxLineBytes: maxLineBytes)
        }
        // 整份只有写到一半的一行：从头读。
        if offset == 0 { return ClaudeForwardLineScanner(position: 0, maxLineBytes: maxLineBytes) }
        // 写到一半的那一行比一块还长（极少见）：它的开头不在这块里，只能从末尾接着读、丢掉这一行剩下的部分。
        return ClaudeForwardLineScanner(position: fileEnd, startsMidLine: true, maxLineBytes: maxLineBytes)
    }

    func loadNext() async throws -> AgentTranscriptGrowth {
        guard !caughtUp, forward != nil else { return .unchanged }
        let epoch = self.epoch
        let size = UInt64(max(0, try await provider.stat(path).size))
        guard epoch == self.epoch, var forward else { return .unchanged }
        if size < forward.position {
            restartFromEnd()
            return .replaced
        }
        var items: [AgentTranscriptItem] = []
        var bytesRead = 0
        while forward.position < size, items.count < pageItems, bytesRead < pageBytes {
            let length = Int(min(UInt64(chunkBytes), size - forward.position))
            let chunk = try await provider.readRange(path, offset: forward.position, length: length)
            guard epoch == self.epoch else { return .unchanged }
            guard !chunk.isEmpty else { break }
            bytesRead += chunk.count
            for line in forward.feed(chunk) {
                items.append(contentsOf: self.items(from: line))
            }
        }
        self.forward = forward
        if forward.position >= size { caughtUp = true }
        return .appended(items, hasMore: !caughtUp)
    }

    /// 变短了：被截断或换掉了。往前翻与往后读都从头来（从末尾），由模型清空后重读。
    private func restartFromEnd() {
        epoch += 1
        scanner = nil
        forward = nil
        anchor = nil
        caughtUp = true
    }

    func loadNewer() async throws -> AgentTranscriptGrowth {
        guard caughtUp, forward != nil else { return .unchanged }
        let epoch = self.epoch
        let size = UInt64(max(0, try await provider.stat(path).size))
        guard epoch == self.epoch, var forward else { return .unchanged }
        if size < forward.position {
            restartFromEnd()
            return .replaced
        }
        guard size > forward.position else { return .unchanged }
        let end = min(size, forward.position + UInt64(followBytes))
        var items: [AgentTranscriptItem] = []
        while forward.position < end {
            let length = Int(min(UInt64(chunkBytes), end - forward.position))
            let chunk = try await provider.readRange(path, offset: forward.position, length: length)
            guard epoch == self.epoch else { return .unchanged }
            // 读的时候又变短了：先把读到的交出去，下一次 stat 会发现。
            guard !chunk.isEmpty else { break }
            for line in forward.feed(chunk) {
                items.append(contentsOf: self.items(from: line))
            }
        }
        self.forward = forward
        return .appended(items, hasMore: forward.position < size)
    }
}

/// 「继续这个会话」在终端里敲的命令：`cd -- '<目录>' && claude --resume <会话 ID>`。
///
/// 会话 ID 只收 UUID 的形状，目录按 POSIX shell 的单引号规则引起来；任何一样不合规矩就不给命令，
/// 不会拼出能注入别的命令的东西。
nonisolated enum ClaudeResumeCommand {
    static func make(sessionID: String, directory: String) -> String? {
        guard isSessionID(sessionID), let quoted = quotedDirectory(directory) else { return nil }
        return "cd -- \(quoted) && claude --resume \(sessionID.lowercased())"
    }

    /// 在这个目录里新开一个会话：`cd -- '<目录>' && claude`。目录的规矩同上。
    static func makeNew(directory: String) -> String? {
        guard let quoted = quotedDirectory(directory) else { return nil }
        return "cd -- \(quoted) && claude"
    }

    /// 8-4-4-4-12 的十六进制。
    static func isSessionID(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.unicodeScalars.allSatisfy { $0.properties.isASCIIHexDigit } }
    }

    /// 绝对路径，没有控制字符（换行打进 shell 就是两条命令）。单引号里只有 `'` 本身要处理：`'\''`。
    static func quotedDirectory(_ directory: String) -> String? {
        guard directory.hasPrefix("/"),
              !directory.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
