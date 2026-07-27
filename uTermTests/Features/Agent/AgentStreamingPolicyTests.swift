import XCTest
@testable import uTerm

final class AgentStreamingPolicyTests: XCTestCase {
    func testStreamingAccumulatorPublishesFirstDeltaImmediatelyAndCoalescesBurst() {
        let start = ContinuousClock.now
        var accumulator = StreamingTextAccumulator()

        XCTAssertEqual(accumulator.append("A", at: start), "A")
        XCTAssertNil(accumulator.append("B", at: start.advanced(by: .milliseconds(10))))
        XCTAssertNil(accumulator.append("C", at: start.advanced(by: .milliseconds(49))))
        XCTAssertEqual(
            accumulator.append("D", at: start.advanced(by: .milliseconds(50))),
            "BCD")
        XCTAssertNil(accumulator.flush())
    }

    func testStreamingAccumulatorFlushesUnpublishedTail() {
        let start = ContinuousClock.now
        var accumulator = StreamingTextAccumulator()

        XCTAssertEqual(accumulator.append("first", at: start), "first")
        XCTAssertNil(accumulator.append(" tail", at: start.advanced(by: .milliseconds(5))))
        XCTAssertEqual(accumulator.flush(), " tail")
        XCTAssertNil(accumulator.flush())
    }

    func testNearBottomPolicyAllowsShortContentAndToleranceBand() {
        XCTAssertTrue(AgentScrollPolicy.isNearBottom(
            visibleMaxY: 400, contentHeight: 300))
        XCTAssertTrue(AgentScrollPolicy.isNearBottom(
            visibleMaxY: 910, contentHeight: 1_000))
        XCTAssertFalse(AgentScrollPolicy.isNearBottom(
            visibleMaxY: 800, contentHeight: 1_000))
    }

    func testNearBottomPolicyRejectsInvalidGeometry() {
        XCTAssertFalse(AgentScrollPolicy.isNearBottom(
            visibleMaxY: .nan, contentHeight: 1_000))
        XCTAssertFalse(AgentScrollPolicy.isNearBottom(
            visibleMaxY: 1_000, contentHeight: .infinity))
    }

    func testWorkspaceAssistantAlignsShortConversationToTop() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Agent/Views/AssistantView.swift"),
                                encoding: .utf8)

        XCTAssertTrue(source.contains(".defaultScrollAnchor(.bottom)"))
        XCTAssertTrue(
            source.contains(".defaultScrollAnchor(.top, for: .alignment)"),
            "Short assistant conversations must align to the top without losing tail following.")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
