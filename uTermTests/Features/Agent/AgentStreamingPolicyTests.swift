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
}
