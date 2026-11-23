import Foundation

/// 一台主机上 Claude Code 的历史会话（`~/.claude/projects`），经任意 `SFTPProviding` 只读地访问：
/// SSH 主机是 `SFTPSession`，本机是经辅助程序的那个（沙盒里的 App 读不到 `~/.claude`）。
actor ClaudeHistorySource: AgentHistorySource {
    private let provider: any SFTPProviding
    /// 列表一行先读末尾这么多。实测本机 1600 多份记录，64 KB 里有 `entrypoint` 的占 99%、有标题的也是 99%。
    static let tailBytes = 64 * 1024
    /// 末尾没定下来源时从开头往后找，最多读这么多（只在少数大文件开头全是快照行时用得到）。
    static let headScanLimit = 1024 * 1024
    static let headChunkBytes = 256 * 1024
    /// 「全部项目」时同时列几个目录。
    static let listConcurrency = 6

    /// 子代理的信息文件很小（实测几百字节），读这么多足够。
    static let subagentInfoBytes = 64 * 1024

    private var home: String?
    private var cache: [AgentHistorySessionFile.CacheKey: AgentHistorySessionMetadata] = [:]
    /// 子代理的信息文件读过就不再读（按路径；它在子代理派出时写好，之后基本不变）。
    private var infoCache: [String: AgentSubagentInfo] = [:]

    /// `home`：主目录。不给就问 `provider`（`realPath(".")`：SFTP 与远控文件服务都把它解析成登录用户的主目录）；
    /// 测试给一个临时目录。
    init(provider: any SFTPProviding, home: String? = nil) {
        self.provider = provider
        self.home = home
    }

    private func projectsRoot() async throws -> String {
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
            // 目录不存在 = 这台主机上没用过 Claude Code。别的错误（没权限、断线）照常报。
            if (try? await provider.stat(root)) == nil { return [] }
            throw error
        }
        return entries
            .filter { ($0.isDirectory || $0.isSymlink) && !$0.name.hasPrefix(".") }
            .map { AgentHistoryProject(id: $0.name, path: root + "/" + $0.name, modifiedAt: $0.modifiedAt) }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
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
        return files.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 全部项目的会话合在一起，新的在前。列不了的项目跳过。
    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile] {
        var result: [AgentHistorySessionFile] = []
        var next = 0
        await withTaskGroup(of: [AgentHistorySessionFile].self) { group in
            func launch() {
                let project = projects[next]
                next += 1
                group.addTask { (try? await self.sessions(in: project)) ?? [] }
            }
            while next < min(Self.listConcurrency, projects.count) { launch() }
            while let files = await group.next() {
                result.append(contentsOf: files)
                if next < projects.count { launch() }
            }
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata {
        if let cached = cache[file.cacheKey] { return cached }
        let scan = try await Self.scan(file: file, provider: provider)
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
            lastActivity: scan.lastTimestamp)
        cache[file.cacheKey] = metadata
        return metadata
    }

    /// 读末尾一块；来源没定下来再从开头往后读几块。
    static func scan(file: AgentHistorySessionFile, provider: any SFTPProviding) async throws -> ClaudeSessionScan {
        let size = file.size
        let tailLength = Int(min(size, UInt64(tailBytes)))
        let tailOffset = size - UInt64(tailLength)
        let tail = try await provider.readRange(file.path, offset: tailOffset, length: tailLength)
        var scan = ClaudeSessionScan.scan(tail, dropsLeadingPartial: tailOffset > 0, dropsTrailingPartial: false)
        guard !scan.isOriginDecided, tailOffset > 0 else { return scan }

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
        scan = scan.merged(withEarlier: head)
        return scan
    }

    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging {
        ClaudeTranscriptPager(provider: provider, path: file.path)
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
        .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
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
}

/// 从文件末尾往前一页一页读对话。文件在看的时候可能还在长（会话正开着），只读第一次打开时那么长。
actor ClaudeTranscriptPager: AgentTranscriptPaging {
    private let provider: any SFTPProviding
    private let path: String
    private let chunkBytes: Int
    private let pageItems: Int
    private let pageBytes: Int
    /// 子代理自己的记录每行都是 `isSidechain`，要照常显示。
    private let includesSidechain: Bool
    private var scanner: ClaudeReverseLineScanner?

    init(provider: any SFTPProviding, path: String, includesSidechain: Bool = false,
         chunkBytes: Int = AgentTranscriptLimits.chunkBytes,
         pageItems: Int = AgentTranscriptLimits.pageItems,
         pageBytes: Int = AgentTranscriptLimits.pageBytes,
         maxLineBytes: Int = AgentTranscriptLimits.maxLineBytes) {
        self.provider = provider
        self.path = path
        self.chunkBytes = chunkBytes
        self.pageItems = pageItems
        self.pageBytes = pageBytes
        self.includesSidechain = includesSidechain
        self.maxLineBytes = maxLineBytes
    }

    private let maxLineBytes: Int

    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool) {
        if scanner == nil {
            let size = try await provider.stat(path).size
            scanner = ClaudeReverseLineScanner(fileSize: UInt64(max(0, size)), maxLineBytes: maxLineBytes)
        }
        // 在副本上读，整页读完才写回：中途出错（断线）下次从同一个位置重读，不会漏行。
        guard var scanner else { return ([], true) }
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
            for line in scanner.feed(chunk) {
                let items = ClaudeTranscriptParser.items(from: line, includesSidechain: includesSidechain)
                if !items.isEmpty {
                    newestFirst.append(items)
                    count += items.count
                }
            }
            if scanner.nextRange(chunkSize: chunkBytes) == nil, let first = scanner.finish() {
                let items = ClaudeTranscriptParser.items(from: first, includesSidechain: includesSidechain)
                if !items.isEmpty { newestFirst.append(items) }
            }
        }
        if scanner.nextRange(chunkSize: chunkBytes) == nil, !scanner.isAtStart {
            _ = scanner.finish()   // 空文件
        }
        self.scanner = scanner
        return (newestFirst.reversed().flatMap { $0 }, scanner.isAtStart)
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
