import XCTest
@testable import AgentKit

/// `LLMEvent`/`LLMToolCall` are plain, frozen data types ported unchanged from
/// uTerm's app-local originals (now a typealias there) and newly adopted by
/// uTable's SSE accumulators. Coverage here is about the Equatable contract
/// both apps' tests lean on — the algorithms that produce these values are
/// tested where they live (uTerm's `AnthropicSSEParser`/`OpenAISSEParser`
/// tests, uTable's `AnthropicClientTests`/`OpenAICompatibleClientTests`).
final class LLMEventTests: XCTestCase {
    func testTextEventsEqualByValue() {
        XCTAssertEqual(LLMEvent.text("hi"), LLMEvent.text("hi"))
        XCTAssertNotEqual(LLMEvent.text("hi"), LLMEvent.text("bye"))
    }

    func testToolCallEqualityIsFieldwise() {
        let a = LLMToolCall(id: "1", name: "run", argumentsJSON: "{}")
        let b = LLMToolCall(id: "1", name: "run", argumentsJSON: "{}")
        let c = LLMToolCall(id: "2", name: "run", argumentsJSON: "{}")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(LLMEvent.toolCall(a), LLMEvent.toolCall(b))
    }

    func testTextAndToolCallEventsAreNeverEqual() {
        let event: LLMEvent = .text("x")
        let toolEvent: LLMEvent = .toolCall(LLMToolCall(id: "1", name: "n", argumentsJSON: "{}"))
        XCTAssertNotEqual(event, toolEvent)
    }
}
