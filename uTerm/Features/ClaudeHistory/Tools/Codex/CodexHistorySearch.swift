import Foundation

/// 搜索没能覆盖到的那部分（**提议的、只加不改的扩展**，不改共用的 `AgentHistorySearchEvent`）：
/// 实现了这个协议的数据源能说出「这些会话里有几份这台主机上搜不了、为什么」。界面在搜之前（或搜完后）问一次，
/// 在结果下面加一句说明；不实现的数据源照旧（当作全都能搜）。
protocol AgentHistorySearchCoverageReporting: AgentHistorySource {
    func searchCoverage(of files: [AgentHistorySessionFile]) async -> AgentHistorySearchCoverage
}

nonisolated struct AgentHistorySearchCoverage: Equatable, Sendable {
    /// 搜不了的份数。
    var unsearchable: Int
    var reason: Reason?

    nonisolated enum Reason: Equatable, Sendable {
        /// 压缩过的记录，主机上没有解压工具（Codex：`zstd`）。
        case missingDecompressor
    }

    static let complete = AgentHistorySearchCoverage(unsearchable: 0, reason: nil)
}

extension CodexHistorySource: AgentHistorySearchCoverageReporting {
    /// 压缩过的记录要在主机上用 `zstd` 解开了找。主机上有没有 `zstd`，列表那一步（读开头的命令）就知道了；
    /// 还不知道时问一次。
    func searchCoverage(of files: [AgentHistorySessionFile]) async -> AgentHistorySearchCoverage {
        let compressed = files.filter { $0.path.hasSuffix(".zst") }.count
        guard compressed > 0 else { return .complete }
        if hostHasZstd == nil { await probeZstd() }
        return hostHasZstd == false ? AgentHistorySearchCoverage(unsearchable: compressed, reason: .missingDecompressor) : .complete
    }

    /// `command -v zstd`：结果用标记行带回来（登录 shell 的配置文件可能先打印别的东西）。
    private func probeZstd() async {
        let script = """
            exec 2>/dev/null
            echo uterm-claude-search:begin
            command -v zstd >/dev/null 2>&1 || echo \(CodexHostCommand.nozstdMarker)
            echo "uterm-claude-search:end 0"
            """
        guard let output = try? await provider.exec(ClaudeSearchCommand.command(script: script, arguments: [])),
              (try? ClaudeSearchCommand.payload(of: output)) != nil else { return }
        noteZstd(available: !CodexHostCommand.hasNozstdMarker(output))
    }

    /// 两段式，同 Claude：第一段在主机上找「哪些文件里有这串字」（压缩的用 `zstd -dc` 解开了找），第二段只对候选文件
    /// 找出命中行的位置，本机读回那几行解析确认。压缩的记录本机没法按位置读，第二段让主机把那一行原样带回来
    /// （一份一条命令，单行与总量都有上限，超了的那一行确认不了、不报）。
    ///
    /// 主机上没有 `zstd` 时压缩的那些跳过（进度照算，`searchCoverage` 能说出跳过了几份）。
    func search(_ query: AgentHistorySearchQuery, in files: [AgentHistorySessionFile], limits: AgentHistorySearchLimits,
                onEvent: @escaping @Sendable (AgentHistorySearchEvent) async -> Void) async throws {
        let root = try await sessionsRoot()
        let prefix = root + "/"
        let targets: [(file: AgentHistorySessionFile, name: String)] = files.compactMap { file in
            guard file.project.tool == .codex, let name = Self.relativeName(file.path, under: prefix) else { return nil }
            return (file, name)
        }
        .sorted { AgentHistorySessionFile.newestFirst($0.file, $1.file) }
        let needle = ClaudeSearchCommand.jsonEscaped(query.text)
        var searched = 0
        var hitCount = 0
        await onEvent(.progress(searched: 0, total: targets.count))
        // 明文与压缩的分开成批（压缩的要在主机上解，按解开后的大小估：Codex 用 zstd 等级 3，实测约 3.5 倍）。
        for batch in Self.batches(targets, batching: searchBatching) {
            try Task.checkCancellation()
            let found = try await runCommand(CodexHostCommand.filesContaining(needle, root: root, names: batch.map(\.name)),
                                             root: root)
            let matched = Set(found.lines.map(String.init))
            searched += batch.count
            let listed = try await listedSessions(batch.filter { matched.contains($0.name) })
            let compressed = batch.first?.file.path.hasSuffix(".zst") == true
            let perCommand = compressed ? 1 : max(1, searchBatching.linesFiles)
            var start = 0
            while start < listed.count {
                try Task.checkCancellation()
                let chunk = Array(listed[start..<min(listed.count, start + perCommand)])
                start += chunk.count
                let lines = try await runCommand(
                    CodexHostCommand.matchingLines(needle, root: root, maxLines: limits.candidateLinesPerSession,
                                                   maxLineBytes: limits.maxLineBytes,
                                                   inlineLineBytes: Self.inlineLineBytes, inlineTotalBytes: Self.inlineTotalBytes,
                                                   names: chunk.map(\.name)),
                    root: root)
                let references = CodexHostCommand.lineReferences(lines.lines)
                for (index, candidate) in chunk.enumerated() {
                    try Task.checkCancellation()
                    let room = min(limits.hitsPerSession, limits.totalHits - hitCount)
                    let refs = references.filter { $0.file == index + 1 }
                    guard let session = try await confirm(candidate.file, metadata: candidate.metadata, references: refs,
                                                          query: query, limit: room, maxLineBytes: limits.maxLineBytes)
                    else { continue }
                    hitCount += session.hits.count
                    await onEvent(.session(session))
                    if hitCount >= limits.totalHits {
                        await onEvent(.progress(searched: searched, total: targets.count))
                        await onEvent(.finished(truncated: true))
                        return
                    }
                }
            }
            await onEvent(.progress(searched: searched, total: targets.count))
        }
        await onEvent(.finished(truncated: false))
    }

