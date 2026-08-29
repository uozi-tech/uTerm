import Foundation

/// 自动上下文压缩：每轮发送前把过长的会话历史压回 token 预算内，
/// 内存 `messages` 与 SwiftData 聊天记录始终保留全文——压缩只作用于
/// `streamAssistantTurn` 的出站副本。（与 uTable AgentContextCompressor
/// 同一套算法，适配本仓库的 ChatMessage/ToolCallState 形态。）
///
/// 三段策略（确定性、零额外 API 调用、零延迟）：
/// 1. 最近窗口原文保留，并向前对齐到 user 消息边界（保证从完整一轮开始）；
/// 2. 窗口之外先「折叠」：旧工具输出与旧长文截断——命令输出是上下文膨胀
///    的大头，折掉通常就够了；
/// 3. 仍超预算再从最旧开始整轮丢弃，用一条确定性摘要（最早请求 + 工具
///    调用计数）顶在最前，提示模型细节可重新执行命令获取。
///
/// 丢弃以 user 边界为单位；折叠只改 `output` 内容不动结构，所以客户端
/// （AnthropicClient/OpenAIClient）把带工具的 assistant 消息展开成
/// tool_use + tool_result 的配对不受影响。
nonisolated enum ContextCompressor {

    struct Policy: Sendable {
        /// 出站消息（不含系统提示词）的 token 预算。
        var tokenBudget: Int = 12_000
        /// 最近保留原文的消息条数（实际窗口可能更大：向前对齐 user 边界）。
        var keptRecentMessages: Int = 12
        /// 窗口外工具输出折叠后保留的前缀字符数。
        var foldedOutputCap: Int = 200
        /// 窗口外 user/assistant 正文截断字符数。
        var foldedTextCap: Int = 600
    }

    // MARK: - 估算

    /// 粗算：UTF-8 字节数 / 3（CJK 一字 3 字节 ≈ 1–2 token、英文 4 字符 ≈ 1
    /// token，取 3 做混排折中）。预算控制要量级正确，不求精确计数。
    static func estimateTokens(_ message: ChatMessage) -> Int {
        var bytes = message.text.utf8.count
        for call in message.toolCalls {
            bytes += call.command.utf8.count
            bytes += call.explanation?.utf8.count ?? 0
            bytes += call.output?.utf8.count ?? 0
        }
        return max(1, bytes / 3)
    }

    static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    // MARK: - 压缩

    static func compress(_ messages: [ChatMessage], policy: Policy = Policy()) -> [ChatMessage] {
        guard estimateTokens(messages) > policy.tokenBudget else { return messages }

        let windowStart = recentWindowStart(messages, keep: policy.keptRecentMessages)
        guard windowStart > 0 else { return messages }

        // 阶段一：窗口外折叠。
        var folded = messages
        for index in 0..<windowStart {
            folded[index] = fold(messages[index], policy: policy)
        }
        if estimateTokens(folded) <= policy.tokenBudget {
            return folded
        }

        // 阶段二：从最旧开始按轮（user 边界）丢弃。
        let boundaries = userBoundaries(in: messages, before: windowStart)
        var digest = DroppedDigest()
        var dropUpTo = 0
        for boundary in boundaries.dropFirst() + [windowStart] {
            digest.absorb(messages[dropUpTo..<boundary])
            dropUpTo = boundary
            let remainder = Array(folded[dropUpTo...])
            if estimateTokens(remainder) + digest.estimatedTokens <= policy.tokenBudget {
                break
            }
            if boundary == windowStart { break }
        }
        return [digest.noteMessage] + Array(folded[dropUpTo...])
    }

    // MARK: - 私有

    /// 最近窗口起点：从「倒数第 keep 条」向前找最近的 user 边界。
    private static func recentWindowStart(_ messages: [ChatMessage], keep: Int) -> Int {
        guard messages.count > keep else { return 0 }
        var index = messages.count - keep
        while index > 0 {
            if messages[index].role == .user { return index }
            index -= 1
        }
        return 0
    }

    private static func userBoundaries(in messages: [ChatMessage], before end: Int) -> [Int] {
        var result: [Int] = []
        for index in 0..<end where messages[index].role == .user {
            result.append(index)
        }
        if result.first != 0 { result.insert(0, at: 0) }
        return result
    }

    private static func fold(_ message: ChatMessage, policy: Policy) -> ChatMessage {
        var folded = message
        if folded.text.count > policy.foldedTextCap {
            folded.text = String(folded.text.prefix(policy.foldedTextCap)) + "…（已截断）"
        }
        folded.toolCalls = folded.toolCalls.map { call in
            guard let output = call.output, output.count > policy.foldedOutputCap else {
                return call
            }
            var trimmed = call
            trimmed.output = String(output.prefix(policy.foldedOutputCap))
                + "…（输出已折叠，原 \(output.count) 字符；需要时请重新执行命令）"
            return trimmed
        }
        return folded
    }

    /// 被丢弃轮次的确定性摘要。
    private struct DroppedDigest {
        var count = 0
        var firstUserText: String?
        var commandCount = 0

        mutating func absorb(_ dropped: ArraySlice<ChatMessage>) {
            for message in dropped {
                count += 1
                if message.role == .user, firstUserText == nil {
                    firstUserText = message.text
                }
                commandCount += message.toolCalls.count
            }
        }

        var noteMessage: ChatMessage {
            var parts: [String] = ["（上下文压缩：已省略更早的 \(count) 条消息"]
            if let first = firstUserText {
                let head = first.count > 80 ? String(first.prefix(80)) + "…" : first
                parts.append("，最早的请求是「\(head)」")
            }
            if commandCount > 0 {
                parts.append("；期间执行过 \(commandCount) 次命令")
            }
            parts.append("。需要这些细节时请重新执行命令获取。）")
            return ChatMessage(role: .user, text: parts.joined())
        }

        var estimatedTokens: Int {
            ContextCompressor.estimateTokens(noteMessage)
        }
    }
}
