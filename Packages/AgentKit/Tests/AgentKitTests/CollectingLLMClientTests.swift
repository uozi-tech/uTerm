import XCTest
@testable import AgentKit

final class CollectingLLMClientTests: XCTestCase {
    private struct BoomError: Error, Equatable {}

    private func stream(_ events: [LLMEvent], thenThrow error: Error? = nil) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    func testCollectsTextDeltasConcatenated() async throws {
        let collected = try await CollectingLLMClient.collect(stream([.text("Hi"), .text(" there")]))
        XCTAssertEqual(collected.text, "Hi there")
        XCTAssertTrue(collected.toolCalls.isEmpty)
    }

    func testCollectsToolCallsInArrivalOrder() async throws {
        let a = LLMToolCall(id: "1", name: "a", argumentsJSON: "{}")
        let b = LLMToolCall(id: "2", name: "b", argumentsJSON: "{}")
        let collected = try await CollectingLLMClient.collect(stream([.toolCall(a), .toolCall(b)]))
        XCTAssertNil(collected.text)
        XCTAssertEqual(collected.toolCalls, [a, b])
    }

    func testCollectsMixedTextAndToolCalls() async throws {
        let call = LLMToolCall(id: "1", name: "run", argumentsJSON: #"{"x":1}"#)
        let collected = try await CollectingLLMClient.collect(
            stream([.text("checking..."), .toolCall(call)]))
        XCTAssertEqual(collected.text, "checking...")
        XCTAssertEqual(collected.toolCalls, [call])
    }

    func testEmptyStreamYieldsNilTextAndNoToolCalls() async throws {
        let collected = try await CollectingLLMClient.collect(stream([]))
        XCTAssertNil(collected.text)
        XCTAssertTrue(collected.toolCalls.isEmpty)
    }

    func testFailureBeforeAnyEventCarriesEmptyPartial() async {
        do {
            _ = try await CollectingLLMClient.collect(stream([], thenThrow: BoomError()))
            XCTFail("should throw")
        } catch let failure as CollectingLLMClient.CollectionFailure {
            XCTAssertNil(failure.partial.text)
            XCTAssertTrue(failure.partial.toolCalls.isEmpty)
            XCTAssertTrue(failure.underlying is BoomError)
        } catch {
            XCTFail("expected CollectionFailure, got \(error)")
        }
    }

    func testFailureAfterSomeEventsCarriesThatPartial() async {
        do {
            _ = try await CollectingLLMClient.collect(stream([.text("partial")], thenThrow: BoomError()))
            XCTFail("should throw")
        } catch let failure as CollectingLLMClient.CollectionFailure {
            XCTAssertEqual(failure.partial.text, "partial")
            XCTAssertTrue(failure.underlying is BoomError)
        } catch {
            XCTFail("expected CollectionFailure, got \(error)")
        }
    }
}
