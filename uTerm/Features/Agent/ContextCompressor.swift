import AgentKit
import Foundation

/// The compression *algorithm* now lives once in `AgentKit.AgentContextCompressor`
/// (identical to what uTable's `AgentContextCompressor` moved to). This file
/// keeps the old in-module name as a thin alias plus this app's
/// `CompressibleMessage` conformance for `ChatMessage` — the message *shape*
/// (2 roles, `ToolCallState` calls) stays uTerm-owned.
typealias ContextCompressor = AgentContextCompressor

nonisolated extension ChatMessage: CompressibleMessage {
    var isTurnBoundary: Bool { role == .user }

    var payloadByteCount: Int {
        var bytes = text.utf8.count
        for call in toolCalls {
            bytes += call.command.utf8.count
            bytes += call.explanation?.utf8.count ?? 0
            bytes += call.output?.utf8.count ?? 0
        }
        return bytes
    }

    var turnText: String? { role == .user ? text : nil }

    var toolCallNames: [String] { toolCalls.map(\.name) }

    func folded(policy: AgentContextCompressor.Policy) -> ChatMessage {
        var folded = self
        if folded.text.count > policy.foldedTextCap {
            folded.text = String(folded.text.prefix(policy.foldedTextCap)) + "…（已截断）"
        }
        folded.toolCalls = folded.toolCalls.map { call in
            guard let output = call.output, output.count > policy.foldedToolResultCap else {
                return call
            }
            var trimmed = call
            trimmed.output = String(output.prefix(policy.foldedToolResultCap))
                + "…（输出已折叠，原 \(output.count) 字符；需要时请重新执行命令）"
            return trimmed
        }
        return folded
    }

    /// 被丢弃轮次的确定性摘要。uTerm 只有一种工具（run_command），所以只报总次数，
    /// 不像 uTable 那样按工具名分别列出（`toolCallCounts` 的 key 恒为 "run_command"）。
    static func digestMessage(count: Int, firstTurnText: String?, toolCallCounts: [String: Int]) -> ChatMessage {
        var parts: [String] = ["（上下文压缩：已省略更早的 \(count) 条消息"]
        if let first = firstTurnText {
            let head = first.count > 80 ? String(first.prefix(80)) + "…" : first
            parts.append("，最早的请求是「\(head)」")
        }
        let commandCount = toolCallCounts.values.reduce(0, +)
        if commandCount > 0 {
            parts.append("；期间执行过 \(commandCount) 次命令")
        }
        parts.append("。需要这些细节时请重新执行命令获取。）")
        return ChatMessage(role: .user, text: parts.joined())
    }
}
