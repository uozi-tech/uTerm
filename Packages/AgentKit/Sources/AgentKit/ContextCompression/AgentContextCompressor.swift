import Foundation

/// Automatic outbound context compression: before each turn is sent, pack an
/// over-budget conversation history back within a token budget. In-memory
/// state and any persisted chat record always keep the full text — compression
/// only ever touches the outbound copy built for this one request.
///
/// Ported from two independent, byte-for-byte-identical implementations
/// (uTable's `AgentContextCompressor` operating on `AgentMessage`, uTerm's
/// `ContextCompressor` operating on `ChatMessage`) into one generic algorithm.
/// Each app's message type conforms to `CompressibleMessage` instead of the
/// algorithm knowing about either shape.
///
/// Three-stage strategy (deterministic, zero extra API calls, zero latency):
/// 1. Keep the most recent window verbatim (extended backward to the nearest
///    user-turn boundary, so the window always starts on a complete turn);
/// 2. Outside the window, "fold" first: old tool results and old long text get
///    truncated to a summary line — tool dumps are the biggest source of
///    context bloat, and folding them is usually enough;
/// 3. If still over budget, drop whole turns from the oldest end (aligned to
///    user boundaries), replacing them with one deterministic digest message
///    (earliest request + tool-call counts) so the model knows it can re-fetch
///    detail.
///
/// Drops always happen on turn boundaries, so an assistant(tool_calls) ↔
/// tool_result pairing is never split (providers validate this strictly).
/// Pure function, fully unit-testable.
public enum AgentContextCompressor {

    public struct Policy: Sendable {
        /// Token budget for the outbound messages (system prompt excluded).
        public var tokenBudget: Int
        /// Number of most-recent messages kept verbatim (the actual window
        /// may be larger: it extends backward to a user-turn boundary).
        public var keptRecentMessages: Int
        /// Prefix length (characters) kept when folding an out-of-window tool
        /// result.
        public var foldedToolResultCap: Int
        /// Prefix length (characters) kept when folding out-of-window
        /// user/assistant text.
        public var foldedTextCap: Int

        public init(
            tokenBudget: Int = 12_000,
            keptRecentMessages: Int = 12,
            foldedToolResultCap: Int = 200,
            foldedTextCap: Int = 600
        ) {
            self.tokenBudget = tokenBudget
            self.keptRecentMessages = keptRecentMessages
            self.foldedToolResultCap = foldedToolResultCap
            self.foldedTextCap = foldedTextCap
        }
    }

    // MARK: - Estimation

    /// Rough estimate: UTF-8 byte count / 3. One CJK character is ~3 bytes ≈
    /// 1–2 tokens, four English characters ≈ 1 token; 3 is a reasonable
    /// compromise for mixed text. Budgeting needs the right order of
    /// magnitude, not an exact token count.
    public static func estimateTokens<M: CompressibleMessage>(_ message: M) -> Int {
        max(1, message.payloadByteCount / 3)
    }

    public static func estimateTokens<M: CompressibleMessage>(_ messages: [M]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    // MARK: - Compression

    public static func compress<M: CompressibleMessage>(
        _ messages: [M],
        policy: Policy = Policy()
    ) -> [M] {
        guard estimateTokens(messages) > policy.tokenBudget else { return messages }

        let windowStart = recentWindowStart(messages, keep: policy.keptRecentMessages)
        guard windowStart > 0 else { return messages }

        // Stage 1: fold everything outside the window.
        var folded = messages
        for index in 0..<windowStart {
            folded[index] = messages[index].folded(policy: policy)
        }
        if estimateTokens(folded) <= policy.tokenBudget {
            return folded
        }

        // Stage 2: drop whole turns from the oldest end (aligned to user boundaries).
        let boundaries = userBoundaries(in: messages, before: windowStart)
        var digest = DroppedDigest<M>()
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

    // MARK: - Private

    /// Start of the recent window: walk backward from "keep-th from the end"
    /// to the nearest user-turn boundary.
    private static func recentWindowStart<M: CompressibleMessage>(_ messages: [M], keep: Int) -> Int {
        guard messages.count > keep else { return 0 }
        var index = messages.count - keep
        while index > 0 {
            if messages[index].isTurnBoundary { return index }
            index -= 1
        }
        return 0
    }

    /// Indices of every user-turn message before `end` (ascending, with a
    /// synthetic 0 fallback).
    private static func userBoundaries<M: CompressibleMessage>(in messages: [M], before end: Int) -> [Int] {
        var result: [Int] = []
        for index in 0..<end where messages[index].isTurnBoundary {
            result.append(index)
        }
        if result.first != 0 { result.insert(0, at: 0) }
        return result
    }

    /// Deterministic summary of a run of dropped turns.
    private struct DroppedDigest<M: CompressibleMessage> {
        var count = 0
        var firstTurnText: String?
        var toolCounts: [String: Int] = [:]

        mutating func absorb(_ dropped: ArraySlice<M>) {
            for message in dropped {
                count += 1
                if let text = message.turnText, firstTurnText == nil {
                    firstTurnText = text
                }
                for name in message.toolCallNames {
                    toolCounts[name, default: 0] += 1
                }
            }
        }

        var noteMessage: M {
            M.digestMessage(count: count, firstTurnText: firstTurnText, toolCallCounts: toolCounts)
        }

        var estimatedTokens: Int {
            AgentContextCompressor.estimateTokens(noteMessage)
        }
    }
}
