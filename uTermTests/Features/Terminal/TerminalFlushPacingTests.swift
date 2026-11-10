// 【迁移中，暂未编译】这份用例还依赖 SwiftTerm 或已经删掉的 SwiftTerm 时代类型，等改写到 Ghostty + 影子终端
// （`ShadowTerminal`）上的同一条行为。改写完把这一对 `#if UTERM_LEGACY_SWIFTTERM_TESTS` / `#endif` 去掉。
// 清单与进度见 docs/ghostty-eval/migration-log.md「测试改写」。
#if UTERM_LEGACY_SWIFTTERM_TESTS
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

    // MARK: 积压追赶

    private func feed(_ pacer: inout TerminalFlushPacer, elapsedMs: Double = 1, backlogged: Bool, atMs: Double) -> Int {
        pacer.didFeed(bytes: pacer.budget, elapsedMs: elapsedMs, backlogged: backlogged, nowMs: atMs)
    }

    /// 小流量喂的时候也常有新字节到达，那不是积压。
    func testTrickleIsNotBacklog() {
        let pacer = TerminalFlushPacer(pacing: pacing)
        XCTAssertFalse(pacer.isBacklogged(fed: pacer.budget / 4, hasMore: true))
        XCTAssertFalse(pacer.isBacklogged(fed: pacer.budget, hasMore: false))
        XCTAssertTrue(pacer.isBacklogged(fed: pacer.budget, hasMore: true))
    }

    func testBacklogUsesShortDelayAndIdleUsesInterval() {
        var pacer = TerminalFlushPacer(pacing: pacing)
        XCTAssertEqual(feed(&pacer, backlogged: true, atMs: 0), pacing.catchUpDelayMs)
        XCTAssertEqual(feed(&pacer, backlogged: false, atMs: 5), pacing.intervalMs)
    }

    /// 一直刷屏时不能一直占着主线程。
    func testLongBacklogFallsBackToInterval() {
        var pacer = TerminalFlushPacer(pacing: pacing)
        XCTAssertEqual(feed(&pacer, backlogged: true, atMs: 1_000), pacing.catchUpDelayMs)
        XCTAssertEqual(feed(&pacer, backlogged: true, atMs: 1_000 + pacing.catchUpWindowMs), pacing.intervalMs)
    }

    func testNewBacklogRestartsCatchUpWindow() {
        var pacer = TerminalFlushPacer(pacing: pacing)
        _ = feed(&pacer, backlogged: true, atMs: 0)
        _ = feed(&pacer, backlogged: false, atMs: 10)
        XCTAssertEqual(feed(&pacer, backlogged: true, atMs: 10_000), pacing.catchUpDelayMs)
    }

    /// 解析跟不上说明机器忙，这时不追赶。
    func testSlowFeedDoesNotCatchUp() {
        var pacer = TerminalFlushPacer(pacing: pacing)
        XCTAssertEqual(feed(&pacer, elapsedMs: pacing.targetMs + 1, backlogged: true, atMs: 0), pacing.intervalMs)
    }

    func testBackgroundNeverCatchesUp() {
        var pacer = TerminalFlushPacer(pacing: .background)
        XCTAssertEqual(feed(&pacer, backlogged: true, atMs: 0), TerminalFlushPacing.background.intervalMs)
    }

    func testSwitchingPacingResetsBudget() {
        var pacer = TerminalFlushPacer(pacing: .desktop)
        _ = feed(&pacer, backlogged: true, atMs: 0)
        XCTAssertGreaterThan(pacer.budget, TerminalFlushPacing.desktop.baseBytes)
        pacer.use(.background)
        XCTAssertEqual(pacer.budget, TerminalFlushPacing.background.baseBytes)
    }
}
#endif
