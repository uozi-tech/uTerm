import Foundation

/// 一份 Codex 记录的第一行（`session_meta`）里列表要用的那几个字段。
///
/// 第一行有 12–50 KB（大头是 `base_instructions`，整段系统提示词），而要用的字段都在它前面：实测本机 2090 份记录，
/// `base_instructions` 最晚从第 1110 字节开始，`id` / `cwd` / `originator` / `source` / `thread_source` /
/// `parent_thread_id` 全在它之前。所以只读、只传开头一小段，不完整解析（`ClaudeJSONLScan` 捞字段，块尾截断的值跳过）。
nonisolated struct CodexSessionHeader: Equatable, Sendable {
    /// 线程 ID（`codex resume <ID>` 认的那个）。
    var id: String
    var cwd: String?
    /// 哪个程序写的：`codex_cli_rs`（老的命令行界面）、`codex-tui`（新的命令行界面）、`codex_exec`（`codex exec`）、
    /// `codex_vscode`（VS Code 插件）、`Codex Desktop`（桌面版）……
    var originator: String?
    var source: Source
    /// `user` / `subagent` / `guardian_review` / `code_review` / `memory_consolidation` / 别的；老版本没有。
    var threadSource: String?
    /// 是谁派出来的（子代理、审查之类）。
    var parentThreadID: String?
    /// 派子代理时给的路径（`/root/<任务名>` 之类），最后一段就是派它时 `spawn_agent` 的 `task_name`。
    var agentPath: String?
    var forkedFromID: String?

    nonisolated enum Source: Equatable, Sendable {
        /// `cli` / `vscode` / `exec` / `mcp` / 自定义的名字。
        case named(String)
        /// `{"subagent": {"thread_spawn": {…}}}`：`spawn_agent` 派出来的子代理。
        case threadSpawn
        /// `{"subagent": …}` 的别的种类（`review`、`compact`、`{"other": "guardian"}` 之类）。
        case otherSubagent
        /// 读到的那段里没有（老版本、被截断）。
        case unknown
    }

    /// 只认这一段：`base_instructions` 及以后的不看（那里面是提示词原文，可能恰好写着像键的字）。
    static let maxPrefixBytes = 4096

    /// 第一行的开头一段 → 字段。不是 `session_meta` 行（或者连 ID 都没有）为 nil。
    static func parse(prefix data: Data) -> CodexSessionHeader? {
        var head = data.prefix(maxPrefixBytes)
        if let newline = head.firstIndex(of: 0x0A) { head = head[head.startIndex..<newline] }
        if let cut = head.range(of: Data("\"base_instructions\"".utf8)) { head = head[head.startIndex..<cut.lowerBound] }
        let bytes = Data(head)
        guard ClaudeJSONLScan.contains("\"type\":\"session_meta\"", in: bytes) else { return nil }
        func first(_ key: String) -> String? {
            ClaudeJSONLScan.stringValues(forKey: key, in: bytes).first.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let id = first("id") else { return nil }
        let source: Source
        if let named = first("source") {
            source = .named(named)
        } else if ClaudeJSONLScan.contains("\"source\":{", in: bytes) {
            source = ClaudeJSONLScan.contains("\"thread_spawn\":", in: bytes) ? .threadSpawn : .otherSubagent
        } else {
            source = .unknown
        }
        return CodexSessionHeader(id: id, cwd: first("cwd"), originator: first("originator"), source: source,
                                  threadSource: first("thread_source"), parentThreadID: first("parent_thread_id"),
                                  agentPath: first("agent_path"), forkedFromID: first("forked_from_id"))
    }

    /// 命令行里起的界面写的 `originator`：老的 `codex_cli_rs`，0.1xx 后期起改走 app-server 的 `codex-tui`。
    /// `codex exec`（`codex_exec`）是程序调用的，同 Claude 的 `claude -p` 不列。
    static let cliOriginators: Set<String> = ["codex_cli_rs", "codex-tui"]

    /// 是一个人开的顶层会话（不是派出来的子代理、审查、记忆整理）。
    var isTopLevel: Bool {
        if parentThreadID != nil { return false }
        switch source {
        case .threadSpawn, .otherSubagent: return false
        case .named, .unknown: break
        }
        return threadSource == nil || threadSource == "user"
    }

    /// 命令行起的：只列这些（同 Claude 的规矩）。`originator` 没写的老版本看 `source == "cli"`。
    var isFromCommandLine: Bool {
        guard isTopLevel else { return false }
        if let originator { return Self.cliOriginators.contains(originator) }
        return source == .named("cli")
    }

    /// 子代理对外的 ID：派它的调用结果里报的是 `task_name`（`{"task_name": "…"}`），和这里路径的最后一段对得上；
    /// 没有路径的（老版本）用线程 ID。
    var agentID: String {
        if let agentPath, let last = agentPath.split(separator: "/").last, !last.isEmpty { return String(last) }
        return id
    }
}

/// `~/.codex/session_index.jsonl`：会话名（Codex 自己起的，或者你改过的）。只追加，同一个 ID 以最后一条为准。
nonisolated enum CodexSessionIndex {
    /// 只读末尾这么多（实测本机 427 条、几十 KB）。更早的名字被截掉了也只是那几行退回用第一句话当标题。
    static let maxBytes = 2 * 1024 * 1024

    static func names(from data: Data, dropsLeadingPartial: Bool) -> [String: String] {
        var names: [String: String] = [:]
        for line in ClaudeJSONLScan.lines(in: data, dropsLeadingPartial: dropsLeadingPartial, dropsTrailingPartial: false) {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = object["id"] as? String, let name = object["thread_name"] as? String else { continue }
            let title = ClaudeSessionScan.singleLine(name)
            if title.isEmpty { names[id] = nil } else { names[id] = title }
        }
        return names
    }
}
