import Foundation

/// Cursor 命令行的一份库 → 要显示的条目（按时间先后，结果与调用分开，由 `AgentTranscriptAssembler` 挂上去）。
///
/// 条目 ID：`<第几轮>.u`（你说的）、`<第几轮>.<第几步>`（回答、思考、工具调用）、`<第几轮>.<第几步>.r`（工具结果）、
/// `<第几轮>.c` / `.o`（你敲的 shell 命令与输出）。会话只往后长，所以同一条的 ID 不变；工具结果单独成条，
/// 调用先写、结果后到时，跟随读到的只是一条新的结果（已经显示的调用不用改）。
///
/// 映射（`AgentTranscriptItem.Kind` 没有的就近放）：
/// - 用户消息 → `.userText`；用户敲的 shell 命令 → `.command("! …")` + `.commandOutput`。
/// - 回答 → `.assistantText`；思考 → `.thinking`（空的只有用时，不显示）。
/// - 工具调用 → `.toolCall` + `.toolResult`；子代理（`Task`）也是普通的工具调用：它的过程嵌在结果里，没有单独的记录，
///   结果显示子代理最后的回答。
/// - 没有时间戳：只有第一轮的用户消息带会话的创建时间。
nonisolated enum CursorTranscriptParser {
    static func items(in database: SQLiteMemoryDatabase) throws -> [AgentTranscriptItem] {
        guard let loaded = try CursorChatStore.load(database), let root = loaded.root else { return [] }
        let legacy = CursorChatStore.usesLegacyTurns(root)
        var output: [AgentTranscriptItem] = []
        for (index, reference) in CursorChatStore.turnReferences(root).enumerated() {
            guard let turn = try CursorChatStore.turn(reference, legacy: legacy, blobs: loaded.blobs) else { continue }
            output.append(contentsOf: items(of: turn, index: index,
                                            timestamp: index == 0 ? loaded.meta.createdAt : nil))
        }
        return output
    }

    static func items(of turn: CursorChatStore.Turn, index: Int, timestamp: Date?) -> [AgentTranscriptItem] {
        let prefix = String(index)
        var output: [AgentTranscriptItem] = []
        switch turn {
        case .shell(let command, let result):
            if let command = command?.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
                output.append(AgentTranscriptItem(id: prefix + ".c", kind: .command("! " + command), timestamp: timestamp))
            }
            if let result {
                let text = joined([result.text(1), result.text(2)])
                if !text.isEmpty {
                    output.append(AgentTranscriptItem(
                        id: prefix + ".o",
                        kind: .commandOutput(AgentClippedText(text, limit: AgentTranscriptLimits.toolResultCharacters))))
                }
            }
        case .agent(let user, let steps):
            if let text = user?.text(1), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(AgentTranscriptItem(id: prefix + ".u", kind: .userText(clip(text, AgentTranscriptLimits.textCharacters)),
                                                  timestamp: timestamp))
            }
            for (stepIndex, step) in steps.enumerated() {
                guard let step else { continue }
                output.append(contentsOf: items(ofStep: step, id: "\(prefix).\(stepIndex)"))
            }
        }
        return output
    }

    /// 一步：1 回答、2 工具调用、3 思考。
    static func items(ofStep step: CursorProtobufMessage, id: String) -> [AgentTranscriptItem] {
        if let assistant = step.message(1) {
            guard let text = assistant.text(1), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [AgentTranscriptItem(id: id, kind: .assistantText(clip(text, AgentTranscriptLimits.textCharacters)))]
        }
        if let thinking = step.message(3) {
            guard let text = thinking.text(1), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [AgentTranscriptItem(id: id, kind: .thinking(AgentClippedText(text, limit: AgentTranscriptLimits.thinkingCharacters)))]
        }
        if let call = step.message(2) {
            return CursorToolCall.items(call, id: id)
        }
        return []
    }

    static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0?.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let clipped = AgentClippedText(text, limit: limit)
        return clipped.isClipped ? clipped.text + "\n\n…" : clipped.text
    }
}

