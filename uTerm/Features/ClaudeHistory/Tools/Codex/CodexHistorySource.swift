import Foundation

/// 一台主机上 Codex CLI 的历史会话（`~/.codex/sessions/<年>/<月>/<日>/rollout-<时间>-<线程 ID>.jsonl`，
/// 7 天没动过的被 Codex 自己压成 `.jsonl.zst`），经任意 `SFTPProviding` 只读地访问。
///
/// **项目从哪来**：记录按日期分目录，不按工作目录；工作目录写在每份记录的第一行（`session_meta.cwd`）。所以列项目要先知道
/// 每份记录的开头：能跑命令的主机一条命令拿一批（`CodexHostCommand.headersScript`，压缩的在主机上用 `zstd` 解开头），
/// 只许 SFTP 的主机一份一份读开头一小段（压缩的读到能解出第一块为止，实测要 32–92 KB）。开头读过就记在内存里
/// （一份记录的第一行写好就不再变，压缩前后也一样），刷新时只读新出现的。
///
/// **列哪些**：只列一个人在命令行里开的顶层会话（`CodexSessionHeader.isFromCommandLine`）。派出来的子代理（`spawn_agent`）
/// 不单独列，从派它的调用点进去看；审查（guardian）、记忆整理这类内部会话不列；桌面版、VS Code 插件、`codex exec` 起的
/// 进列表但不显示（同 Claude 的「藏起来的」）。一个都没有命令行会话的工作目录不算项目。
///
/// **没列的目录**：`~/.codex/archived_sessions/` 是你在 Codex 里归档掉的会话（桌面版的「归档」、`codex` 的归档命令把文件
/// 挪过去），Codex 自己的「继续会话」列表也不显示它们，这里同样不列。
actor CodexHistorySource: AgentHistorySource {
    nonisolated var tool: AgentHistoryTool { .codex }
    nonisolated var supportsSearch: Bool { true }

    let provider: any SFTPProviding
    private var home: String?
    let searchBatching: ClaudeSearchBatching
    let listing: CodexListing

    /// 第一行的字段，按记录的明文路径（去掉 `.zst`）记：压缩前后是同一份。
    private var headers: [String: CodexSessionHeader] = [:]
    /// 开头读不出来的（坏文件、不是 `session_meta`）。按缓存键记，文件变了再试。
    private var unreadable: Set<AgentHistorySessionFile.CacheKey> = []
    private var cache: [AgentHistorySessionFile.CacheKey: AgentHistorySessionMetadata] = [:]
    /// `session_index.jsonl` 里的会话名，连同读它时的大小与修改时间（没变就不再读）。
    private var names: [String: String] = [:]
    private var namesKey: (size: Int64, mtime: Date)?
    /// 最近一次列出来的东西。
    private var snapshot: Snapshot?
    private var scanning: Task<Snapshot, Error>?
    /// 能不能在主机上跑命令（`nil` = 还没试过）。跑不了的之后就只走 SFTP。
    private(set) var canExecute: Bool?
    /// 主机上有没有 `zstd`（`nil` = 还不知道）。没有时压缩过的记录搜不了。
    private(set) var hostHasZstd: Bool?
    /// 子代理记录开头抄进来的父会话上下文从第几条起不算（`subagent_history_start_ordinal`），按路径记。
    private var subagentStart: [String: Int?] = [:]

    /// `home`：主目录。不给就问 `provider`（`realPath(".")`），测试给一个临时目录。
    init(provider: any SFTPProviding, home: String? = nil, listing: CodexListing = .standard,
         searchBatching: ClaudeSearchBatching = .standard) {
        self.provider = provider
        self.home = home
        self.listing = listing
        self.searchBatching = searchBatching
    }

    /// 列出来的：全部顶层会话（按项目）与子代理记录（按父会话的线程 ID）。
    nonisolated struct Snapshot: Sendable {
        var projects: [AgentHistoryProject]
        var sessions: [String: [AgentHistorySessionFile]]
        var children: [String: [AgentSubagentFile]]
        /// 子代理记录的路径 → 它自己的线程 ID（再往下派的子代理挂在它名下）。
        var childThreadIDs: [String: String]
    }

    func codexHome() async throws -> String {
        if let home { return home + "/.codex" }
        let resolved = try await provider.realPath(".")
        home = resolved
        return resolved + "/.codex"
    }

    func sessionsRoot() async throws -> String { try await codexHome() + "/sessions" }

    // MARK: - 列表

    func projects() async throws -> [AgentHistoryProject] {
        try await rescan().projects
    }

    func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject? {
        Self.project(containing: directory, among: projects)
    }

    /// 自己或最近的上级目录。
    nonisolated static func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject? {
        let target = normalized(directory)
        var best: AgentHistoryProject?
        for project in projects where project.tool == .codex {
            guard let candidate = project.directory.map(normalized) else { continue }
            let contains = target == candidate || candidate == "/" || target.hasPrefix(candidate + "/")
            if contains, candidate.count > (best?.directory.map(normalized)?.count ?? -1) { best = project }
        }
        return best
    }

    nonisolated static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    func sessions(in project: AgentHistoryProject) async throws -> [AgentHistorySessionFile] {
        let snapshot = try await current()
        return snapshot.sessions[project.id] ?? []
    }

    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile] {
        guard let snapshot = try? await current() else { return [] }
        return projects.flatMap { snapshot.sessions[$0.id] ?? [] }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 有就用上一次列的（`projects()` 刚列过），没有才列。
    private func current() async throws -> Snapshot {
        if let snapshot { return snapshot }
        return try await rescan()
    }

    /// 重新列：目录是新列的，开头读过的不再读。同时只有一轮。
    private func rescan() async throws -> Snapshot {
        if let scanning { return try await scanning.value }
        let task = Task { try await self.scan() }
        scanning = task
        defer { scanning = nil }
        let result = try await task.value
        snapshot = result
        return result
    }

    private func scan() async throws -> Snapshot {
        let root = try await sessionsRoot()
        let files = try await listRecordFiles(root: root)
        await readNames()
        try await readHeaders(files, root: root)

        // 同一个线程可能有好几份（回退过：新开一份引用旧的前缀），用最新的那份。
        var newest: [String: (file: CodexRecordFile, header: CodexSessionHeader)] = [:]
        var children: [String: [AgentSubagentFile]] = [:]
        var childThreadIDs: [String: String] = [:]
        for file in files {
            guard let header = headers[file.plainPath] else { continue }
            if header.isTopLevel {
                guard header.cwd != nil else { continue }
                if let existing = newest[header.id], existing.file.modifiedAt >= file.modifiedAt { continue }
                newest[header.id] = (file, header)
            } else if header.source == .threadSpawn, let parent = header.parentThreadID {
                children[parent, default: []].append(AgentSubagentFile(
                    agentID: header.agentID, path: file.path, size: file.size, modifiedAt: file.modifiedAt,
                    hasInfo: false, tool: .codex))
                childThreadIDs[file.path] = header.id
            }
        }
        let byDirectory = Dictionary(grouping: newest.values, by: { Self.normalized($0.header.cwd ?? "") })
        var projects: [AgentHistoryProject] = []
        var sessions: [String: [AgentHistorySessionFile]] = [:]
        for (directory, entries) in byDirectory where entries.contains(where: { $0.header.isFromCommandLine }) {
            let modified = entries.map(\.file.modifiedAt).max()
            let project = AgentHistoryProject(id: directory, path: root, modifiedAt: modified, directory: directory, tool: .codex)
            projects.append(project)
            sessions[project.id] = entries.map { entry in
                AgentHistorySessionFile(sessionID: entry.header.id, project: project, path: entry.file.path,
                                        size: entry.file.size, modifiedAt: entry.file.modifiedAt)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        }
        projects.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        for key in children.keys { children[key]?.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) } }
        return Snapshot(projects: projects, sessions: sessions, children: children, childThreadIDs: childThreadIDs)
    }

    // MARK: 列目录

    /// `<根>/<年>/<月>/<日>/rollout-*.jsonl(.zst)`。几层目录一起列（同时最多 `listing.listConcurrency` 个）。
    /// 同一份记录正在压缩 / 解压时明文与压缩的会同时在：用明文的（Codex 自己也是先认明文）。
    func listRecordFiles(root: String) async throws -> [CodexRecordFile] {
        let years: [RemoteEntry]
        do {
            years = try await provider.list(path: root)
        } catch {
            // 目录不存在 = 这台主机上没用过 Codex。别的错误（没权限、断线）照常报。
            if (try? await provider.stat(root)) == nil { return [] }
            throw error
        }
        var directories = years.filter { $0.isDirectory && Self.isDigits($0.name) }.map { root + "/" + $0.name }
        for _ in 0..<2 {
            let listed = await listAll(directories)
            directories = listed.flatMap { path, entries in
                entries.filter { $0.isDirectory && Self.isDigits($0.name) }.map { path + "/" + $0.name }
            }
        }
        var byPlainPath: [String: CodexRecordFile] = [:]
        for (directory, entries) in await listAll(directories) {
            for entry in entries where !entry.isDirectory {
                guard let file = CodexRecordFile(directory: directory, entry: entry) else { continue }
                if let existing = byPlainPath[file.plainPath], !existing.isCompressed { continue }
                byPlainPath[file.plainPath] = file
            }
        }
        return byPlainPath.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private nonisolated static func isDigits(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// 列不了的目录跳过（刚被删、没权限）。
    private func listAll(_ paths: [String]) async -> [(String, [RemoteEntry])] {
        var result: [(String, [RemoteEntry])] = []
        var next = 0
        await withTaskGroup(of: (String, [RemoteEntry]).self) { group in
            func launch() {
                let path = paths[next]
                next += 1
                group.addTask { (path, (try? await self.provider.list(path: path)) ?? []) }
            }
            while next < min(listing.listConcurrency, paths.count) { launch() }
            while let item = await group.next() {
                result.append(item)
                if next < paths.count { launch() }
            }
        }
        return result
    }

    // MARK: 开头

    /// 还没读过开头的读一遍：先试主机命令（一批一批），剩下的（跑不了命令、主机上没有 zstd、命令输出不全）走 SFTP。
    private func readHeaders(_ files: [CodexRecordFile], root: String) async throws {
        var pending = files.filter { headers[$0.plainPath] == nil && !unreadable.contains($0.cacheKey) }
        guard !pending.isEmpty else { return }
        if canExecute != false {
            pending = try await readHeadersOnHost(pending, root: root)
        }
        try await readHeadersOverSFTP(pending)
    }

    /// 在主机上一批一批读。返回没读到的（要走 SFTP 的）。
    private func readHeadersOnHost(_ files: [CodexRecordFile], root: String) async throws -> [CodexRecordFile] {
        let prefix = root + "/"
        var targets: [(file: CodexRecordFile, name: String)] = []
        var leftover: [CodexRecordFile] = []
        for file in files {
            guard let name = Self.relativeName(file.path, under: prefix) else {
                leftover.append(file)
                continue
            }
            targets.append((file, name))
        }
        let batches = listing.headerBatching.batches(targets, name: \.name, size: { _ in 0 })
        // 子任务不抛错：一批跑不了只是这一批走 SFTP；取消了的回 nil（同样走 SFTP）。
        let failed = await withTaskGroup(
            of: (batch: [(file: CodexRecordFile, name: String)], output: String?).self
        ) { group -> [CodexRecordFile] in
            var next = 0
            var failed: [CodexRecordFile] = []
            func launch() {
                let batch = batches[next]
                next += 1
                let command = CodexHostCommand.headers(root: root, names: batch.map(\.name))
                group.addTask {
                    if Task.isCancelled { return (batch, nil) }
                    return (batch, try? await self.provider.exec(command))
                }
            }
            while next < min(listing.execConcurrency, batches.count) { launch() }
            while let (batch, output) = await group.next() {
                if let output, let payload = try? ClaudeSearchCommand.payload(of: output) {
                    canExecute = true
                    noteZstd(available: !CodexHostCommand.hasNozstdMarker(output))
                    if payload.status == ClaudeSearchCommand.noDirectoryStatus { continue }
                    var seen = Set<Int>()
                    for line in CodexHostCommand.headerLines(payload.lines) where line.index >= 1 && line.index <= batch.count {
                        seen.insert(line.index)
                        let file = batch[line.index - 1].file
                        if let header = line.header {
                            headers[file.plainPath] = header
                        } else if line.missingZstd {
                            failed.append(file)
                        } else {
                            unreadable.insert(file.cacheKey)
                        }
                    }
                    for (index, item) in batch.enumerated() where !seen.contains(index + 1) { failed.append(item.file) }
                } else {
                    // 跑不了命令（只许 SFTP、没有 sh）或者输出不全：这一批走 SFTP。第一批就不行，后面的也别试了。
                    if canExecute == nil, output == nil || (try? ClaudeSearchCommand.payload(of: output ?? "")) == nil {
                        canExecute = false
                        group.cancelAll()
                    }
                    failed.append(contentsOf: batch.map(\.file))
                }
                if canExecute != false, next < batches.count { launch() }
            }
            // 没发出去的批次（跑不了命令时取消了）也走 SFTP。
            if next < batches.count { for batch in batches[next...] { failed.append(contentsOf: batch.map(\.file)) } }
            return failed
        }
        return leftover + failed
    }

    /// 主机的命令输出里有没有「没有 zstd」那一行：有一次没有就记成没有。
    func noteZstd(available: Bool) {
        if !available { hostHasZstd = false } else if hostHasZstd == nil { hostHasZstd = true }
    }

    nonisolated static func relativeName(_ path: String, under prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return "./" + relative
    }

    /// 一份一份读开头（同时 `listing.readConcurrency` 份）。
    private func readHeadersOverSFTP(_ files: [CodexRecordFile]) async throws {
        var next = 0
        await withTaskGroup(of: (CodexRecordFile, Data?).self) { group in
            func launch() {
                let file = files[next]
                next += 1
                group.addTask { (file, try? await self.readPrefix(of: file, bytes: CodexHostCommand.headerBytes)) }
            }
            while next < min(listing.readConcurrency, files.count) { launch() }
            while let (file, data) = await group.next() {
                if let data, let header = CodexSessionHeader.parse(prefix: data) {
                    headers[file.plainPath] = header
                } else if data != nil {
                    unreadable.insert(file.cacheKey)
                }
                if next < files.count { launch() }
            }
        }
    }

    /// 记录开头解开后的至少 `bytes` 字节（不够就是整份）。压缩的一块一块读、边读边解，解出够数就停：
    /// zstd 要读完一整块（解开后 128 KB）才吐得出东西，所以第一次读的不能太少。
    func readPrefix(of file: CodexRecordFile, bytes: Int, compressedLimit: Int = 4 * 1024 * 1024) async throws -> Data {
        guard file.isCompressed else {
            return try await provider.readRange(file.path, offset: 0, length: bytes)
        }
        let stream = CodexZstdStream()
        var output = Data()
        var offset: UInt64 = 0
        var chunk = listing.compressedFirstRead
        while output.count < bytes, offset < file.size, offset < UInt64(compressedLimit) {
            let data = try await provider.readRange(file.path, offset: offset, length: chunk)
            guard !data.isEmpty else { break }
            output.append(try stream.decompress(data, limit: max(bytes, 1) + 4 * 1024 * 1024))
            offset += UInt64(data.count)
            chunk = listing.compressedNextRead
        }
        return output
    }

    // MARK: 会话名

    private func readNames() async {
        guard let home = try? await codexHome() else { return }
        let path = home + "/session_index.jsonl"
        guard let stat = try? await provider.stat(path) else {
            names = [:]
            namesKey = nil
            return
        }
        if let namesKey, namesKey.size == stat.size, namesKey.mtime == stat.mtime { return }
        let length = Int(min(stat.size, Int64(CodexSessionIndex.maxBytes)))
        let offset = UInt64(max(0, stat.size - Int64(length)))
        guard let data = try? await provider.readRange(path, offset: offset, length: length) else { return }
        names = CodexSessionIndex.names(from: data, dropsLeadingPartial: offset > 0)
        namesKey = (stat.size, stat.mtime)
    }

    // MARK: - 一行的信息

    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata {
        if let cached = cache[file.cacheKey] { return cached }
        let record = CodexRecordFile(path: file.path, size: file.size, modifiedAt: file.modifiedAt)
        var header = headers[record.plainPath]
        if header == nil {
            header = CodexSessionHeader.parse(prefix: try await readPrefix(of: record, bytes: CodexHostCommand.headerBytes))
            if let header { headers[record.plainPath] = header }
        }
        let scan = try await CodexSessionScan.scan(record, provider: provider, limits: listing)
        let isEmpty = scan.readWholeFile && !scan.hasConversation
        let metadata = AgentHistorySessionMetadata(
            title: header.flatMap { names[$0.id] } ?? scan.firstUserText ?? scan.lastUserText,
            isListed: (header?.isFromCommandLine ?? false) && !isEmpty,
            lastDirectory: scan.lastDirectory ?? header?.cwd,
            resumeDirectory: header?.cwd ?? file.project.directory,
            gitBranch: scan.gitBranch,
            lastActivity: scan.lastTimestamp ?? (record.isCompressed ? file.modifiedAt : nil))
        cache[file.cacheKey] = metadata
        return metadata
    }

    // MARK: - 对话

    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging {
        Self.pager(provider: provider, path: file.path, anchor: nil, minimumOrdinal: nil)
    }

    nonisolated func transcript(for file: AgentHistorySessionFile, around anchor: AgentTranscriptAnchor) -> any AgentTranscriptPaging {
        Self.pager(provider: provider, path: file.path, anchor: anchor, minimumOrdinal: nil)
    }

    nonisolated static func pager(provider: any SFTPProviding, path: String, anchor: AgentTranscriptAnchor?,
                                  minimumOrdinal: Int?) -> any AgentTranscriptPaging {
        let parse: @Sendable (ClaudeReverseLineScanner.Line) -> [AgentTranscriptItem] = {
            CodexTranscriptParser.items(from: $0, minimumOrdinal: minimumOrdinal)
        }
        if path.hasSuffix(".zst") {
            return CodexCompressedPager(provider: provider, path: path, anchor: anchor, lineParser: parse)
        }
        return ClaudeTranscriptPager(provider: provider, path: path, anchor: anchor, lineParser: parse)
    }

    // MARK: - 子代理

    func subagents(of target: AgentTranscriptTarget) async throws -> [AgentSubagentFile] {
        let snapshot = try await current()
        let threadID: String?
        switch target {
        case .session(let file): threadID = file.sessionID
        case .subagent(let subagent): threadID = snapshot.childThreadIDs[subagent.path]
        }
        guard let threadID else { return [] }
        return snapshot.children[threadID] ?? []
    }

    func info(of subagent: AgentSubagentFile) async -> AgentSubagentInfo? { nil }

    /// 子代理的记录开头抄着父会话的上下文（`subagent_history_start_ordinal` 之前的条目），打开时先读一次第一行再定从哪显示。
    nonisolated func subagentTranscript(for subagent: AgentSubagentFile) -> any AgentTranscriptPaging {
        CodexSubagentPager(source: self, path: subagent.path)
    }

    /// 子代理记录里从第几条起是它自己的。读不出来为 nil（全显示）。
    func subagentStartOrdinal(path: String) async -> Int? {
        if let known = subagentStart[path] { return known }
        let record = CodexRecordFile(path: path, size: UInt64.max, modifiedAt: .distantPast)
        var value: Int?
        if let data = try? await readPrefix(of: record, bytes: CodexSessionScan.firstLineLimit) {
            let line = data.prefix { $0 != 0x0A }
            if let range = line.range(of: Data("\"subagent_history_start_ordinal\":".utf8)) {
                let digits = line[range.upperBound...].prefix { (0x30...0x39).contains($0) }
                value = Int(String(decoding: digits, as: UTF8.self))
            }
        }
        subagentStart[path] = value
        return value
    }

    // MARK: - 命令

    nonisolated func resumeCommand(sessionID: String, directory: String) -> String? {
        CodexResumeCommand.resume(sessionID: sessionID, directory: directory)
    }

    nonisolated func newSessionCommand(directory: String) -> String? {
        CodexResumeCommand.newSession(directory: directory)
    }
}

/// 列表读记录时的并发与读多少。测试换成小的。
nonisolated struct CodexListing: Sendable {
    /// 同时列几个日期目录。
    var listConcurrency = 8
    /// 同时跑几条读开头的命令。
    var execConcurrency = 3
    /// 一条命令读几份的开头：一份回一行约 200 字节，150 份约 30 KB，离 SSH `exec` 的 64 000 字节上限有余量。
    var headerBatching = ClaudeSearchBatching(files: 150, nameBytes: 24_000, bytes: .max, linesFiles: 1)
    /// 只许 SFTP 时同时读几份的开头。
    var readConcurrency = 8
    /// 压缩的记录第一次读多少（实测拿到第一行要 32–92 KB），之后每次再读多少。
    var compressedFirstRead = 64 * 1024
    var compressedNextRead = 64 * 1024
    /// 列表一行读末尾多少（最后活动时间、最后的目录）。
    var tailBytes = 64 * 1024
    /// 找第一句话最多读到解开后的第几字节（实测本机中位数 91 KB、九成在 236 KB 以内）。
    var headScanLimit = 1024 * 1024
    var headChunkBytes = 256 * 1024

    static let standard = CodexListing()
}

/// 列目录看到的一份记录。
nonisolated struct CodexRecordFile: Hashable, Sendable {
    let path: String
    let size: UInt64
    let modifiedAt: Date

    var isCompressed: Bool { path.hasSuffix(".zst") }
    /// 明文的路径（压缩的去掉 `.zst`）：压缩前后是同一份记录。
    var plainPath: String { isCompressed ? String(path.dropLast(".zst".count)) : path }
    var cacheKey: AgentHistorySessionFile.CacheKey { .init(path: path, size: size, modifiedAt: modifiedAt) }

    init(path: String, size: UInt64, modifiedAt: Date) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
    }

    /// 只认 `rollout-*.jsonl` 与 `rollout-*.jsonl.zst`（临时文件 `.rollout-materialize-*`、`*.tmp` 不算）。
    init?(directory: String, entry: RemoteEntry) {
        let name = entry.name
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") else { return nil }
        self.init(path: directory + "/" + name, size: entry.size ?? 0, modifiedAt: entry.modifiedAt ?? .distantPast)
    }
}

