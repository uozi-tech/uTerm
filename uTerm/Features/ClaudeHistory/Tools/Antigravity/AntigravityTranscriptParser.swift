import Foundation

/// Antigravity 的记录（`brain/<会话 ID>/.system_generated/logs/transcript_full.jsonl`，一行一步）里的一行 → 要显示的条目。
///
/// 没有公开规格，按 2026-11 的桌面版写的。每行是紧凑 JSON，键的先后固定：`step_index`、`source`、`type`、`status`、
/// （`error`）、`created_at`，后面是各类型自己的字段。要显示的类型：
/// - `USER_INPUT`：`content` 里 `<USER_REQUEST>` 才是你说的话；`<ADDITIONAL_METADATA>`（本地时间、打开的文件）是系统附上的，
///   不显示；`<USER_SETTINGS_CHANGE>`（换了模型之类）折成一句通知。
/// - `PLANNER_RESPONSE`：模型的一步，`thinking`、`content`（回答）、`tool_calls`（`name` + `args`）。
/// - `GENERIC`：一次工具调用的结果。记录里没有调用 ID，结果按调用的先后各占一步：第 S 步的第 k 个调用，结果在第 S + 1 + k 步
///   （本机 2090 个调用实测 2089 个对上，没对上的那个是会话被打断、结果没写出来）。所以调用与结果的 ID 都用「结果那一步的编号」，
///   不看上下文就能对上，分页时两者落在不同页也一样（`AgentTranscriptAssembler.attachResults`）。
/// - `SYSTEM_MESSAGE`（后台任务结束等系统注入）、`ERROR_MESSAGE`（请求模型失败）只显示一句通知。
/// - `CHECKPOINT`：上下文压缩后的摘要。
///
/// `transcript.jsonl` 是同一份的删节版：长字段截到四千字左右（`truncated_fields` 记着截了哪些），`args` 的每个值都再编成了
/// JSON 字符串。只在没有 `transcript_full.jsonl` 时读它（`encodedArgs`）。
nonisolated enum AntigravityTranscriptParser {
    /// 判断类型看行首多少字节：`type` 在第三个键，前面只有步号和来源，一百字节以内。
    static let headBytes = 256

    /// 要显示的几种行。
    static let displayedTypes: Set<String> = [
        "USER_INPUT", "PLANNER_RESPONSE", "GENERIC", "SYSTEM_MESSAGE", "ERROR_MESSAGE", "CHECKPOINT",
    ]

    /// 行首写的是哪种类型；不像一行记录为 nil。
    static func type(ofHead head: Data) -> String? {
        let head = head.prefix(headBytes)
        guard let value = ClaudeJSONLScan.stringValues(forKey: "type", in: head).first else { return nil }
        return value
    }

    /// 一行 → 条目。`line` 是 `ClaudeReverseLineScanner` / `ClaudeForwardLineScanner` 切出来的。
    static func items(from line: ClaudeReverseLineScanner.Line, encodedArgs: Bool = false) -> [AgentTranscriptItem] {
        let idPrefix = String(line.offset)
        guard let type = type(ofHead: line.bytes), displayedTypes.contains(type) else { return [] }
        if line.isTruncated {
            return [AgentTranscriptItem(id: idPrefix + ".0", kind: .oversized(bytes: line.length))]
        }
        return items(fromJSON: line.bytes, idPrefix: idPrefix, encodedArgs: encodedArgs)
    }

    /// 解析一整行。坏行、不认识的类型返回空，不抛错。
    static func items(fromJSON data: Data, idPrefix: String, encodedArgs: Bool = false) -> [AgentTranscriptItem] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        let timestamp = (object["created_at"] as? String).flatMap(ClaudeTimestamp.parse)
        let step = object["step_index"] as? Int
        let content = object["content"] as? String ?? ""

        var kinds: [AgentTranscriptItem.Kind] = []
        switch type {
        case "USER_INPUT":
            kinds = userKinds(content)
            kinds.append(contentsOf: Array(repeating: .image, count: mediaCount(object)))
        case "PLANNER_RESPONSE":
            if let thinking = object["thinking"] as? String, !isBlank(thinking) {
                kinds.append(.thinking(AgentClippedText(thinking, limit: AgentTranscriptLimits.thinkingCharacters)))
            }
            if !isBlank(content) { kinds.append(.assistantText(clip(content, AgentTranscriptLimits.textCharacters))) }
            for case let (index, call as [String: Any]) in ((object["tool_calls"] as? [Any]) ?? []).enumerated() {
                let name = call["name"] as? String ?? "?"
                var args = call["args"] as? [String: Any] ?? [:]
                if encodedArgs { args = decodedArgs(args) }
                kinds.append(.toolCall(AgentToolCall(
                    toolUseID: step.map { resultID(step: $0 + 1 + index) }, name: name,
                    summary: AntigravityToolSummary.summary(name: name, args: args), result: nil)))
            }
            // 放在最后：前面几条的 ID（行内序号）不受影响。
            if let usage = usage(of: object) { kinds.append(.usage(usage)) }
        case "GENERIC":
            let status = object["status"] as? String
            let error = object["error"] as? String
            var text = stripResultHeader(content)
            if isBlank(text), let error { text = error }
            kinds.append(.toolResult(AgentToolResult(
                toolUseID: step.map(resultID(step:)),
                content: AgentClippedText(ClaudeUserText.stripTerminalEscapes(text), limit: AgentTranscriptLimits.toolResultCharacters),
                isError: status == "ERROR" || status == "INVALID",
                imageCount: mediaCount(object))))
        case "SYSTEM_MESSAGE":
            if let line = systemNotice(content) { kinds.append(.notice(line)) }
        case "ERROR_MESSAGE":
            let line = ClaudeSessionScan.singleLine((object["error"] as? String) ?? content, limit: 300)
            if !line.isEmpty { kinds.append(.notice(line)) }
        case "CHECKPOINT":
            if !isBlank(content) {
                kinds.append(.compactSummary(AgentClippedText(content, limit: AgentTranscriptLimits.compactSummaryCharacters)))
            }
        default:
            break
        }
        return kinds.enumerated().map { index, kind in
            AgentTranscriptItem(id: "\(idPrefix).\(index)", kind: kind, timestamp: timestamp)
        }
    }

    /// 模型这一步的用量：`input_tokens` + `cache_read_tokens` 是它看到的上下文（没有缓存写入这一项）。记录里没有窗口多大。
    static func usage(of object: [String: Any]) -> AgentTurnUsage? {
        func count(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        let context = count("input_tokens") + count("cache_read_tokens")
        guard context > 0 else { return nil }
        return AgentTurnUsage(model: object["model"] as? String, contextTokens: context, outputTokens: count("output_tokens"))
    }

    /// 调用和它的结果共用的 ID：结果那一步的步号。
    static func resultID(step: Int) -> String { "step-\(step)" }

    // MARK: 你说的话

    /// 系统附上、不显示的块。
    private static let hiddenUserTags = ["ADDITIONAL_METADATA"]

    static func userKinds(_ raw: String) -> [AgentTranscriptItem.Kind] {
        var text = raw
        for tag in hiddenUserTags { text = ClaudeUserText.removing(tag: tag, from: text).rest }
        var kinds: [AgentTranscriptItem.Kind] = []
        let settings = ClaudeUserText.removing(tag: "USER_SETTINGS_CHANGE", from: text)
        text = settings.rest
        let request = ClaudeUserText.removing(tag: "USER_REQUEST", from: text)
        // 没有 `<USER_REQUEST>` 的（老版本、别的入口）：去掉认得的块以后剩下的就是你说的话。
        let pieces = request.inner.isEmpty ? [request.rest] : request.inner
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { kinds.append(.userText(clip(trimmed, AgentTranscriptLimits.textCharacters))) }
        }
        for change in settings.inner {
            let line = firstSentence(change)
            if !line.isEmpty { kinds.append(.notice(line)) }
        }
        return kinds
    }

    /// 只要第一句（后面是写给模型的「不用提这件事」之类）。
    private static func firstSentence(_ text: String) -> String {
        let line = ClaudeSessionScan.singleLine(text, limit: 300)
        guard let end = line.range(of: ". ") else { return line }
        return String(line[..<end.lowerBound]) + "."
    }

    // MARK: 工具结果

    /// 结果开头是一两组 `Created At: …` / `Completed At: …`（这一步什么时候开始、结束），不是工具的输出。
    static func stripResultHeader(_ content: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let first = lines.first, first.hasPrefix("Created At: ") || first.hasPrefix("Completed At: ") {
            lines = lines.dropFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 系统消息

    /// `The following is a <SYSTEM_MESSAGE> not actually sent by the user…` + `<SYSTEM_MESSAGE>[Message] timestamp=… sender=…
    /// priority=… content=<正文></SYSTEM_MESSAGE>`：只留正文的一句。
    static func systemNotice(_ content: String) -> String? {
        // 前言里也提到了这个标签（不成对），取最后一个开标签之后的那段。
        var body = content
        if let open = content.range(of: "<SYSTEM_MESSAGE>", options: .backwards) {
            body = String(content[open.upperBound...])
            if let close = body.range(of: "</SYSTEM_MESSAGE>") { body = String(body[..<close.lowerBound]) }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("[Message]"), let marker = body.range(of: " content=") {
            body = String(body[marker.upperBound...])
        }
        let line = ClaudeSessionScan.singleLine(body, limit: 300)
        return line.isEmpty ? nil : line
    }

    // MARK: 小工具

    private static func mediaCount(_ object: [String: Any]) -> Int {
        (object["media"] as? [Any])?.count ?? 0
    }

    /// `transcript.jsonl` 的参数：每个值都是编过一次的 JSON（`"\"/a/b\""`、`"true"`、`"12"`），解回来。
    static func decodedArgs(_ args: [String: Any]) -> [String: Any] {
        args.mapValues { value in
            guard let string = value as? String, let data = string.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return value }
            return decoded
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let clipped = AgentClippedText(text, limit: limit)
        return clipped.isClipped ? clipped.text + "\n\n…" : clipped.text
    }
}

/// 工具调用参数的一行摘要。参数名是 Antigravity 自己的（大驼峰，`CommandLine`、`Path`……）。
nonisolated enum AntigravityToolSummary {
    /// 常见工具各自最能说明意思的那个参数。
    private static let preferredKeys: [String: [String]] = [
        "run_command": ["CommandLine"],
        "read_file": ["Path"], "edit_file": ["Path"], "write_file": ["Path"],
        "search_web": ["query"],
        "update_focus": ["focus"],
        "schedule": ["Prompt"],
        "manage_task": ["TaskId"],
    ]
    /// 不认识的工具按这个顺序找一个字符串参数（含别的版本里见过的写法）。
    private static let fallbackKeys = [
        "CommandLine", "Path", "AbsolutePath", "TargetFile", "File", "DirectoryPath", "SearchPath", "Query", "query",
        "Url", "url", "Prompt", "prompt", "focus", "TaskId", "toolSummary",
    ]

    static func summary(name: String, args: [String: Any]) -> String {
        for key in (preferredKeys[name] ?? []) + fallbackKeys {
            if let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ClaudeSessionScan.singleLine(value, limit: AgentTranscriptLimits.summaryCharacters)
            }
        }
        // 提问：第一个问题。
        if let questions = args["questions"] as? [Any], let first = questions.first as? [String: Any],
           let question = first["question"] as? String, !question.isEmpty {
            return ClaudeSessionScan.singleLine(question, limit: AgentTranscriptLimits.summaryCharacters)
        }
        var shown = args
        shown.removeValue(forKey: "toolSummary")
        guard !shown.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys, .fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return ClaudeSessionScan.singleLine(json, limit: AgentTranscriptLimits.summaryCharacters)
    }
}
