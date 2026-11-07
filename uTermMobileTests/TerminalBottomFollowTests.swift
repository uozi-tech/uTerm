import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// 跟随底部时，滚动视图还在减速 / 回弹，输出不能去抢 contentOffset（SwiftTerm 补丁 #17）。
/// Claude Code 思考时每秒约 10 个 DEC 2026 帧，每帧结束都会走 `updateScroller`：
/// 以前每帧把 offset 硬设回底部，和 UIKit 的回弹动画来回抢，滚到底部时整屏抖。
@MainActor
final class TerminalBottomFollowTests: XCTestCase {
    /// 能假装正在减速的终端：`isDecelerating` 只读，没法让真实的 UIScrollView 停在这个状态里断言。
    private final class CoastingTerminalView: SwiftTerm.TerminalView {
        var coasting = false
        var rowHeight: CGFloat = 0
        override var isDecelerating: Bool { coasting || super.isDecelerating }
        /// 照 UIKit：不带动画地设 offset 会停掉惯性。
        override func setContentOffset(_ offset: CGPoint, animated: Bool) {
            if !animated { coasting = false }
            super.setContentOffset(offset, animated: animated)
        }
    }

    /// 帧取自 Claude Code 跑在 SwiftTerm 里的真实输出（同 `TerminalSynchronizedOutputTests`）：原地重画，不增行。
    private static let claudeFrame = "\u{1B}[?2026h\u{1B}[?25l\u{1B}[2D\u{1B}[3B\r\u{1B}[6A\u{1B}[38;2;215;119;87m*"
        + "\u{1B}[39m\r\r\n\r\n\r\n\r\n\r\n\r\n\u{1B}[2C\u{1B}[3A\u{1B}[?25h\u{1B}[?2026l"

    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func hostedTerminal() throws -> CoastingTerminalView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        window.isHidden = false
        self.window = window
        let view = CoastingTerminalView(frame: window.bounds,
                                        font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        window.addSubview(view)
        view.layoutIfNeeded()
        let rows = view.getTerminal().rows
        view.feed(text: (0..<(rows * 4)).map { "line \($0)\r\n" }.joined())
        let before = view.contentSize.height
        view.feed(text: "last\r\n")
        view.rowHeight = view.contentSize.height - before
        XCTAssertGreaterThan(view.rowHeight, 0)
        view.feed(text: "\u{1B}[3A")
        view.flushPendingDisplay()
        return view
    }

    private func bottom(of view: UIScrollView) -> CGFloat {
        max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
    }

    private func rowHeight(of view: CoastingTerminalView) -> CGFloat { view.rowHeight }

    func testFrameDoesNotFightTheBounceAtTheBottom() throws {
        let view = try hostedTerminal()
        let overshoot = bottom(of: view) + 30
        view.coasting = true
        view.contentOffset.y = overshoot

        view.feed(text: Self.claudeFrame)
        view.flushPendingDisplay()

        XCTAssertEqual(view.contentOffset.y, overshoot, accuracy: 0.5, "回弹还没结束，不能被拽回底部")
    }

    func testFrameDoesNotSnapACoastLandingOnTheBottom() throws {
        let view = try hostedTerminal()
        let landing = bottom(of: view) - rowHeight(of: view) * 0.4
        view.coasting = true
        view.contentOffset.y = landing

        view.feed(text: Self.claudeFrame)
        view.flushPendingDisplay()

        XCTAssertEqual(view.contentOffset.y, landing, accuracy: 0.5, "惯性自己会落到底部，不该提前跳过去")
    }

    func testOutputThatPullsTheTailAwayStillGetsFollowed() throws {
        let view = try hostedTerminal()
        view.coasting = true
        view.contentOffset.y = bottom(of: view)

        view.feed(text: (0..<20).map { "more \($0)\r\n" }.joined())
        view.flushPendingDisplay()

        XCTAssertEqual(view.contentOffset.y, bottom(of: view), accuracy: 0.5, "新输出拉开好几行时要跟上")
    }

    func testFrameStillPinsToTheBottomAtRest() throws {
        let view = try hostedTerminal()
        view.contentOffset.y = bottom(of: view) - rowHeight(of: view) * 0.4

        view.feed(text: Self.claudeFrame)
        view.flushPendingDisplay()

        XCTAssertEqual(view.contentOffset.y, bottom(of: view), accuracy: 0.5)
    }
}
