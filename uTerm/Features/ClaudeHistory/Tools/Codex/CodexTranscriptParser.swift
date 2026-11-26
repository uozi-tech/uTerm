import Foundation

/// Codex CLI 记录（`rollout-*.jsonl`，一行一条）里的一行 → 要显示的条目。
///
/// 每行 `{"timestamp":…,"ordinal":…,"type":…,"payload":{…}}`。没有公开规格，按 codex-cli 0.126–0.169 的实际文件
/// 和上游源码（`codex-rs/protocol`）写的。同一件事记录里常常写两遍：给模型的 `response_item`，和给界面的 `event_msg`
/// （`item_completed`、老版本的 `user_message` / `agent_message` / `agent_reasoning`）。这里只认 `response_item`
/// （它从最早的版本起就有，是 `codex resume` 接着往下聊的依据），`event_msg` 一律不显示，免得一句话出现两次。
///
/// 显示的：
/// - `message`：`user` 的 `input_text`（去掉系统注入的块）、`input_image`（占位）；`assistant` 的 `output_text`。
///   `developer`（系统提示、权限说明）不显示。
/// - `reasoning`：只有摘要（`summary[].text`）是明文，正文是加密的，不显示。
/// - `function_call` / `custom_tool_call` / `local_shell_call` / `web_search_call`：工具调用；
///   `function_call_output` / `custom_tool_call_output`：结果，按 `call_id` 挂到调用下面。
/// - `agent_message`：别的代理发来的消息，只留一句。
/// - 顶层 `compacted`：上下文压缩后的摘要。
///
/// 别的（`session_meta`、`turn_context`、`token_usage_record`、`world_state`、加密的 `compaction`……）以及不认识的跳过。
nonisolated enum CodexTranscriptParser {
    /// 看行首判断类型。顶层的 `type` 在前一百字节里，`payload` 的 `type` / `role` 紧跟在后面。
    static let headBytes = 512

    /// 看行首判断值不值得解析。
    static func isMessageCandidate(head: Data) -> Bool {
        let head = head.prefix(headBytes)
        if ClaudeJSONLScan.contains("\"type\":\"compacted\"", in: head) { return true }
        if isTokenCount(head: head) { return true }
        guard ClaudeJSONLScan.contains("\"type\":\"response_item\"", in: head) else { return false }
        return !ClaudeJSONLScan.contains("\"role\":\"developer\"", in: head)
            && !Self.skippedPayloadTypes.contains { ClaudeJSONLScan.contains("\"payload\":{\"type\":\"\($0)\"", in: head) }
    }

    /// 用量（`event_msg` 里的 `token_count`）：不显示成一行，标题块取最后一条。
    static func isTokenCount(head: Data) -> Bool {
        ClaudeJSONLScan.contains("\"type\":\"event_msg\"", in: head)
            && ClaudeJSONLScan.contains("\"payload\":{\"type\":\"token_count\"", in: head)
    }

    /// 不显示的 `payload.type`（`payload` 的第一个键就是 `type`）：加密的压缩记录、工具清单、配置变更、快照。
    private static let skippedPayloadTypes = ["compaction", "additional_tools", "configuration_update", "ghost_snapshot"]

    /// 一行 → 条目。`minimumOrdinal`：比它小的行不显示（子代理记录开头抄进来的父会话上下文，`subagent_history_start_ordinal`）。
    static func items(from line: ClaudeReverseLineScanner.Line, minimumOrdinal: Int? = nil) -> [AgentTranscriptItem] {
        let idPrefix = String(line.offset)
        guard isMessageCandidate(head: line.bytes) else { return [] }
        if line.isTruncated {
            // 用量那一行没有大的：截断了就不要，不占一行「太大」。
            if isTokenCount(head: line.bytes) { return [] }
            if let minimumOrdinal, let ordinal = ordinal(inHead: line.bytes), ordinal < minimumOrdinal { return [] }
            return [AgentTranscriptItem(id: idPrefix + ".0", kind: .oversized(bytes: line.length))]
        }
        return items(fromJSON: line.bytes, idPrefix: idPrefix, minimumOrdinal: minimumOrdinal)
    }

    /// 解析一整行。坏行、不认识的结构返回空，不抛错。
    static func items(fromJSON data: Data, idPrefix: String, minimumOrdinal: Int? = nil) -> [AgentTranscriptItem] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return [] }
        if let minimumOrdinal, let ordinal = object["ordinal"] as? Int, ordinal < minimumOrdinal { return [] }
        let timestamp = (object["timestamp"] as? String).flatMap(ClaudeTimestamp.parse)
        let kinds: [AgentTranscriptItem.Kind]
        switch type {
        case "response_item": kinds = responseItem(payload)
        case "compacted": kinds = compacted(payload)
        case "event_msg": kinds = usage(of: payload).map { [.usage($0)] } ?? []
        default: kinds = []
        }
        return kinds.enumerated().map { index, kind in
            AgentTranscriptItem(id: "\(idPrefix).\(index)", kind: kind, timestamp: timestamp)
        }
    }

    /// `token_count`：`info.last_token_usage` 是这一次的（`input_tokens` 已含缓存）；窗口大小与账号额度记录里都有。
    static func usage(of payload: [String: Any]) -> AgentTurnUsage? {
        guard payload["type"] as? String == "token_count" else { return nil }
        let info = payload["info"] as? [String: Any]
        let last = info?["last_token_usage"] as? [String: Any]
        func count(_ object: [String: Any]?, _ key: String) -> Int { (object?[key] as? NSNumber)?.intValue ?? 0 }
        let rateLimits = rateLimits(payload["rate_limits"] as? [String: Any])
        let context = count(last, "input_tokens")
        // 只有额度、还没有用量的那种（会话刚开）也留着：额度照样有用。
        guard context > 0 || rateLimits != nil else { return nil }
        let window = (info?["model_context_window"] as? NSNumber)?.intValue
        return AgentTurnUsage(model: nil, contextTokens: context, outputTokens: count(last, "output_tokens"),
                              contextWindow: window.flatMap { $0 > 0 ? $0 : nil }, rateLimits: rateLimits)
    }

    /// `rate_limits`：`primary` / `secondary` 各一个时间窗（用了几成、窗多长、几时重置），`plan_type` 是套餐。
    static func rateLimits(_ object: [String: Any]?) -> AgentRateLimits? {
        guard let object else { return nil }
        func window(_ key: String) -> AgentRateLimits.Window? {
            guard let window = object[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return AgentRateLimits.Window(usedPercent: used, windowMinutes: (window["window_minutes"] as? NSNumber)?.intValue,
                                          resetsAt: resets)
        }
        // `limit_name`：只管某几个模型的额度才有名字（管全部的是 nil）。
        let scope = (object["limit_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var primary = window("primary"), secondary = window("secondary")
        primary?.scope = scope
        secondary?.scope = scope
        let limits = AgentRateLimits(primary: primary, secondary: secondary, plan: object["plan_type"] as? String)
        return limits.windows.isEmpty ? nil : limits
    }

    /// 截断的大行只有开头：从里面读 `ordinal`。
    private static func ordinal(inHead head: Data) -> Int? {
        guard let range = head.range(of: Data("\"ordinal\":".utf8)) else { return nil }
        let digits = head[range.upperBound...].prefix { (0x30...0x39).contains($0) }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    // MARK: - response_item

    private static func responseItem(_ payload: [String: Any]) -> [AgentTranscriptItem.Kind] {
        switch payload["type"] as? String {
        case "message":
            return message(payload)
        case "reasoning":
            let summary = (payload["summary"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["text"] as? String }
                .joined(separator: "\n\n")
            guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [.thinking(AgentClippedText(summary, limit: AgentTranscriptLimits.thinkingCharacters))]
        case "function_call":
            let name = payload["name"] as? String ?? "?"
            let arguments = payload["arguments"] as? String ?? ""
            let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
            var call = AgentToolCall(toolUseID: payload["call_id"] as? String, name: name,
                                     summary: CodexToolSummary.summary(name: name, arguments: input, raw: arguments),
                                     result: nil)
            if CodexToolSummary.spawnToolNames.contains(name) {
                call.spawn = AgentSpawnRequest(description: nonEmpty(input?["task_name"]) ?? nonEmpty(input?["message"]),
                                               agentType: nonEmpty(input?["agent_type"]) ?? nonEmpty(input?["role"]))
            }
            return [.toolCall(call)]
        case "custom_tool_call":
            let name = payload["name"] as? String ?? "?"
            return [.toolCall(AgentToolCall(toolUseID: payload["call_id"] as? String, name: name,
                                            summary: CodexToolSummary.freeformSummary(name: name, input: payload["input"] as? String ?? ""),
                                            result: nil))]
        case "local_shell_call":
            let action = payload["action"] as? [String: Any]
            let command = CodexToolSummary.commandLine(action?["command"])
            return [.toolCall(AgentToolCall(toolUseID: (payload["call_id"] as? String) ?? (payload["id"] as? String),
                                            name: "shell", summary: command ?? "", result: nil))]
        case "web_search_call":
            let action = payload["action"] as? [String: Any]
            let summary = nonEmpty(action?["query"]) ?? nonEmpty(action?["url"]) ?? nonEmpty(action?["pattern"]) ?? ""
            return [.toolCall(AgentToolCall(toolUseID: nil, name: "web_search", summary: summary, result: nil))]
        case "function_call_output", "custom_tool_call_output":
            return [.toolResult(toolResult(payload))]
        case "agent_message":
            let text = (payload["content"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["text"] as? String }
                .joined(separator: " ")
            let line = ClaudeSessionScan.singleLine(text, limit: 300)
            return line.isEmpty ? [] : [.notice(line)]
        default:
            return []
        }
    }

    private static func message(_ payload: [String: Any]) -> [AgentTranscriptItem.Kind] {
        let blocks = (payload["content"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        switch payload["role"] as? String {
        case "user":
            var kinds: [AgentTranscriptItem.Kind] = []
            for block in blocks {
                switch block["type"] as? String {
                case "input_text":
                    kinds.append(contentsOf: CodexUserText.kinds(from: block["text"] as? String ?? ""))
                case "input_image":
                    kinds.append(.image)
                default:
                    continue
                }
            }
            return kinds
        case "assistant":
            return blocks.compactMap { block in
                guard block["type"] as? String == "output_text", let text = block["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .assistantText(clip(text, AgentTranscriptLimits.textCharacters))
            }
        default:
            return []
        }
    }

    /// 结果是字符串，或 `input_text` / `input_image` 块的数组。老版本的 shell 结果是一段 JSON：
    /// `{"output": "…", "metadata": {"exit_code": 1, …}}`，退出码不是 0 算出错。
    private static func toolResult(_ payload: [String: Any]) -> AgentToolResult {
        var images = 0
        var text = ""
        var isError = false
        var spawnedAgentID: String?
        if let string = payload["output"] as? String {
            text = string
            if string.hasPrefix("{"),
               let object = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any] {
                if let output = object["output"] as? String {
                    text = output
                    if let code = (object["metadata"] as? [String: Any])?["exit_code"] as? Int { isError = code != 0 }
                }
                spawnedAgentID = spawnedID(in: object)
            }
        } else if let parts = payload["output"] as? [Any] {
            var pieces: [String] = []
            for case let part as [String: Any] in parts {
                switch part["type"] as? String {
                case "input_text", "output_text", "text": pieces.append(part["text"] as? String ?? "")
                case "input_image": images += 1
                default: continue
                }
            }
            text = pieces.joined(separator: "\n")
            if pieces.count == 1, text.hasPrefix("{"),
               let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                spawnedAgentID = spawnedID(in: object)
            }
        }
        if payload["success"] as? Bool == false { isError = true }
        var result = AgentToolResult(toolUseID: payload["call_id"] as? String,
                                     content: AgentClippedText(ClaudeUserText.stripTerminalEscapes(text),
                                                               limit: AgentTranscriptLimits.toolResultCharacters),
                                     isError: isError, imageCount: images)
        result.spawnedAgentID = spawnedAgentID
        return result
    }

    /// `spawn_agent` 的结果：现在是 `{"task_name": "…"}`；老一些的多代理版本报的是 `agent_id` / `thread_id`。
    /// 别的工具的结果里恰好有这几个键也无妨：只有派子代理的调用会拿它去对记录。
    private static func spawnedID(in object: [String: Any]) -> String? {
        for key in ["task_name", "agent_id", "thread_id"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - compacted

    private static func compacted(_ payload: [String: Any]) -> [AgentTranscriptItem.Kind] {
        let text = payload["message"] as? String ?? ""
        return [.compactSummary(AgentClippedText(text, limit: AgentTranscriptLimits.compactSummaryCharacters))]
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = ClaudeSessionScan.singleLine(string, limit: AgentTranscriptLimits.summaryCharacters)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let clipped = AgentClippedText(text, limit: limit)
        return clipped.isClipped ? clipped.text + "\n\n…" : clipped.text
    }
}

/// 工具调用参数的一行摘要。
nonisolated enum CodexToolSummary {
    /// 派子代理的工具：`spawn_agent`（多代理，`collaboration` 命名空间）。
    static let spawnToolNames: Set<String> = ["spawn_agent"]

    /// 常见工具各自最能说明意思的那个参数。
    private static let preferredKeys: [String: [String]] = [
        "shell": ["command"], "exec_command": ["cmd", "command"], "container.exec": ["command"],
        "write_stdin": ["chars"], "apply_patch": ["input", "patch"],
        "spawn_agent": ["task_name", "message"], "send_message": ["message"], "followup_task": ["message"],
        "view_image": ["path"], "read_file": ["path", "file_path"], "list_dir": ["path"],
    ]
    private static let fallbackKeys = ["cmd", "command", "file_path", "path", "pattern", "query", "url", "message",
                                       "description", "prompt", "title", "name", "target"]

    static func summary(name: String, arguments: [String: Any]?, raw: String) -> String {
        guard let arguments else { return ClaudeSessionScan.singleLine(raw, limit: AgentTranscriptLimits.summaryCharacters) }
        let keys = (preferredKeys[name] ?? []) + fallbackKeys
        for key in keys {
            if let line = commandLine(arguments[key]) { return line }
        }
        guard !arguments.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return ClaudeSessionScan.singleLine(json, limit: AgentTranscriptLimits.summaryCharacters)
    }

    /// 字符串原样（压成一行）；字符串数组（`["bash", "-lc", "ls"]`）用空格接起来，`bash -lc` 这层壳去掉。
    static func commandLine(_ value: Any?) -> String? {
        var text: String?
        if let string = value as? String {
            text = string
        } else if let parts = value as? [String] {
            let shells: Set<String> = ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"]
            if parts.count == 3, shells.contains(parts[0]), parts[1] == "-lc" || parts[1] == "-c" {
                text = parts[2]
            } else {
                text = parts.joined(separator: " ")
            }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ClaudeSessionScan.singleLine(text, limit: AgentTranscriptLimits.summaryCharacters)
    }

    /// 自由格式的工具（`custom_tool_call`）：参数是一整段文字。`apply_patch` 取改了哪些文件；别的取第一行不空的。
    static func freeformSummary(name: String, input: String) -> String {
        let lines = input.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if name == "apply_patch" {
            let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
            let files = lines.compactMap { line in
                markers.first(where: { line.hasPrefix($0) }).map { String(line.dropFirst($0.count)) }
            }
            if !files.isEmpty {
                return ClaudeSessionScan.singleLine(files.joined(separator: ", "), limit: AgentTranscriptLimits.summaryCharacters)
            }
        }
        let first = lines.first { !$0.isEmpty } ?? ""
        return ClaudeSessionScan.singleLine(first, limit: AgentTranscriptLimits.summaryCharacters)
    }
}

/// 用户那一侧的文字：Codex 把环境说明、AGENTS.md、技能说明这些注入的内容也写成 `user` 的 `input_text`，
/// 而且是**一块一个**——整块是一个 `<标签>…</标签>`，或者以 `# AGENTS.md instructions for` 开头。这些不显示；
/// 少数几种（回合被中断、子代理的通知）是给人看也有意义的提示，只留一句。
nonisolated enum CodexUserText {
    /// 整块折成一句提示的标签。
    static let noticeTags: Set<String> = ["turn_aborted", "subagent_notification"]

    static func kinds(from raw: String) -> [AgentTranscriptItem.Kind] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if text.hasPrefix("# AGENTS.md instructions for ") || text.hasPrefix("<user_instructions>") { return [] }
        // `<image name=[Image #1]>` / `</image>`：图片前后的标记，图片本身另有 `input_image`。
        if isImageMarker(text) { return [] }
        if let tag = wrappingTag(of: text) {
            guard noticeTags.contains(tag) else { return [] }
            let inner = ClaudeUserText.removing(tag: tag, from: text).inner.first ?? ""
            let line = ClaudeSessionScan.singleLine(stripTags(inner), limit: 300)
            return line.isEmpty ? [] : [.notice(line)]
        }
        return [.userText(CodexTranscriptParser.clip(text, AgentTranscriptLimits.textCharacters))]
    }

    /// 整块是不是一个 `<tag>…</tag>`（标签名只有小写字母、数字、下划线、横线）。是就返回标签名。
    static func wrappingTag(of text: String) -> String? {
        guard text.hasPrefix("<"), let close = text.firstIndex(of: ">") else { return nil }
        let name = text[text.index(after: text.startIndex)..<close]
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" })
        else { return nil }
        return text.hasSuffix("</\(name)>") ? String(name) : nil
    }

    private static func isImageMarker(_ text: String) -> Bool {
        text == "</image>" || (text.hasPrefix("<image") && text.hasSuffix(">") && !text.contains("\n") && text.count <= 200)
    }

    /// 提示里还有一层小标签（`<turn_aborted>` 里的说明之类）：只要文字。
    private static func stripTags(_ text: String) -> String {
        var output = ""
        var inTag = false
        for character in text {
            if character == "<" { inTag = true; continue }
            if character == ">", inTag { inTag = false; output.append(" "); continue }
            if !inTag { output.append(character) }
        }
        return output
    }
}
