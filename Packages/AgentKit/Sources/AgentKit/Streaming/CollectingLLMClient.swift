import Foundation

/// Folds a stream of `LLMEvent`s into one complete result: all text deltas
/// concatenated, all tool calls in arrival order.
///
/// This is the generic half of "collect a stream into a complete response" —
/// shared, provider-agnostic, and independent of either app's own
/// request/response shape (uTerm drives its UI directly off the event stream
/// and has no need to collect; uTable's `StreamCollectingProvider` uses this
/// to implement its non-streaming `chat(_:)` on top of a streaming client,
/// then maps `Collected` into its own `ChatResponse` — see AgentKit HANDOFF
/// phase 2 notes for why that mapping couldn't itself live here: usage and a
/// literal finish reason are wire-format-specific and get lost before an
/// event ever reaches this generic collector).
public enum CollectingLLMClient {
    /// One stream's events, folded into a single result.
    public struct Collected: Sendable, Equatable {
        /// Concatenation of every `.text` event's delta; `nil` when the
        /// stream produced no text at all (as opposed to empty text).
        public let text: String?
        /// Every `.toolCall` event, in arrival order.
        public let toolCalls: [LLMToolCall]

        public init(text: String?, toolCalls: [LLMToolCall]) {
            self.text = text
            self.toolCalls = toolCalls
        }
    }

    /// Thrown when `collect(_:)`'s underlying stream fails before finishing.
    /// Carries whatever was folded before the failure, so a caller can tell
    /// "nothing arrived yet" (e.g. an HTTP error before the first SSE byte —
    /// safe to retry through an entirely different path) apart from "some
    /// progress was made" (a mid-stream drop after real content/tool calls
    /// already surfaced — silently retrying risks duplicated side effects).
    public struct CollectionFailure: Error, Sendable {
        public let partial: Collected
        public let underlying: Error

        public init(partial: Collected, underlying: Error) {
            self.partial = partial
            self.underlying = underlying
        }
    }

    /// Drains `events` to completion and folds it into a `Collected`. On
    /// failure, throws `CollectionFailure` wrapping whatever was folded so far
    /// plus the underlying error — never the bare underlying error — so a
    /// caller can inspect `partial` before deciding how to react.
    public static func collect(_ events: AsyncThrowingStream<LLMEvent, Error>) async throws -> Collected {
        var text: String?
        var toolCalls: [LLMToolCall] = []
        do {
            for try await event in events {
                switch event {
                case .text(let delta):
                    text = (text ?? "") + delta
                case .toolCall(let call):
                    toolCalls.append(call)
                }
            }
        } catch {
            throw CollectionFailure(partial: Collected(text: text, toolCalls: toolCalls), underlying: error)
        }
        return Collected(text: text, toolCalls: toolCalls)
    }
}
