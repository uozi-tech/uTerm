import Foundation

/// 主机上正在运行的 Claude Code：每个进程有一份 `~/.claude/sessions/<pid>.json`（同目录的 `<pid>.<hash>.key` 不管）。
/// 实测字段：`pid`、`sessionId`、`cwd`、`startedAt`、`procStart`、`version`、`kind`（interactive / bg）、`entrypoint`、
/// `name`、`status`（见过 busy / idle / shell）、`updatedAt`、`statusUpdatedAt`。
///
/// 进程退出后文件可能还留着，所以在主机上一条命令把「进程还活着的」那几份原样吐回来，App 里解析（主机上不要 jq）：
/// `kill -0` 看进程在不在；再用 `ps -o lstart=` 取它的启动时间，和文件里的 `procStart` 比，防重启之后进程号被别的进程用上。
/// 命令的形状同搜索（`ClaudeSearchCommand.command`）：整段编码后交给 `sh`，登录 shell 是 csh / tcsh / fish 也照样跑。只读。
nonisolated enum ClaudeLiveSessions {
    static let beginMarker = "uterm-claude-live:begin"
    static let pidMarker = "uterm-claude-live:pid"
    static let endMarker = "uterm-claude-live:end"
    /// 目录进不去（没有这个目录 = 没有在跑的）。
    static let noDirectoryStatus = 200
    static func directory(home: String) -> String {
        (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/.claude/sessions"
    }

    /// `$2` 是 sessions 目录。回：每个活着的进程一行 `uterm-claude-live:pid <pid> <ps 报的启动时间>`，接着是那份文件。
    /// 启动时间用 UTC（`procStart` 是 UTC）；`ps` 不认 `-o lstart`（busybox）时为空，只靠 `kill -0`。
    /// 一份最多读 4 KB（实测五六百到八百多字节；SSH 的 exec 总输出有约 64 000 字节的上限）。
    static let script = #"""
        exec 2>/dev/null
        echo uterm-claude-live:begin
        cd "$(printf %b "$2")" || { echo "uterm-claude-live:end 200"; exit 0; }
        for f in *.json; do
          p=${f%.json}
          case $p in ''|*[!0-9]*) continue;; esac
          [ -f "$f" ] || continue
          kill -0 "$p" || continue
          s=$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$p")
          echo "uterm-claude-live:pid $p $s"
          head -c 4096 "$f"
          echo
        done
        echo "uterm-claude-live:end 0"
        exit 0
        """#

    static func command(sessionsDirectory: String) -> String {
        ClaudeSearchCommand.command(script: script, arguments: [sessionsDirectory])
    }

    enum ReadError: Error, Equatable {
        /// 没有开始标记：命令根本没跑起来（主机只许 SFTP、没有 `sh`）。
        case cannotExecute
        /// 没有结束标记：输出不完整。
        case incompleteOutput
    }

    /// 命令的输出 → 活着的会话（按 `AgentLiveSession.ordered` 排好）。坏的、启动时间对不上的那几份跳过。
    static func parse(_ output: String) throws -> [AgentLiveSession] {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        guard let begin = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == beginMarker }) else {
            throw ReadError.cannotExecute
        }
        let body = lines[(begin + 1)...]
        guard let end = body.firstIndex(where: { $0.hasPrefix(endMarker + " ") }) else { throw ReadError.incompleteOutput }
        if Int(lines[end].dropFirst(endMarker.count + 1).trimmingCharacters(in: .whitespaces)) == noDirectoryStatus {
            return []
        }
        var found: [AgentLiveSession.Key: AgentLiveSession] = [:]
        var header: Substring?
        var content: [Substring] = []
        func flush() {
            defer { content = [] }
            guard let header, let session = session(header: header, json: content.joined(separator: "\n")) else { return }
            if let known = found[session.key],
               CodeRunStatus.merging(known.runStatus, host: session.runStatus) == known.runStatus { return }
            found[session.key] = session
        }
        for line in lines[(begin + 1)..<end] {
            if line.hasPrefix(pidMarker + " ") {
                flush()
                header = line.dropFirst(pidMarker.count + 1)
            } else if header != nil {
                content.append(line)
            }
        }
        flush()
        return AgentLiveSession.ordered(Array(found.values))
    }

    /// 一份：`header` 是标记行后面的「<pid> <启动时间>」。
    static func session(header: Substring, json: String) -> AgentLiveSession? {
        let parts = header.split(separator: " ", maxSplits: 1)
        guard let first = parts.first, let pid = Int(first),
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let sessionID = (object["sessionId"] as? String)?.trimmingCharacters(in: .whitespaces), !sessionID.isEmpty
        else { return nil }
        // 文件名的进程号和里面写的不一样：不是它自己的那份。
        if let recorded = object["pid"] as? Int, recorded != pid { return nil }
        if parts.count == 2, let recorded = object["procStart"] as? String,
           isSameProcess(observed: String(parts[1]), recorded: recorded) == false {
            return nil
        }
        let directory = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AgentLiveSession(tool: .claude, sessionID: sessionID, pid: pid, directory: directory,
                                state: state(of: object["status"] as? String))
    }

    /// `status` → 状态。实测见过 busy / idle / shell；别的值没见过：字样像在等人的（wait / permission / input）当等人处理，
    /// 其余当没报。
    static func state(of status: String?) -> AgentLiveSession.State {
        guard let status = status?.lowercased() else { return .unknown }
        switch status {
        case "busy": return .working
        case "idle": return .idle
        default:
            return ["wait", "permission", "input"].contains(where: status.contains) ? .waiting : .unknown
        }
    }

    /// `ps` 报的启动时间与文件里的 `procStart` 是不是同一个进程：都读得出时间时，相差两秒以内算同一个；
    /// 正好差整刻钟的倍数（两边时区写法不同）也算。读不出（`ps` 不支持、格式不认识）为 nil：只靠 `kill -0`。
    static func isSameProcess(observed: String, recorded: String) -> Bool? {
        guard let a = startDate(observed), let b = startDate(recorded) else { return nil }
        let difference = abs(a.timeIntervalSince(b))
        if difference <= 2 { return true }
        let quarter = 15.0 * 60
        let remainder = difference.truncatingRemainder(dividingBy: quarter)
        return min(remainder, quarter - remainder) <= 2
    }

    /// `Thu Nov  6 13:07:37 2026` 这种（`ps -o lstart` 与 `procStart` 的写法），按 UTC。
    static func startDate(_ text: String) -> Date? {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: normalized)
    }
}