    /// 压缩的记录第二段带回来的行：单行最多这么大、一条命令加起来最多这么多（离 `exec` 的 64 000 字节上限有余量）。
    static let inlineLineBytes = 16 * 1024
    static let inlineTotalBytes = 44 * 1024

    /// 按先后切批，明文与压缩的不混在一批里。
    nonisolated static func batches(_ targets: [(file: AgentHistorySessionFile, name: String)],
                                    batching: ClaudeSearchBatching) -> [[(file: AgentHistorySessionFile, name: String)]] {
        var runs: [[(file: AgentHistorySessionFile, name: String)]] = []
        for target in targets {
            let compressed = target.file.path.hasSuffix(".zst")
            if let last = runs.last?.last, last.file.path.hasSuffix(".zst") == compressed {
                runs[runs.count - 1].append(target)
            } else {
                runs.append([target])
            }
        }
        return runs.flatMap { run in
            batching.batches(run, name: \.name, size: { item in
                item.file.path.hasSuffix(".zst") ? item.file.size.multipliedReportingOverflow(by: 4).partialValue : item.file.size
            })
        }
    }

    private func runCommand(_ command: String, root: String) async throws -> (lines: [Substring], status: Int) {
        let output: String
        do {
            output = try await provider.exec(command)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if (try? await provider.list(path: root)) != nil { throw AgentHistorySearchError.cannotExecute }
            throw error
        }
        try Task.checkCancellation()
        let payload = try ClaudeSearchCommand.payload(of: output)
        noteZstd(available: !CodexHostCommand.hasNozstdMarker(output))
        if payload.status == ClaudeSearchCommand.noDirectoryStatus { return ([], payload.status) }
        return payload
    }

    private func listedSessions(_ candidates: [(file: AgentHistorySessionFile, name: String)]) async throws
        -> [(file: AgentHistorySessionFile, name: String, metadata: AgentHistorySessionMetadata)] {
        var result: [(file: AgentHistorySessionFile, name: String, metadata: AgentHistorySessionMetadata)] = []
        var start = 0
        while start < candidates.count {
            try Task.checkCancellation()
            let chunk = Array(candidates[start..<min(candidates.count, start + ClaudeHistorySource.searchMetadataConcurrency)])
            start += chunk.count
            let read = await withTaskGroup(of: (Int, AgentHistorySessionMetadata?).self) { group in
                for (index, candidate) in chunk.enumerated() {
                    group.addTask { (index, try? await self.metadata(for: candidate.file)) }
                }
                var values = [AgentHistorySessionMetadata?](repeating: nil, count: chunk.count)
                for await (index, value) in group { values[index] = value }
                return values
            }
            for (candidate, metadata) in zip(chunk, read) {
                guard let metadata, metadata.isListed else { continue }
                result.append((candidate.file, candidate.name, metadata))
            }
        }
        return result
    }

    /// 命中要落在可显示的文字里。明文的按位置读回来（相邻的一次读）；压缩的用主机带回来的那一行。
    private func confirm(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata,
                         references: [CodexHostCommand.LineReference], query: AgentHistorySearchQuery,
                         limit: Int, maxLineBytes: Int) async throws -> AgentHistorySearchSession? {
        guard limit > 0 else { return nil }
        let refs = references.filter { $0.length > 0 && $0.length <= maxLineBytes }.sorted { $0.offset < $1.offset }
        var lines: [(ref: CodexHostCommand.LineReference, data: Data)] = []
        if file.path.hasSuffix(".zst") {
            lines = refs.compactMap { ref in ref.inline.map { (ref, $0) } }
        } else {
            let tuples = refs.map { (file: $0.file, offset: $0.offset, length: $0.length) }
            for group in ClaudeHistorySource.readGroups(tuples) {
                try Task.checkCancellation()
                guard let first = group.first, let last = group.last else { continue }
                let start = first.offset == 0 ? 0 : first.offset - 1
                let end = last.offset + UInt64(last.length) + 1
                let data = try await provider.readRange(file.path, offset: start, length: Int(end - start))
                for ref in group {
                    guard let line = ClaudeHistorySource.line(at: ref.offset, length: ref.length, in: data, from: start) else { continue }
                    lines.append((CodexHostCommand.LineReference(file: ref.file, offset: ref.offset, length: ref.length), line))
                }
            }
        }
        var hits: [AgentHistorySearchHit] = []
        var hasMore = false
        for (ref, line) in lines {
            let items = CodexTranscriptParser.items(fromJSON: line, idPrefix: String(ref.offset))
            guard let hit = AgentHistorySearchMatcher.firstHit(in: items, query: query) else { continue }
            if hits.count == limit {
                hasMore = true
                break
            }
            hits.append(AgentHistorySearchHit(itemID: hit.item.id, role: hit.item.role, snippet: hit.snippet,
                                              timestamp: hit.item.timestamp,
                                              anchor: AgentTranscriptAnchor(lineOffset: ref.offset, lineLength: ref.length)))
        }
        return hits.isEmpty ? nil : AgentHistorySearchSession(file: file, metadata: metadata, hits: hits, hasMoreHits: hasMore)
    }
}
