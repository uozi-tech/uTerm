import XCTest
@testable import uTerm

final class TerminalFlushPacingTests: XCTestCase {
    private let pacing = TerminalFlushPacing.desktop

    func testDoublesWhileBacklogFeedsWellUnderTarget() {
        XCTAssertEqual(pacing.nextBudget(after: 32 * 1024, elapsedMs: 1, filled: true), 64 * 1024)
    }

    func testHalvesWhenFeedExceedsTarget() {
        XCTAssertEqual(pacing.nextBudget(after: 256 * 1024, elapsedMs: 20, filled: true), 128 * 1024)
    }

    func testStaysPutWithoutBacklog() {
        XCTAssertEqual(pacing.nextBudget(after: 64 * 1024, elapsedMs: 0.1, filled: false), 64 * 1024)
    }

    func testStaysPutBetweenHalfTargetAndTarget() {
        XCTAssertEqual(pacing.nextBudget(after: 64 * 1024, elapsedMs: 6, filled: true), 64 * 1024)
    }

    func testBudgetIsClampedToBaseAndMax() {
        XCTAssertEqual(pacing.nextBudget(after: pacing.baseBytes, elapsedMs: 50, filled: true), pacing.baseBytes)
        XCTAssertEqual(pacing.nextBudget(after: pacing.maxBytes, elapsedMs: 0.1, filled: true), pacing.maxBytes)
    }
}
