import Foundation

/// A message type that `AgentContextCompressor`'s single generic algorithm can
/// operate on. uTerm's `ChatMessage` (2 roles, `ToolCallState` calls) and
/// uTable's `AgentMessage` (4 roles, `ToolCall`s) conform independently in
/// their own app targets — the compression *algorithm* lives once in this
/// package; the message *shape* stays app-owned.
///
/// The five requirements are exactly what the algorithm needs: where turn
/// boundaries are (so drops/windows never split a tool_use/tool_result pair),
/// how big a message roughly is, what to fold when it is outside the kept
/// window, and how to phrase the digest note that replaces dropped turns
/// (left to the conformer because the right phrasing depends on the app's
/// tool vocabulary — uTable names several distinct tools, uTerm only ever
/// runs `run_command`).
public protocol CompressibleMessage: Sendable {
    /// Whether this message starts a new conversational turn (the app's
    /// "user" role). Window/drop boundaries always align to these.
    var isTurnBoundary: Bool { get }

    /// Rough size of this message's payload in bytes (text + any tool
    /// call/result payload). Only relative magnitude matters — the budget
    /// comparison divides by a constant to approximate tokens.
    var payloadByteCount: Int { get }

    /// This message's plain text when it is a turn boundary; `nil` otherwise.
    /// Used to quote "the earliest request was ..." in the digest note.
    var turnText: String? { get }

    /// Names of any tool calls this message carries (assistant messages
    /// only); empty for everything else.
    var toolCallNames: [String] { get }

    /// Returns a copy with long text / tool-output fields truncated to the
    /// policy's caps. Messages already within the caps return unchanged.
    func folded(policy: AgentContextCompressor.Policy) -> Self

    /// Builds the synthetic message that replaces a run of dropped turns,
    /// e.g. "(context compressed: omitted N earlier messages ...)". Must
    /// return a turn-boundary message so the windowing logic downstream of
    /// it keeps treating it as a valid drop point.
    static func digestMessage(count: Int, firstTurnText: String?, toolCallCounts: [String: Int]) -> Self
}