/// 「继续这个会话」：`cd -- '<目录>' && codex resume <线程 ID>`；新开：`cd -- '<目录>' && codex`。
/// 线程 ID 只收 UUID 的形状（Codex 的是 UUIDv7），目录的引法同 Claude 的。
nonisolated enum CodexResumeCommand {
    static func resume(sessionID: String, directory: String) -> String? {
        guard ClaudeResumeCommand.isSessionID(sessionID),
              let quoted = ClaudeResumeCommand.quotedDirectory(directory) else { return nil }
        return "cd -- \(quoted) && codex resume \(sessionID.lowercased())"
    }

    static func newSession(directory: String) -> String? {
        guard let quoted = ClaudeResumeCommand.quotedDirectory(directory) else { return nil }
        return "cd -- \(quoted) && codex"
    }
}

/// 子代理记录：先问一次从第几条起是它自己的，再交给普通的读法。
actor CodexSubagentPager: AgentTranscriptPaging {
    private let source: CodexHistorySource
    private let path: String
    private var inner: (any AgentTranscriptPaging)?

    init(source: CodexHistorySource, path: String) {
        self.source = source
        self.path = path
    }

    private func pager() async -> any AgentTranscriptPaging {
        if let inner { return inner }
        let start = await source.subagentStartOrdinal(path: path)
        let made = CodexHistorySource.pager(provider: source.provider, path: path, anchor: nil, minimumOrdinal: start)
        inner = made
        return made
    }

    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool) {
        try await pager().loadPrevious()
    }

    func loadNewer() async throws -> AgentTranscriptGrowth { try await pager().loadNewer() }
    func loadNext() async throws -> AgentTranscriptGrowth { try await pager().loadNext() }
}
