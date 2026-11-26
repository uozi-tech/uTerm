import Foundation

/// 在主机上搜 Antigravity 记录要跑的命令。编码、登录 shell、输出标记与上限的道理都同 `ClaudeSearchCommand`（这里直接用它的
/// 编码、拼装与取输出），第一段「哪些文件里有这串字」也是同一个脚本；只有第二段挑行的规矩是 Antigravity 自己的。
nonisolated enum AntigravitySearchCommand {
    /// `$2` 搜索串，`$3` 根目录，`$4` 每份最多几行，`$5` 行的字节上限，之后是文件。回：每行 `<第几个文件> <行首偏移> <行长>`。
    ///
    /// 只报你说的话（`USER_INPUT`）与模型的一步（`PLANNER_RESPONSE`）：工具结果、系统消息、压缩摘要不参与搜索。`type` 在行首
    /// 一百字节以内（`{"step_index":…,"source":"…","type":"…"`），文字里的引号转义过，冒充不了。
    ///
    /// 找之前先去掉不参与搜索的两段，免得每份只报的那几行被它们占满（本机实测模型的步里多半是长长的思考，搜常见的词时
    /// 候选行几乎全落在思考里）：模型那步的 `"thinking":"…"`（键在 `content` 之后、`tool_calls` 之前；字符串里的引号都转义过，
    /// `,"tool_calls":[` 只会是真的下一个键），你那步的 `<ADDITIONAL_METADATA>…</ADDITIONAL_METADATA>`。剩下的误报
    /// （命中在工具参数的长文字里）由本机解析时丢掉。
    static let linesScript = #"""
        exec 2>/dev/null
        LC_ALL=C; export LC_ALL
        T=$(printf %b "$2"); export T
        echo \#(ClaudeSearchCommand.beginMarker)
        cd "$(printf %b "$3")" || { echo "\#(ClaudeSearchCommand.endMarker) \#(ClaudeSearchCommand.noDirectoryStatus)"; exit 0; }
        M=$4; X=$5; export M X
        shift 5
        I=0; s=0
        for a; do
          case $a in *\\*) a=$(printf %b "$a");; esac
          I=$((I + 1)); export I
          awk '
        BEGIN { t = tolower(ENVIRON["T"]); m = ENVIRON["M"] + 0; x = ENVIRON["X"] + 0; o = 0; n = 0 }
        {
          l = length($0); s = o; o += l + 1
          if (l > x) next
          h = substr($0, 1, 256)
          if (index(h, "\"type\":\"PLANNER_RESPONSE\"")) {
            b = $0; i = index(b, ",\"thinking\":\"")
            if (i) { r = substr(b, i + 1); j = index(r, ",\"tool_calls\":["); b = substr(b, 1, i - 1); if (j) b = b substr(r, j) }
          } else if (index(h, "\"type\":\"USER_INPUT\"")) {
            b = $0; i = index(b, "<ADDITIONAL_METADATA>")
            if (i) { r = substr(b, i); j = index(r, "</ADDITIONAL_METADATA>"); b = substr(b, 1, i - 1); if (j) b = b substr(r, j + 22) }
          } else next
          if (index(tolower(b), t) == 0) next
          print ENVIRON["I"], s, l
          n++
          if (n >= m) exit
        }' "$a"
          r=$?
          case $r in 0) ;; *) s=$r;; esac
        done
        echo "\#(ClaudeSearchCommand.endMarker) $s"
        exit 0
        """#

    static func matchingLines(_ needle: String, root: String, maxLines: Int, maxLineBytes: Int, names: [String]) -> String {
        ClaudeSearchCommand.command(script: linesScript,
                                    arguments: [needle, root, String(maxLines), String(maxLineBytes)] + names)
    }
}

extension AntigravityHistorySource {
    /// 两段式，同 Claude：第一段 `grep -l` 找出有这串字的记录（一批一批、新的在前），第二段只对候选记录报命中行的位置，
    /// 本机按位置读回那几行解析，确认命中落在可显示的文字里再截前后文。
    ///
    /// 记录在几个数据目录里，命令在主目录下跑，文件名写成相对主目录的 `./.gemini/…`。
    func search(_ query: AgentHistorySearchQuery, in files: [AgentHistorySessionFile], limits: AgentHistorySearchLimits,
                onEvent: @escaping @Sendable (AgentHistorySearchEvent) async -> Void) async throws {
        let root = try await homeDirectory()
        let targets = Self.searchTargets(files, home: root, roots: roots)
        let needle = ClaudeSearchCommand.jsonEscaped(query.text)
        var searched = 0
        var hitCount = 0
        await onEvent(.progress(searched: 0, total: targets.count))
        for batch in searchBatching.batches(targets, name: \.name, size: \.file.size) {
            try Task.checkCancellation()
            let found = try await runSearchCommand(
                ClaudeSearchCommand.filesContaining(needle, root: root, names: batch.map(\.name)), root: root)
            let matched = Set(found.lines.map(String.init))
            let candidates = batch.filter { matched.contains($0.name) }
            searched += batch.count
            let listed = try await listedSessions(candidates)
            var start = 0
            while start < listed.count {
                try Task.checkCancellation()
                let chunk = Array(listed[start..<min(listed.count, start + max(1, searchBatching.linesFiles))])
                start += chunk.count
                let lines = try await runSearchCommand(
                    AntigravitySearchCommand.matchingLines(needle, root: root, maxLines: limits.candidateLinesPerSession,
                                                           maxLineBytes: limits.maxLineBytes, names: chunk.map(\.name)),
                    root: root)
                let references = ClaudeSearchCommand.lineReferences(lines.lines)
                for (index, candidate) in chunk.enumerated() {
                    try Task.checkCancellation()
                    let room = min(limits.hitsPerSession, limits.totalHits - hitCount)
                    guard let session = try await confirm(candidate.file, metadata: candidate.metadata,
                                                          references: references.filter { $0.file == index + 1 },
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

    /// 只搜主对话的记录：`<数据目录>/brain/<ID>/.system_generated/logs/<记录>`，换成相对主目录的名字。新的在前。
    nonisolated static func searchTargets(_ files: [AgentHistorySessionFile], home: String, roots: [DataRoot])
        -> [(file: AgentHistorySessionFile, name: String)] {
        let prefixes = roots.map { home + "/" + $0.relativePath + "/brain/" }
        return files.compactMap { file -> (file: AgentHistorySessionFile, name: String)? in
            guard let prefix = prefixes.first(where: { file.path.hasPrefix($0) }) else { return nil }
            let inner = file.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
            guard inner.count == 4, isConversationName(String(inner[0])),
                  "\(inner[1])/\(inner[2])" == logsDirectory,
                  inner[3] == fullTranscriptName || inner[3] == shortTranscriptName,
                  !file.path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
            return (file, "./" + String(file.path.dropFirst(home.count + 1)))
        }
        .sorted { AgentHistorySessionFile.newestFirst($0.file, $1.file) }
    }

    /// 跑一条搜索命令，取标记之间的输出。`exec` 失败时，连接还在（还能列主目录）就是这台主机跑不了命令（只许 SFTP）。
    private func runSearchCommand(_ command: String, root: String) async throws -> (lines: [Substring], status: Int) {
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
        if payload.status == ClaudeSearchCommand.noDirectoryStatus { return ([], payload.status) }
        return payload
    }

    /// 只留列表里会列出来的；信息照列表那样读（有缓存）。
    private func listedSessions(_ candidates: [(file: AgentHistorySessionFile, name: String)]) async throws
        -> [(file: AgentHistorySessionFile, name: String, metadata: AgentHistorySessionMetadata)] {
        var result: [(file: AgentHistorySessionFile, name: String, metadata: AgentHistorySessionMetadata)] = []
        for candidate in candidates {
            try Task.checkCancellation()
            guard let metadata = try? await metadata(for: candidate.file), metadata.isListed else { continue }
            result.append((candidate.file, candidate.name, metadata))
        }
        return result
    }

    /// 把主机报回来的几行读回来解析：命中要落在可显示的文字里（`AgentHistorySearchMatcher.searchableText`）。
    private func confirm(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata,
                         references: [(file: Int, offset: UInt64, length: Int)], query: AgentHistorySearchQuery,
                         limit: Int, maxLineBytes: Int) async throws -> AgentHistorySearchSession? {
        guard limit > 0 else { return nil }
        let encodedArgs = file.path.hasSuffix("/" + Self.shortTranscriptName)
        let refs = references.filter { $0.length > 0 && $0.length <= maxLineBytes }.sorted { $0.offset < $1.offset }
        var hits: [AgentHistorySearchHit] = []
        var hasMore = false
        groups: for group in ClaudeHistorySource.readGroups(refs) {
            try Task.checkCancellation()
            guard let first = group.first, let last = group.last else { continue }
            // 前后各多读一个字节，核对确实是整行。
            let start = first.offset == 0 ? 0 : first.offset - 1
            let end = last.offset + UInt64(last.length) + 1
            let data = try await provider.readRange(file.path, offset: start, length: Int(end - start))
            for ref in group {
                guard let line = ClaudeHistorySource.line(at: ref.offset, length: ref.length, in: data, from: start) else { continue }
                let items = AntigravityTranscriptParser.items(fromJSON: line, idPrefix: String(ref.offset), encodedArgs: encodedArgs)
                guard let hit = AgentHistorySearchMatcher.firstHit(in: items, query: query) else { continue }
                if hits.count == limit {
                    hasMore = true
                    break groups
                }
                hits.append(AgentHistorySearchHit(itemID: hit.item.id, role: hit.item.role, snippet: hit.snippet,
                                                  timestamp: hit.item.timestamp,
                                                  anchor: AgentTranscriptAnchor(lineOffset: ref.offset, lineLength: ref.length)))
            }
        }
        return hits.isEmpty ? nil : AgentHistorySearchSession(file: file, metadata: metadata, hits: hits, hasMoreHits: hasMore)
    }
}
