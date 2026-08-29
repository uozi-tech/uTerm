import Foundation
import XCTest
@testable import AgentKit

/// A minimal message conforming to `CompressibleMessage`, standing in for
/// both apps' real message types so the generic algorithm gets exercised
/// without pulling in either app's model. Mirrors the shapes exercised by
/// uTable's `AgentContextCompressorTests` and uTerm's `ContextCompressorTests`
/// (a user turn, an assistant reply with one named tool call, a big tool
/// result / output payload).
private struct MockMessage: CompressibleMessage, Equatable {
    enum Kind: Equatable { case user, assistant, toolResult }
    var kind: Kind
    var text: String
    var toolCallName: String?
    var payload: String = ""

    var isTurnBoundary: Bool { kind == .user }
    var payloadByteCount: Int { text.utf8.count + payload.utf8.count }
    var turnText: String? { kind == .user ? text : nil }
    var toolCallNames: [String] { toolCallName.map { [$0] } ?? [] }

    func folded(policy: AgentContextCompressor.Policy) -> MockMessage {
        var copy = self
        if kind == .toolResult, payload.count > policy.foldedToolResultCap {
            copy.payload = String(payload.prefix(policy.foldedToolResultCap)) + "…(folded)"
        } else if text.count > policy.foldedTextCap {
            copy.text = String(text.prefix(policy.foldedTextCap)) + "…(truncated)"
        }
        return copy
    }

    static func digestMessage(count: Int, firstTurnText: String?, toolCallCounts: [String: Int]) -> MockMessage {
        var note = "(compressed: omitted \(count) messages"
        if let firstTurnText {
            note += ", earliest request was \"\(firstTurnText)\""
        }
        if !toolCallCounts.isEmpty {
            let summary = toolCallCounts.sorted { $0.key < $1.key }
                .map { "\($0.key)x\($0.value)" }.joined(separator: ", ")
            note += "; tools called: \(summary)"
        }
        note += ")"
        return MockMessage(kind: .user, text: note)
    }
}

final class AgentContextCompressorTests: XCTestCase {

    private func turn(_ index: Int, resultSize: Int) -> [MockMessage] {
        [
            MockMessage(kind: .user, text: "question \(index)"),
            MockMessage(kind: .assistant, text: "", toolCallName: "describe_table"),
            MockMessage(kind: .toolResult, text: "", payload: String(repeating: "x", count: resultSize)),
            MockMessage(kind: .assistant, text: "answer for turn \(index)."),
        ]
    }

    func testUnderBudgetIsIdentity() {
        let messages = turn(1, resultSize: 100)
        XCTAssertEqual(
            AgentContextCompressor.compress(messages, policy: .init(tokenBudget: 10_000)),
            messages
        )
    }

    func testFoldsOldToolResultsKeepsRecentVerbatim() throws {
        // 5 turns, 6000-char tool results each ≈ 2000 tokens; the budget fits
        // everything once folded, so nothing should be dropped.
        let messages = (1...5).flatMap { turn($0, resultSize: 6000) }
        let policy = AgentContextCompressor.Policy(
            tokenBudget: 5_000, keptRecentMessages: 4, foldedToolResultCap: 100
        )
        let out = AgentContextCompressor.compress(messages, policy: policy)

        XCTAssertEqual(out.count, messages.count)
        XCTAssertEqual(Array(out.suffix(4)), Array(messages.suffix(4)))
        let folded = out[2]
        XCTAssertEqual(folded.kind, .toolResult)
        XCTAssertTrue(folded.payload.contains("folded"))
        XCTAssertTrue(folded.payload.utf8.count < 400)
        XCTAssertLessThanOrEqual(AgentContextCompressor.estimateTokens(out), policy.tokenBudget)
    }

    func testDropsOldestTurnsWithDigestWhenFoldingIsNotEnough() throws {
        let messages = (1...8).flatMap { turn($0, resultSize: 9000) }
        let policy = AgentContextCompressor.Policy(
            tokenBudget: 4_000, keptRecentMessages: 4, foldedToolResultCap: 3000
        )
        let out = AgentContextCompressor.compress(messages, policy: policy)

        let first = try XCTUnwrap(out.first)
        XCTAssertEqual(first.kind, .user)
        XCTAssertTrue(first.text.contains("compressed"))
        XCTAssertTrue(first.text.contains("question 1"))
        XCTAssertTrue(first.text.contains("describe_table"))

        XCTAssertEqual(out[1].kind, .user) // digest note is followed by a user boundary
        XCTAssertEqual(Array(out.suffix(4)), Array(messages.suffix(4)))
    }

    func testRecentWindowExtendsBackToUserBoundary() {
        let messages = turn(1, resultSize: 40_000) + turn(2, resultSize: 200)
        let policy = AgentContextCompressor.Policy(
            tokenBudget: 2_000, keptRecentMessages: 2, foldedToolResultCap: 100
        )
        let out = AgentContextCompressor.compress(messages, policy: policy)
        XCTAssertEqual(Array(out.suffix(4)), Array(messages.suffix(4)))
    }

    func testEstimateScalesWithContent() {
        let small = AgentContextCompressor.estimateTokens([MockMessage(kind: .user, text: "hi")])
        let large = AgentContextCompressor.estimateTokens([
            MockMessage(kind: .user, text: String(repeating: "content", count: 3000)),
        ])
        XCTAssertGreaterThan(large, small * 100)
    }
}
