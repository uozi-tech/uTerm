import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// 用户报的：手机上点终端反应慢。上游的轻点要等「这是不是双击、三击」判定完（系统的双击间隔，约 0.3 秒）才弹键盘、
/// 才把点击报给程序（Claude Code 这类接管鼠标的），每一下都慢半拍。现在轻点抬手就生效，双击 / 三击照旧选词 / 选行。
///
/// 真的合成触摸（`SyntheticFinger`），走 UIKit 自己的轻点手势，量的是抬手到生效隔了多久。
@MainActor
final class GhosttyTapLatencyTests: XCTestCase {
    /// 抬手之后多久之内算「当场」：比系统的双击间隔短得多，又给主线程留出几帧的余量。
    private static let immediate = 0.12

    private var host: GhosttyProbeHost!
    private var finger: SyntheticFinger!

    override func setUp() async throws {
        try await super.setUp()
        host = try GhosttyProbeHost(size: CGSize(width: 393, height: 600), keepsBridgeDelegate: true)
        host.window.removeGestureRecognizer(host.touchWatch)
        try await host.waitUntilReady()
        host.window.makeKey()
        finger = try SyntheticFinger(window: host.window)
        _ = host.view.resignFirstResponder()
        host.view.uTermClearSelection(onlyIfBlank: false)
        // 上一条用例的轻点不能和这一条的第一下凑成双击。
        try await Task.sleep(for: .milliseconds(600))
    }

    override func tearDown() async throws {
        _ = host?.view.resignFirstResponder()
        host?.close()
        host = nil
        finger = nil
        try await super.tearDown()
    }

    private func point(col: Int, row: Int) -> CGPoint {
        let cell = CGSize(width: host.view.bounds.width / CGFloat(max(host.grid.cols, 1)),
                          height: host.view.bounds.height / CGFloat(max(host.grid.rows, 1)))
        return host.view.convert(CGPoint(x: cell.width * (CGFloat(col) + 0.5), y: cell.height * (CGFloat(row) + 0.5)),
                                 to: host.window)
    }

    private func show(_ text: String) async throws {
        host.feedAndWait("\u{1B}[H\u{1B}[2J\(text)\r\n")
        try await Task.sleep(for: .milliseconds(150))
    }

    /// 按下、停 40 ms、抬起；返回抬手的时刻。
    @discardableResult
    private func tap(at point: CGPoint, tapCount: Int = 1) async throws -> CFTimeInterval {
        try finger.down(at: point, tapCount: tapCount)
        try await Task.sleep(for: .milliseconds(40))
        try finger.up()
        return CACurrentMediaTime()
    }

    /// 等到 `condition` 成立，返回从 `since` 起过了多久；`limit` 秒内没成立返回 nil。
    private func elapsed(since: CFTimeInterval, limit: Double = 1, until condition: () -> Bool) async throws -> Double? {
        while CACurrentMediaTime() - since < limit {
            if condition() { return CACurrentMediaTime() - since }
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition() ? CACurrentMediaTime() - since : nil
    }

    private var sentText: String {
        (host.bridge.inputLog ?? []).map { String(decoding: $0, as: UTF8.self) }.joined()
    }

    /// 报给程序的左键按下（SGR 1006：`ESC [ < 0 ; 列 ; 行 M`，松开是小写 m）。
    private func clicks(in text: String) -> Int {
        text.matches(of: /\x1B\[<0;\d+;\d+M/).count
    }

    func testTapRaisesTheKeyboardAtOnce() async throws {
        try await show("hello world")
        XCTAssertFalse(host.view.isFirstResponder)
        let upAt = try await tap(at: point(col: 2, row: 3))
        let after = try await elapsed(since: upAt) { host.view.isFirstResponder }
        let seconds = try XCTUnwrap(after, "轻点之后一直没要键盘")
        XCTAssertLessThan(seconds, Self.immediate, String(format: "抬手 %.0f ms 后才要键盘", seconds * 1000))
    }

    /// Claude Code 这类接管了鼠标的程序：点击抬手就报过去。
    func testTapReachesAMouseCapturingProgramAtOnce() async throws {
        try await show("\u{1B}[?1000h\u{1B}[?1006hmenu item")
        defer { host.feedAndWait("\u{1B}[?1006l\u{1B}[?1000l") }
        host.bridge.inputLog = []
        let upAt = try await tap(at: point(col: 2, row: 0))
        let after = try await elapsed(since: upAt) { clicks(in: sentText) > 0 }
        let seconds = try XCTUnwrap(after, "点击没报给程序：\(sentText.debugDescription)")
        XCTAssertLessThan(seconds, Self.immediate, String(format: "抬手 %.0f ms 后才报点击", seconds * 1000))
    }

    /// 双击照旧选词：第二下只选词，不再当一次点击报给程序。
    func testDoubleTapStillSelectsAWordAndClicksOnce() async throws {
        try await show("\u{1B}[?1000h\u{1B}[?1006hhello world")
        defer { host.feedAndWait("\u{1B}[?1006l\u{1B}[?1000l") }
        host.bridge.inputLog = []
        let at = point(col: 8, row: 0)
        try await tap(at: at)
        try await Task.sleep(for: .milliseconds(80))
        let upAt = try await tap(at: at, tapCount: 2)
        let selected = try await elapsed(since: upAt) { host.view.uTermTouchSelectionText != nil }
        XCTAssertNotNil(selected, "双击没选出词")
        XCTAssertEqual(host.view.uTermTouchSelectionText, "world")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(clicks(in: sentText), 1, "双击只有第一下是点击：\(sentText.debugDescription)")
    }

    /// 三击照旧选整行。
    func testTripleTapStillSelectsTheRow() async throws {
        try await show("alpha beta gamma")
        let at = point(col: 7, row: 0)
        try await tap(at: at)
        try await Task.sleep(for: .milliseconds(60))
        try await tap(at: at, tapCount: 2)
        try await Task.sleep(for: .milliseconds(60))
        let upAt = try await tap(at: at, tapCount: 3)
        _ = try await elapsed(since: upAt) { host.view.uTermTouchSelectionText?.contains("gamma") == true }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(host.view.uTermTouchSelectionText?.trimmingCharacters(in: .whitespaces), "alpha beta gamma")
    }
}
