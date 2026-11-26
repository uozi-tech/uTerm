import Foundation

/// Codex 自己维护的会话索引：`~/.codex/state_<N>.sqlite` 的 `threads` 表（N 是格式版本，取最大的那个）。每个线程一行，
/// 记录文件在哪（`rollout_path`）、第一行 `session_meta` 里的那几个字段（工作目录、来源、`originator`……），
/// `updated_at_ms` 跟着记录文件的修改时间走（实测本机最近 400 份一秒不差）。
///
/// 列表用它省掉两样：冷启动时一份份读记录开头（本机两千多份要跑 14 条命令、八秒多），以及每次重列都把几百个日期目录
/// 列一遍（库里哪些线程变了一查就知道，没变的日期目录不用再列）。库在主机上用 `sqlite3` 只读地查（`?mode=ro`，
/// 不用 `immutable=1`：那样读不到 WAL 里新写的）；主机上没有 `sqlite3`、库查不了的，数据源退回原来的读法。
///
/// 和读记录开头的差别：库里的 `cwd` 是 Codex 后来规整过的（`/tmp` → `/private/tmp`、项目挪了地方之后的新路径），
/// 它自己的「继续会话」列表也按这个分；派出来的子代理库里没写 `originator`（不影响：子代理本来就不单独列）。
nonisolated enum CodexStateIndex {
    static let beginMarker = "uterm-codex-index:begin"
    static let endMarker = "uterm-codex-index:end"
    /// 主机上没有 `sqlite3`。
    static let missingStatus = 127

    /// `~/.codex` 里的库：`state_<N>.sqlite` 取 N 最大的；连同它的 `-wal`（大小、修改时间都没变就不用再查）。
    nonisolated struct Database: Equatable, Sendable {
        let path: String
        let fingerprint: [SQLiteFileState?]
    }

    static func database(in entries: [RemoteEntry], home: String) -> Database? {
        var best: (version: Int, entry: RemoteEntry)?
        for entry in entries where !entry.isDirectory && entry.name.hasPrefix("state_") && entry.name.hasSuffix(".sqlite") {
            let digits = entry.name.dropFirst("state_".count).dropLast(".sqlite".count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let version = Int(digits) else { continue }
            if version > (best?.version ?? -1) { best = (version, entry) }
        }
        guard let best else { return nil }
        let wal = entries.first { $0.name == best.entry.name + "-wal" }
        func state(_ entry: RemoteEntry?) -> SQLiteFileState? {
            entry.map { SQLiteFileState(size: $0.size ?? 0, modifiedAt: $0.modifiedAt) }
        }
        return Database(path: home + "/" + best.entry.name, fingerprint: [state(best.entry), state(wal)])
    }

    /// 只读打开的 URI：路径里 URI 有特殊含义的字符（`%`、`?`、`#`）百分号编码。
    static func uri(for path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file:" + encoded + "?mode=ro"
    }

    // MARK: 查询

    /// 一行：`R` 之后 9 列，制表符分隔；值里的 `\`、制表符、换行在库里转义（`\\`、`\t`、`\n`、`\r`），这里再还原。
    /// 来源是 JSON 的（子代理、审查）只回 `{thread_spawn` / `{subagent`，派它的线程 ID 从 JSON 里截出来（UUID 定长）。
    static func query(updatedSince: Int64?, limit: Int, offset: Int) -> String {
        func escaped(_ column: String) -> String {
            "replace(replace(replace(replace(coalesce(\(column), ''), '\\', '\\\\'), char(9), '\\t'), char(10), '\\n'), char(13), '\\r')"
        }
        let updated = "coalesce(updated_at_ms, updated_at * 1000)"
        let source = "CASE WHEN source LIKE '{%' THEN CASE WHEN instr(source, '\"thread_spawn\"') > 0 THEN '{thread_spawn' "
            + "ELSE '{subagent' END ELSE source END"
        let parent = "CASE WHEN instr(source, '\"parent_thread_id\":\"') > 0 "
            + "THEN substr(source, instr(source, '\"parent_thread_id\":\"') + 20, 36) ELSE '' END"
        let columns = ["'R'", escaped("id"), escaped("rollout_path"), escaped("cwd"), escaped(source), escaped("originator"),
                       escaped("thread_source"), escaped("agent_path"), escaped(parent), updated]
        let filter = updatedSince.map { " WHERE \(updated) >= \($0)" } ?? ""
        // 第一页先报一共多少行（`C`），后面几页就知道还要查几条命令。
        let count = offset == 0 ? "SELECT 'C', count(*) FROM threads" + filter + "; " : ""
        return count + "SELECT " + columns.joined(separator: ", ") + " FROM threads" + filter
            + " ORDER BY \(updated) DESC, id LIMIT \(max(1, limit)) OFFSET \(max(0, offset));"
    }

    /// 第一页报的一共多少行；没有为 nil。
    static func total(in output: String) -> Int? {
        output.split(whereSeparator: \.isNewline).lazy.compactMap { line -> Int? in
            line.hasPrefix("C\t") ? Int(line.dropFirst(2)) : nil
        }.first
    }

    /// 在主机上查：`$1` 库的 URI，`$2` SQL。输出夹在开始 / 结束标记之间，结束标记带 `sqlite3` 的退出码（没有它是 127）。
    static let script = #"""
        exec 2>/dev/null
        echo uterm-codex-index:begin
        command -v sqlite3 >/dev/null 2>&1 || { echo "uterm-codex-index:end 127"; exit 0; }
        sqlite3 -batch -noheader -cmd '.timeout 3000' -separator '	' "$1" "$2"
        echo "uterm-codex-index:end $?"
        exit 0
        """#

    /// 整条命令（脚本与参数都经 `RemotePath.shScript`：登录 shell 是 csh / fish 也照样跑）。
    static func command(database: String, sql: String) -> String {
        RemotePath.shScript("sh -c \(argument: 0) sh \(argument: 1) \(argument: 2)",
                            arguments: [script, uri(for: database), sql], escapedNames: false)
    }

    // MARK: 输出

    nonisolated struct Row: Equatable, Sendable {
        let header: CodexSessionHeader
        let rolloutPath: String
        let updatedAtMs: Int64
    }

    nonisolated enum Outcome: Equatable, Sendable {
        case rows([Row])
        /// 主机上没有 `sqlite3`。
        case missingTool
        /// 查不了（库坏了、表结构不认识）：退回原来的读法。
        case failed(Int)
    }

    nonisolated enum OutputError: Error, Equatable {
        /// 没有开始标记：命令根本没跑起来（只许 SFTP 的主机）。
        case notExecuted
        /// 没有结束标记：输出被截了（超了 `exec` 的上限）。
        case incomplete
    }

    static func parse(_ output: String) throws -> Outcome {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        guard let begin = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == beginMarker }) else {
            throw OutputError.notExecuted
        }
        guard let end = lines[(begin + 1)...].firstIndex(where: { $0.hasPrefix(endMarker + " ") }) else {
            throw OutputError.incomplete
        }
        let status = Int(lines[end].dropFirst(endMarker.count + 1).trimmingCharacters(in: .whitespaces)) ?? -1
        if status == missingStatus { return .missingTool }
        guard status == 0 else { return .failed(status) }
        return .rows(lines[(begin + 1)..<end].compactMap(row))
    }

    static func row(_ line: Substring) -> Row? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { unescape(String($0)) }
        guard fields.count == 10, fields[0] == "R", !fields[1].isEmpty, !fields[2].isEmpty,
              let updated = Int64(fields[9]) else { return nil }
        func value(_ index: Int) -> String? { fields[index].isEmpty ? nil : fields[index] }
        let source: CodexSessionHeader.Source
        switch fields[4] {
        case "": source = .unknown
        case "{thread_spawn": source = .threadSpawn
        case "{subagent": source = .otherSubagent
        default: source = .named(fields[4])
        }
        let header = CodexSessionHeader(id: fields[1], cwd: value(3), originator: value(5), source: source,
                                        threadSource: value(6), parentThreadID: value(8), agentPath: value(7),
                                        forkedFromID: nil)
        return Row(header: header, rolloutPath: fields[2], updatedAtMs: updated)
    }

    private static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var out = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                default: out.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// 一条命令查多少行：一行一般 200–300 字节，按 `exec` 能带回的输出留足余量（SSH 64 000 字节 → 125 行一条）。
    static func pageSize(outputLimit: Int) -> Int {
        max(25, min(5000, outputLimit / 512))
    }
}
