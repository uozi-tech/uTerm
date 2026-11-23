import Foundation

/// Claude Code 记录（JSONL，一行一条）里的一行 → 要显示的条目。
///
/// 记录格式没有公开规格（按 Claude Code 2.1.x 的实际文件写的）。行的类型有几十种，要显示的只有
/// `type` 为 `user` / `assistant` 的；其余（`api-request`、`attachment`、`file-history-snapshot`……）以及
/// 不认识的一律跳过。还要跳过：`isSidechain`（子代理的对话，混在主对话里的老版本记录；读子代理自己的记录时
/// 每行都是，这时 `includesSidechain` 为 true）、`isMeta`（系统注入）。`isCompactSummary` 是上下文压缩后的摘要。
///
/// 派子代理的调用（`Agent`，旧版本叫 `Task`）带上 `spawn`；它的结果那一行顶层的 `toolUseResult.agentId`
/// 记在结果上（`spawnedAgentID`），用来找到子代理的记录。
///
/// 大行（附件、工具结果能到 MB 级）先看行首一小段判断类型，不要的不做 JSON 解析。
nonisolated enum ClaudeTranscriptParser {
    /// 判断类型看行首多少字节。`user` 行的 `type` 在一百字节左右，`assistant` 行的 `role` 在两百字节以内。
    static let headBytes = 1024

    /// 看行首判断值不值得解析：可能是要显示的消息行就是 true。
    static func isMessageCandidate(head: Data, includesSidechain: Bool = false) -> Bool {
        let head = head.prefix(headBytes)
        // 元信息行以 `{"type":"…"` 开头，一眼就能定。
        let typePrefix = Data("{\"type\":\"".utf8)
        if head.starts(with: typePrefix) {
            let rest = head.dropFirst(typePrefix.count)
            return rest.starts(with: Data("user\"".utf8)) || rest.starts(with: Data("assistant\"".utf8))
        }
        if !includesSidechain, ClaudeJSONLScan.contains("\"isSidechain\":true", in: head) { return false }
        for marker in ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"role\":\"assistant\"", "\"role\":\"user\""]
        where ClaudeJSONLScan.contains(marker, in: head) {
            return true
        }
        return false
    }

    /// 一行 → 条目（可能没有，也可能好几条）。`line` 是 `ClaudeReverseLineScanner` 切出来的。
    static func items(from line: ClaudeReverseLineScanner.Line, includesSidechain: Bool = false) -> [AgentTranscriptItem] {
        let idPrefix = String(line.offset)
        guard isMessageCandidate(head: line.bytes, includesSidechain: includesSidechain) else { return [] }
        if line.isTruncated {
            return [AgentTranscriptItem(id: idPrefix + ".0", kind: .oversized(bytes: line.length))]
        }
        return items(fromJSON: line.bytes, idPrefix: idPrefix, includesSidechain: includesSidechain)
    }

    /// 解析一整行。坏行、不认识的结构返回空，不抛错。
    static func items(fromJSON data: Data, idPrefix: String, includesSidechain: Bool = false) -> [AgentTranscriptItem] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant" else { return [] }
        if (!includesSidechain && object["isSidechain"] as? Bool == true) || object["isMeta"] as? Bool == true { return [] }
        let timestamp = (object["timestamp"] as? String).flatMap(ClaudeTimestamp.parse)
        let message = object["message"] as? [String: Any]
        let content = message?["content"]

        var kinds: [AgentTranscriptItem.Kind] = []
        if type == "user" {
            if object["isCompactSummary"] as? Bool == true {
                let text = Self.text(of: content)
                kinds.append(.compactSummary(AgentClippedText(text, limit: AgentTranscriptLimits.compactSummaryCharacters)))
            } else if let string = content as? String {
                kinds.append(contentsOf: ClaudeUserText.kinds(from: string))
            } else if let blocks = content as? [Any] {
                for case let block as [String: Any] in blocks {
                    kinds.append(contentsOf: userBlock(block))
                }
                attachSpawnedAgent(object["toolUseResult"], to: &kinds)
            }
        } else {
            if let string = content as? String {
                if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    kinds.append(.assistantText(clip(string, AgentTranscriptLimits.textCharacters)))
                }
            } else if let blocks = content as? [Any] {
                for case let block as [String: Any] in blocks {
                    if let kind = assistantBlock(block) { kinds.append(kind) }
                }
            }
        }
        return kinds.enumerated().map { index, kind in
            AgentTranscriptItem(id: "\(idPrefix).\(index)", kind: kind, timestamp: timestamp)
        }
    }

    /// 派子代理那次调用的结果：行顶层的 `toolUseResult.agentId` 是子代理的 ID。一行只有一个工具结果时才认
    /// （几个结果挤在一行时分不清是谁的）。
    private static func attachSpawnedAgent(_ toolUseResult: Any?, to kinds: inout [AgentTranscriptItem.Kind]) {
        guard let agentID = (toolUseResult as? [String: Any])?["agentId"] as? String, !agentID.isEmpty else { return }
        let indices = kinds.indices.filter { if case .toolResult = kinds[$0] { return true } else { return false } }
        guard indices.count == 1, case .toolResult(var result) = kinds[indices[0]] else { return }
        result.spawnedAgentID = agentID
        kinds[indices[0]] = .toolResult(result)
    }

    /// 派子代理的工具名：现在叫 `Agent`，旧版本叫 `Task`。
    static let spawnToolNames: Set<String> = ["Agent", "Task"]

    private static func userBlock(_ block: [String: Any]) -> [AgentTranscriptItem.Kind] {
        switch block["type"] as? String {
        case "text":
            return ClaudeUserText.kinds(from: block["text"] as? String ?? "")
        case "image":
            return [.image]
        case "tool_result":
            var images = 0
            let text: String
            if let string = block["content"] as? String {
                text = string
            } else if let parts = block["content"] as? [Any] {
                var pieces: [String] = []
                for case let part as [String: Any] in parts {
                    switch part["type"] as? String {
                    case "text": pieces.append(part["text"] as? String ?? "")
                    case "image": images += 1
                    default: continue
                    }
                }
                text = pieces.joined(separator: "\n")
            } else {
                text = ""
            }
            let cleaned = ClaudeUserText.stripTerminalEscapes(text)
            return [.toolResult(AgentToolResult(
                toolUseID: block["tool_use_id"] as? String,
                content: AgentClippedText(cleaned, limit: AgentTranscriptLimits.toolResultCharacters),
                isError: block["is_error"] as? Bool ?? false,
                imageCount: images))]
        default:
            return []
        }
    }

    private static func assistantBlock(_ block: [String: Any]) -> AgentTranscriptItem.Kind? {
        switch block["type"] as? String {
        case "text":
            let text = block["text"] as? String ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .assistantText(clip(text, AgentTranscriptLimits.textCharacters))
        case "thinking":
            let text = block["thinking"] as? String ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .thinking(AgentClippedText(text, limit: AgentTranscriptLimits.thinkingCharacters))
        case "tool_use":
            let name = block["name"] as? String ?? "?"
            let input = block["input"] as? [String: Any] ?? [:]
            var spawn: AgentSpawnRequest?
            if spawnToolNames.contains(name) {
                spawn = AgentSpawnRequest(description: nonEmpty(input["description"]),
                                          agentType: nonEmpty(input["subagent_type"]))
            }
            return .toolCall(AgentToolCall(toolUseID: block["id"] as? String, name: name,
                                           summary: ClaudeToolSummary.summary(name: name, input: input),
                                           result: nil, spawn: spawn))
        default:
            return nil
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = ClaudeSessionScan.singleLine(string, limit: AgentTranscriptLimits.summaryCharacters)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 压缩摘要之类可能是字符串也可能是块数组。
    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [Any] else { return "" }
        var pieces: [String] = []
        for case let block as [String: Any] in blocks where block["type"] as? String == "text" {
            pieces.append(block["text"] as? String ?? "")
        }
        return pieces.joined(separator: "\n")
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let clipped = AgentClippedText(text, limit: limit)
        return clipped.isClipped ? clipped.text + "\n\n…" : clipped.text
    }
}

