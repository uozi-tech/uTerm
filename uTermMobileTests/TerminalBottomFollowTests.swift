import XCTest
@testable import uTermMobile

/// 换引擎之前：跟随底部时，滚动视图还在减速 / 回弹，输出不能去抢 contentOffset（旧引擎的本地补丁 #17）。
/// Claude Code 思考时每秒约 10 个 DEC 2026 帧，以前每帧把 offset 硬设回底部，和 UIKit 的回弹动画来回抢，
/// 滚到底部时整屏抖。四条用例核的是旧引擎的 `updateScroller` 在减速 / 回弹 / 静止时各自写不写 offset。
///
/// 那段逻辑随旧引擎一起删了。新引擎上同一条用户可见行为（滚到底 / 回弹途中来输出不抖、停下后跟到底）
/// 在系统滚动那条路径上，由 `GhosttySystemScrollJitterTests`（回弹、减速、静止时来输出，逐帧核 contentOffset 不被抢）
/// 和 `GhosttyScrollEdgeTests.testFlingToTopWhileOutputStreams` 核。这里不重复。
@MainActor
final class TerminalBottomFollowTests: XCTestCase {
    func testBottomFollowLivesInTheSystemScrollTests() throws {
        throw XCTSkip("旧引擎的 updateScroller（补丁 #17）随引擎一起删了；等价行为见 GhosttySystemScrollJitterTests")
    }
}
