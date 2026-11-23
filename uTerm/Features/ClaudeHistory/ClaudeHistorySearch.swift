import Foundation

/// 在主机上搜 Claude Code 记录要跑的命令：只用系统自带的 `sh`、`printf`、`grep`、`awk`，GNU（Linux）、BSD（macOS）、
/// busybox（Alpine）都实测过。只读，不建任何文件。
///
/// **注入与登录 shell**：命令由登录 shell 解释（sshd 用 `$SHELL -c`，Mac 本机的辅助程序用 `$SHELL -l -c`），登录 shell 可能是
/// sh / bash / zsh / dash，也可能是 fish、csh / tcsh。所以发出去的整串只有一种形状：
///
///     sh -c 'eval "$(printf %b "$1")"' sh '<脚本>' '<参数>' …
///
/// 脚本与参数（搜索词、目录、文件名）全部编码：`[A-Za-z0-9._/,:=+@-]` 原样，其余每个字节写成 `\0ooo`（三位八进制），
/// 再用单引号括起来。于是单引号里只有这些字符和「反斜杠 + 数字」：没有 `'`、换行、`!`、`$`，也没有 `\\` / `\'`——
/// POSIX 系的 shell 单引号里什么都不解释；fish 的单引号里只认 `\\` 与 `\'`；csh 的单引号里只有 `!`（历史替换）与换行特殊。
/// 这几类登录 shell 拿到的都是同一串字节，交给 `sh` 后由 `printf %b` 还原。`printf %b` 不解释 `%`，`\c` 也不会出现
/// （反斜杠本身被编成了 `\0134`）。
///
/// **输出有上限**：SSH 的 `exec` 总输出超过约 64 000 字节整条报错，所以命令只回文件名和数字。输出夹在两行标记之间
/// （登录 shell 的配置文件可能先打印别的东西），结束标记带状态码，没有结束标记就当输出不完整。
nonisolated enum ClaudeSearchCommand {
    static let beginMarker = "uterm-claude-search:begin"
    static let endMarker = "uterm-claude-search:end"
    /// 目录进不去（记录目录没了）。
    static let noDirectoryStatus = 200

    /// 原样放进命令的字节。
    private static let safeBytes: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/,:=+@-".utf8))

    /// 一个参数编码后用单引号括起来。
    static func encodedWord(_ value: String) -> String {
        var output = "'"
        for byte in value.utf8 {
            if safeBytes.contains(byte) {
                output.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                output += "\\0" + String(byte, radix: 8).leftPadded(to: 3)
            }
        }
        return output + "'"
    }

    private static let launcher = #"sh -c 'eval "$(printf %b "$1")"' sh"#

    static func command(script: String, arguments: [String]) -> String {
        ([launcher, encodedWord(script)] + arguments.map(encodedWord)).joined(separator: " ")
    }

    /// 记录里的文字是 JSON 转义过的：拿到主机上找的串也照样转义。只有 `\` 与 `"`（控制字符搜索词里不允许；
    /// Claude Code 写记录时 `/` 与非 ASCII 都是原样）。
    static func jsonEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: 第一段：哪些文件里有这串字

    /// `$2` 搜索串，`$3` 记录根目录，之后是相对根目录的文件（`./` 开头）。回：每行一个有这串字的文件名。
    static let filesScript = #"""
        exec 2>/dev/null
        LC_ALL=C; export LC_ALL
        t=$(printf %b "$2")
        echo uterm-claude-search:begin
        cd "$(printf %b "$3")" || { echo "uterm-claude-search:end 200"; exit 0; }
        shift 3
        for a; do case $a in *\\*) a=$(printf %b "$a");; esac; set -- "$@" "$a"; shift; done
        grep -l -s -i -F -e "$t" -- "$@"
        echo "uterm-claude-search:end $?"
        exit 0
        """#

    static func filesContaining(_ needle: String, root: String, names: [String]) -> String {
        command(script: filesScript, arguments: [needle, root] + names)
    }

    // MARK: 第二段：命中行的位置

    /// `$2` 搜索串，`$3` 记录根目录，`$4` 每份最多几行，`$5` 行的字节上限，之后是文件。
    /// 回：每行 `<第几个文件> <行首偏移> <行长>`（行长不含换行；`LC_ALL=C` 下 awk 的 `length` 是字节数）。
    ///
    /// 只报可能有可显示文字的消息行：先看行首像不像 `user` / `assistant` 行（同 `ClaudeTranscriptParser.isMessageCandidate`），
    /// 再跳过子代理、系统注入、压缩摘要、只有工具结果的、只有思考的。这些都是按 JSON 结构判断的（文字里的引号转义过，
    /// 冒充不了），只是为了少读几行，最后由本机解析确认。每份报够 `$4` 行就不往下读了。
    static let linesScript = #"""
        exec 2>/dev/null
        LC_ALL=C; export LC_ALL
        T=$(printf %b "$2"); export T
        echo uterm-claude-search:begin
        cd "$(printf %b "$3")" || { echo "uterm-claude-search:end 200"; exit 0; }
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
          h = substr($0, 1, 1024)
          if (substr(h, 1, 9) == "{\"type\":\"") {
            if (substr(h, 10, 5) != "user\"" && substr(h, 10, 10) != "assistant\"") next
          } else if (index(h, "\"type\":\"user\"") == 0 && index(h, "\"type\":\"assistant\"") == 0 && index(h, "\"role\":\"user\"") == 0 && index(h, "\"role\":\"assistant\"") == 0) next
          if (index($0, "\"isSidechain\":true") || index($0, "\"isMeta\":true") || index($0, "\"isCompactSummary\":true")) next
          if (index($0, "\"type\":\"text\"") == 0) {
            if (index($0, "\"type\":\"tool_result\"")) next
            if (index($0, "\"type\":\"thinking\"") && index($0, "\"type\":\"tool_use\"") == 0) next
          }
          if (index(tolower($0), t) == 0) next
          print ENVIRON["I"], s, l
          n++
          if (n >= m) exit
        }' "$a"
          r=$?
          case $r in 0) ;; *) s=$r;; esac
        done
        echo "uterm-claude-search:end $s"
        exit 0
        """#

    static func matchingLines(_ needle: String, root: String, maxLines: Int, maxLineBytes: Int, names: [String]) -> String {
        command(script: linesScript, arguments: [needle, root, String(maxLines), String(maxLineBytes)] + names)
    }

    // MARK: 输出

    /// 夹在标记之间的行与结束状态码。没有开始标记 = 命令根本没跑起来（主机只许 SFTP、没有 `sh`）。
    static func payload(of output: String) throws -> (lines: [Substring], status: Int) {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        guard let begin = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == beginMarker }) else {
            throw AgentHistorySearchError.cannotExecute
        }
        let rest = lines[(begin + 1)...]
        guard let end = rest.firstIndex(where: { $0.hasPrefix(endMarker + " ") }) else {
            throw AgentHistorySearchError.incompleteOutput
        }
        let status = Int(lines[end].dropFirst(endMarker.count + 1).trimmingCharacters(in: .whitespaces)) ?? -1
        // 126 / 127：命令找不到或不能执行（grep、awk 缺了）。
        if status == 126 || status == 127 { throw AgentHistorySearchError.missingTools }
        return (Array(lines[(begin + 1)..<end].filter { !$0.isEmpty }), status)
    }

    /// 第二段的一行：`<第几个文件（从 1 起）> <偏移> <长度>`。
    static func lineReferences(_ lines: [Substring]) -> [(file: Int, offset: UInt64, length: Int)] {
        lines.compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 3, let file = Int(parts[0]), let offset = UInt64(parts[1]), let length = Int(parts[2]),
                  file >= 1, length >= 0 else { return nil }
            return (file, offset, length)
        }
    }

    // MARK: 解码（测试与假主机用）

    /// 搜索命令解出来的样子。
    nonisolated enum Request: Equatable, Sendable {
        case files(needle: String, root: String, names: [String])
        case lines(needle: String, root: String, maxLines: Int, maxLineBytes: Int, names: [String])
    }

    /// `command(script:arguments:)` 的逆：不是这种形状就是 nil。
    static func decode(_ command: String) -> Request? {
        guard command.hasPrefix(launcher + " ") else { return nil }
        var words: [String] = []
        var rest = Substring(command.dropFirst(launcher.count + 1))
        while !rest.isEmpty {
            guard rest.first == "'", let close = rest.dropFirst().firstIndex(of: "'") else { return nil }
            guard let word = decodeWord(rest[rest.index(after: rest.startIndex)..<close]) else { return nil }
            words.append(word)
            rest = rest[rest.index(after: close)...]
            if rest.first == " " { rest = rest.dropFirst() }
        }
        guard let script = words.first else { return nil }
        let arguments = Array(words.dropFirst())
        if script == filesScript, arguments.count >= 2 {
            return .files(needle: arguments[0], root: arguments[1], names: Array(arguments.dropFirst(2)))
        }
        if script == linesScript, arguments.count >= 4, let lines = Int(arguments[2]), let bytes = Int(arguments[3]) {
            return .lines(needle: arguments[0], root: arguments[1], maxLines: lines, maxLineBytes: bytes,
                          names: Array(arguments.dropFirst(4)))
        }
        return nil
    }

    private static func decodeWord(_ word: Substring) -> String? {
        var bytes: [UInt8] = []
        var index = word.utf8.startIndex
        let utf8 = word.utf8
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == UInt8(ascii: "\\") {
                let digits = utf8[utf8.index(after: index)...].prefix(4)
                guard digits.count == 4, digits.first == UInt8(ascii: "0"),
                      let value = UInt8(String(decoding: digits.dropFirst(), as: UTF8.self), radix: 8) else { return nil }
                bytes.append(value)
                index = utf8.index(index, offsetBy: 5)
            } else {
                guard safeBytes.contains(byte) else { return nil }
                bytes.append(byte)
                index = utf8.index(after: index)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// 第一段一批交多少份：文件名加起来不超过 `nameBytes`（命令和输出都不会撞上 SSH `exec` 的 64 000 字节、Linux 单个参数的
/// 128 KiB），份数不超过 `files`，记录加起来不超过 `bytes`（一条命令几秒内跑完：取消来得及，Mac 辅助程序 60 秒没输出就结束命令）。
nonisolated struct ClaudeSearchBatching: Equatable, Sendable {
    var files = 300
    var nameBytes = 24_000
    var bytes: UInt64 = 512 * 1024 * 1024
    /// 第二段一条命令查几份。
    var linesFiles = 6

    static let standard = ClaudeSearchBatching()

    /// 按先后切批（不打乱顺序：最近的在前）。
    func batches<T>(_ items: [T], name: (T) -> String, size: (T) -> UInt64) -> [[T]] {
        var result: [[T]] = []
        var current: [T] = []
        var names = 0
        var total: UInt64 = 0
        for item in items {
            let length = name(item).utf8.count + 3
            if !current.isEmpty, current.count >= files || names + length > nameBytes || total + size(item) > bytes {
                result.append(current)
                current = []
                names = 0
                total = 0
            }
            current.append(item)
            names += length
            total += size(item)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

private nonisolated extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}

// MARK: - 两段式搜索

extension ClaudeHistorySource {
    /// 两段式：第一段在主机上找「哪些文件里有这串字」（`grep -l`，一批一批、新的在前）；第二段只对候选文件找出命中行的
    /// 位置（只回数字），本机按位置把那几行读回来解析，确认命中落在可显示的文字里，再截前后文。
    func search(_ query: AgentHistorySearchQuery, in files: [AgentHistorySessionFile], limits: AgentHistorySearchLimits,
                onEvent: @escaping @Sendable (AgentHistorySearchEvent) async -> Void) async throws {
        let root = try await projectsRoot()
        let prefix = root + "/"
        // 只搜主对话：项目目录下第一层的 `<会话 ID>.jsonl`（`subagents/` 里的不搜）。
        let targets: [(file: AgentHistorySessionFile, name: String)] = files.compactMap { file in
            guard file.path.hasPrefix(prefix), file.path.hasSuffix(".jsonl") else { return nil }
            let relative = String(file.path.dropFirst(prefix.count))
            guard relative.split(separator: "/", omittingEmptySubsequences: false).count == 2,
                  !relative.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
            return (file, "./" + relative)
        }
        .sorted { $0.file.modifiedAt > $1.file.modifiedAt }
        let needle = ClaudeSearchCommand.jsonEscaped(query.text)
        var searched = 0
        var hitCount = 0
        await onEvent(.progress(searched: 0, total: targets.count))
        let batches = searchBatching.batches(targets, name: \.name, size: \.file.size)
        for batch in batches {
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
                    ClaudeSearchCommand.matchingLines(needle, root: root, maxLines: limits.candidateLinesPerSession,
                                                      maxLineBytes: limits.maxLineBytes, names: chunk.map(\.name)),
                    root: root)
                let references = ClaudeSearchCommand.lineReferences(lines.lines)
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

    /// 跑一条搜索命令，取标记之间的输出。`exec` 失败时，连接还在（还能列记录目录）就是这台主机跑不了命令（只许 SFTP）。
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
        // 记录目录没了：当作没有结果。
        if payload.status == ClaudeSearchCommand.noDirectoryStatus { return ([], payload.status) }
        return payload
    }

    /// 只留列表里会列出来的（命令行起的、有对话内容的）；信息照列表那样读（有缓存），一次读几份。
    private func listedSessions(_ candidates: [(file: AgentHistorySessionFile, name: String)]) async throws
        -> [(file: AgentHistorySessionFile, name: String, metadata: AgentHistorySessionMetadata)] {
        var result: [(file: AgentHistorySessionFile, name: String, metadata: AgentHistorySessionMetadata)] = []
        var start = 0
        while start < candidates.count {
            try Task.checkCancellation()
            let chunk = Array(candidates[start..<min(candidates.count, start + Self.searchMetadataConcurrency)])
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

    static let searchMetadataConcurrency = 4
    /// 读回来确认的行：相邻的（隔不到这么多字节）一次读，一次最多读这么多。
    static let searchReadGap: UInt64 = 64 * 1024
    static let searchReadSpan: UInt64 = 2 * 1024 * 1024

    /// 把主机报回来的几行读回来解析：命中要落在可显示的文字里（`AgentHistorySearchMatcher.searchableText`）。
    private func confirm(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata,
                         references: [(file: Int, offset: UInt64, length: Int)], query: AgentHistorySearchQuery,
                         limit: Int, maxLineBytes: Int) async throws -> AgentHistorySearchSession? {
        guard limit > 0 else { return nil }
        let refs = references.filter { $0.length > 0 && $0.length <= maxLineBytes }.sorted { $0.offset < $1.offset }
        var hits: [AgentHistorySearchHit] = []
        var hasMore = false
        groups: for group in Self.readGroups(refs) {
            try Task.checkCancellation()
            guard let first = group.first, let last = group.last else { continue }
            // 前后各多读一个字节，核对确实是整行（行首前、行尾后是换行）。
            let start = first.offset == 0 ? 0 : first.offset - 1
            let end = last.offset + UInt64(last.length) + 1
            let data = try await provider.readRange(file.path, offset: start, length: Int(end - start))
            for ref in group {
                guard let line = Self.line(at: ref.offset, length: ref.length, in: data, from: start) else { continue }
                let items = ClaudeTranscriptParser.items(fromJSON: line, idPrefix: String(ref.offset))
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

    nonisolated static func readGroups(_ refs: [(file: Int, offset: UInt64, length: Int)])
        -> [[(file: Int, offset: UInt64, length: Int)]] {
        var groups: [[(file: Int, offset: UInt64, length: Int)]] = []
        for ref in refs {
            if let current = groups.last, let first = current.first, let last = current.last {
                let lastEnd = last.offset + UInt64(last.length)
                let span = ref.offset + UInt64(ref.length) - first.offset
                if ref.offset >= lastEnd, ref.offset - lastEnd <= searchReadGap, span <= searchReadSpan {
                    groups[groups.count - 1].append(ref)
                    continue
                }
            }
            groups.append([ref])
        }
        return groups
    }

    /// 从读回来的那块里取出 `[offset, offset + length)` 这一行；前后不是换行（文件变了、主机算错了偏移）就是 nil。
    nonisolated static func line(at offset: UInt64, length: Int, in data: Data, from start: UInt64) -> Data? {
        let data = Data(data)
        guard offset >= start else { return nil }
        let lower = Int(offset - start)
        let upper = lower + length
        guard upper <= data.count else { return nil }
        if offset > 0 {
            guard lower >= 1, data[lower - 1] == 0x0A else { return nil }
        }
        if upper < data.count, data[upper] != 0x0A { return nil }
        var line = data.subdata(in: lower..<upper)
        if line.last == 0x0D { line.removeLast() }
        return line
    }
}