/// 工具调用参数的一行摘要。
nonisolated enum ClaudeToolSummary {
    /// 常见工具各自最能说明意思的那个参数。
    private static let preferredKeys: [String: [String]] = [
        "Bash": ["command", "description"],
        "Read": ["file_path"], "Write": ["file_path"], "Edit": ["file_path"], "MultiEdit": ["file_path"],
        "NotebookEdit": ["notebook_path"],
        "Grep": ["pattern"], "Glob": ["pattern"],
        "WebFetch": ["url"], "WebSearch": ["query"],
        "Agent": ["description", "prompt"], "Task": ["description", "prompt"],
    ]
    /// 不认识的工具按这个顺序找一个字符串参数。
    private static let fallbackKeys = ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt", "name"]

    static func summary(name: String, input: [String: Any]) -> String {
        let keys = (preferredKeys[name] ?? []) + fallbackKeys
        for key in keys {
            if let value = input[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ClaudeSessionScan.singleLine(value, limit: AgentTranscriptLimits.summaryCharacters)
            }
        }
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return ClaudeSessionScan.singleLine(json, limit: AgentTranscriptLimits.summaryCharacters)
    }
}

/// 用户那一侧的文字：去掉系统注入的部分，认出斜杠命令、`!` 命令和它们的输出。
nonisolated enum ClaudeUserText {
    /// 整块不显示的标签。
    private static let hiddenTags = ["system-reminder", "local-command-caveat"]
    private static let outputTags = ["local-command-stdout", "local-command-stderr", "bash-stdout", "bash-stderr"]

    static func kinds(from raw: String) -> [AgentTranscriptItem.Kind] {
        var text = raw
        for tag in hiddenTags { text = removing(tag: tag, from: text).rest }

        var kinds: [AgentTranscriptItem.Kind] = []
        // 后台任务通知之类：整段是给模型看的，只留摘要。
        let notification = removing(tag: "task-notification", from: text)
        if !notification.inner.isEmpty {
            text = notification.rest
            for block in notification.inner {
                let summary = removing(tag: "summary", from: block).inner.first ?? ""
                let line = ClaudeSessionScan.singleLine(summary.isEmpty ? block : summary, limit: 300)
                if !line.isEmpty { kinds.append(.notice(line)) }
            }
        }

        let name = removing(tag: "command-name", from: text)
        if let command = name.inner.first?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            let args = removing(tag: "command-args", from: name.rest)
            let argument = args.inner.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            kinds.append(.command(argument.isEmpty ? command : "\(command) \(argument)"))
            text = removing(tag: "command-message", from: args.rest).rest
        }
        let bash = removing(tag: "bash-input", from: text)
        for input in bash.inner {
            let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty { kinds.append(.command("! " + command)) }
        }
        text = bash.rest
        for tag in outputTags {
            let output = removing(tag: tag, from: text)
            for inner in output.inner {
                let cleaned = stripTerminalEscapes(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    kinds.append(.commandOutput(AgentClippedText(cleaned, limit: AgentTranscriptLimits.toolResultCharacters)))
                }
            }
            text = output.rest
        }

        let rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty {
            let clipped = AgentClippedText(rest, limit: AgentTranscriptLimits.textCharacters)
            kinds.append(.userText(clipped.isClipped ? clipped.text + "\n\n…" : clipped.text))
        }
        return kinds
    }

    /// 把 `<tag>…</tag>` 全部摘出来：返回各段里面的文字和剩下的文字。没闭合的开标签原样留着。
    static func removing(tag: String, from text: String) -> (inner: [String], rest: String) {
        let open = "<\(tag)>", close = "</\(tag)>"
        guard text.contains(open) else { return ([], text) }
        var inner: [String] = []
        var rest = ""
        var cursor = text.startIndex
        while let start = text.range(of: open, range: cursor..<text.endIndex),
              let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
            rest += text[cursor..<start.lowerBound]
            inner.append(String(text[start.upperBound..<end.lowerBound]))
            cursor = end.upperBound
        }
        rest += text[cursor..<text.endIndex]
        return (inner, rest)
    }

    /// 去掉终端控制序列（颜色等）。只是为了好看：这些文字只进 SwiftUI 的文本，不进任何终端。
    static func stripTerminalEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value == 0x1B }) else { return text }
        var output = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar.value == 0x1B else {
                output.append(scalar)
                continue
            }
            guard let next = scalars.next() else { break }
            switch next {
            case "[":   // CSI：参数与中间字节，直到 0x40–0x7E 的结束字节。
                while let byte = scalars.next(), !(0x40...0x7E).contains(byte.value) {}
            case "]":   // OSC：到 BEL 或 ESC \ 为止。
                while let byte = scalars.next() {
                    if byte.value == 0x07 { break }
                    if byte.value == 0x1B { _ = scalars.next(); break }
                }
            default:
                break   // 两字节的转义，丢掉这一个字符。
            }
        }
        return String(output)
    }
}