/// 一次工具调用（`agent.v1.ToolCall`，oneof：字段号决定是哪种工具，每种都是 1 `args` + 2 `result`）。
/// `result` 也是 oneof，1 几乎总是成功，其余是各种失败（找不到文件、被拒绝、超时……）。
nonisolated enum CursorToolCall {
    /// 一种工具怎么显示：名字（照 `cursor-agent` 发给模型时的叫法）、参数里哪个字段当摘要。
    nonisolated struct Kind: Sendable {
        let name: String
        /// 参数里依次找这些字段号的字符串（repeated 的拼起来）。
        let summaryFields: [Int]
    }

    /// 字段号 → 工具。不认识的字段号显示成 `Tool <号>`，摘要取参数里第一段可打印的文字。
    static let kinds: [Int: Kind] = [
        1: Kind(name: "Shell", summaryFields: [1]),
        3: Kind(name: "Delete", summaryFields: [1]),
        4: Kind(name: "Glob", summaryFields: [2, 1]),
        5: Kind(name: "Grep", summaryFields: [1]),
        8: Kind(name: "Read", summaryFields: [1]),
        9: Kind(name: "TodoWrite", summaryFields: []),
        10: Kind(name: "ReadTodos", summaryFields: []),
        12: Kind(name: "Edit", summaryFields: [1]),
        13: Kind(name: "LS", summaryFields: [1]),
        14: Kind(name: "ReadLints", summaryFields: [1]),
        15: Kind(name: "MCP", summaryFields: [5, 1]),
        16: Kind(name: "SemanticSearch", summaryFields: [1]),
        17: Kind(name: "CreatePlan", summaryFields: [4, 3]),
        18: Kind(name: "WebSearch", summaryFields: [1]),
        19: Kind(name: "Task", summaryFields: [1, 2]),
        20: Kind(name: "ListMcpResources", summaryFields: []),
        21: Kind(name: "ReadMcpResource", summaryFields: []),
        22: Kind(name: "ApplyAgentDiff", summaryFields: []),
        23: Kind(name: "AskQuestion", summaryFields: []),
        24: Kind(name: "Fetch", summaryFields: [1]),
        25: Kind(name: "SwitchMode", summaryFields: []),
        26: Kind(name: "ExaSearch", summaryFields: []),
        27: Kind(name: "ExaFetch", summaryFields: []),
        28: Kind(name: "GenerateImage", summaryFields: []),
        29: Kind(name: "RecordScreen", summaryFields: []),
        30: Kind(name: "ComputerUse", summaryFields: []),
    ]

    /// 调用一条，有结果再一条（`<id>.r`）。
    static func items(_ call: CursorProtobufMessage, id: String) -> [AgentTranscriptItem] {
        guard let picked = call.oneof(1...999) else { return [] }
        let (number, tool) = picked
        let kind = kinds[number]
        let name = kind?.name ?? "Tool \(number)"
        let args = tool.message(1)
        var items = [AgentTranscriptItem(id: id, kind: .toolCall(AgentToolCall(
            toolUseID: id, name: name, summary: summary(args, kind: kind, number: number), result: nil)))]
        if let result = tool.message(2), let outcome = resultText(result, tool: number) {
            let (text, isError) = outcome
            items.append(AgentTranscriptItem(id: id + ".r", kind: .toolResult(AgentToolResult(
                toolUseID: id, content: AgentClippedText(ClaudeUserText.stripTerminalEscapes(text),
                                                         limit: AgentTranscriptLimits.toolResultCharacters),
                isError: isError, imageCount: 0))))
        }
        return items
    }

    static func summary(_ args: CursorProtobufMessage?, kind: Kind?, number: Int) -> String {
        guard let args else { return "" }
        let limit = AgentTranscriptLimits.summaryCharacters
        if number == 9 {
            // TodoWrite：每一项的内容。
            let todos = args.messages(1).compactMap { $0.text(2) }
            return ClaudeSessionScan.singleLine(todos.joined(separator: "; "), limit: limit)
        }
        for field in kind?.summaryFields ?? [] {
            let values = args.strings(field).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !values.isEmpty { return ClaudeSessionScan.singleLine(values.joined(separator: ", "), limit: limit) }
        }
        return args.firstPrintableString().map { ClaudeSessionScan.singleLine($0, limit: limit) } ?? ""
    }

    /// 结果的文字与是否失败；没有可显示的为 nil（还在跑的调用没有结果）。
    static func resultText(_ result: CursorProtobufMessage, tool: Int) -> (String, Bool)? {
        guard let picked = result.oneof(1...99) else { return nil }
        let (outcome, body) = picked
        var isError = outcome != 1
        let text: String
        switch (tool, outcome) {
        case (1, 1), (1, 2):
            // Shell：成功与非零退出的结构一样。交错的输出（stdout 与 stderr 按时间混在一起）有就用它。
            text = body.text(10) ?? CursorTranscriptParser.joined([body.text(5), body.text(6)])
        case (8, 1):
            text = body.string(1) ?? ""
        case (12, 1):
            text = body.text(5) ?? body.text(8) ?? ""
        case (4, 1):
            text = body.strings(3).joined(separator: "\n")
        case (5, 1):
            text = grep(body)
        case (9, 1), (10, 1):
            text = body.messages(1).compactMap { $0.text(2) }.joined(separator: "\n")
        case (15, 1):
            // MCP：内容里的文字，另有 is_error。
            text = body.messages(1).compactMap { $0.message(1)?.text(1) }.joined(separator: "\n")
            if body.varint(2) == 1 { isError = true }
        case (19, 1):
            // 子代理：它最后的回答。
            text = body.messages(1).compactMap { $0.message(1)?.text(1) }.last ?? ""
        case (24, 1):
            text = body.text(2) ?? ""
        default:
            text = body.printableStrings().joined(separator: "\n")
        }
        return (text, isError)
    }

    /// Grep 的结果：每个工作区一份（map），内容模式是「文件:行号:内容」，文件模式是文件名，计数模式是「文件:次数」。
    private static func grep(_ success: CursorProtobufMessage) -> String {
        var lines: [String] = []
        let unions = success.messages(4).compactMap { $0.message(2) } + [success.message(5)].compactMap { $0 }
        for union in unions {
            if let content = union.message(3) {
                for file in content.messages(1) {
                    let name = file.string(1) ?? ""
                    for match in file.messages(2) {
                        let line = match.varint(1).map { String(Int32(truncatingIfNeeded: $0)) } ?? ""
                        lines.append("\(name):\(line):\(match.string(2) ?? "")")
                    }
                }
            } else if let files = union.message(2) {
                lines.append(contentsOf: files.strings(1))
            } else if let counts = union.message(1) {
                for count in counts.messages(1) {
                    let value = count.varint(2).map { String(Int32(truncatingIfNeeded: $0)) } ?? ""
                    lines.append("\(count.string(1) ?? ""):\(value)")
                }
            }
            if lines.count > 2000 { break }
        }
        return lines.joined(separator: "\n")
    }
}
