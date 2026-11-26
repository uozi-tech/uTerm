import CoreGraphics
@testable import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 键盘当触控板（长按空格键 / 长按键盘）挪光标：手指挪几格就发几个方向键（vendor/libghostty-spm 本地补丁 #23）。
/// 用户报的：Claude Code 输入框里长按键盘想调光标位置，光标一格都不动。
@MainActor
final class GhosttyFloatingCursorTests: XCTestCase {

    // MARK: 纯算术

    private let cell = CGSize(width: 8, height: 16)

    func testStepsCountWholeCellsFromTheOrigin() {
        var tracker = TerminalFloatingCursorTracker(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(tracker.move(to: CGPoint(x: 107, y: 115), cellSize: cell) == (0, 0), "不够一格不动")
        XCTAssertTrue(tracker.move(to: CGPoint(x: 125, y: 100), cellSize: cell) == (3, 0))
        XCTAssertTrue(tracker.move(to: CGPoint(x: 131, y: 100), cellSize: cell) == (0, 0), "累计 3.9 格仍是 3 格")
        XCTAssertTrue(tracker.move(to: CGPoint(x: 92, y: 100), cellSize: cell) == (-4, 0), "退回起点左边一格")
        XCTAssertTrue(tracker.move(to: CGPoint(x: 92, y: 134), cellSize: cell) == (0, 2))
        XCTAssertTrue(tracker.move(to: CGPoint(x: 92, y: 84), cellSize: cell) == (0, -3))
    }

    /// 来回抖、慢慢挪：按「从起点该走到第几格」算，不按每步的增量。
    func testSlowDriftStillMovesAndJitterDoesNotAddUp() {
        var tracker = TerminalFloatingCursorTracker(at: .zero)
        var total = 0
        for step in 1 ... 20 { total += tracker.move(to: CGPoint(x: CGFloat(step), y: 0), cellSize: cell).columns }
        XCTAssertEqual(total, 2, "每步 1 pt、共 20 pt = 2 格")
        for _ in 0 ..< 10 {
            total += tracker.move(to: CGPoint(x: 23.9, y: 0), cellSize: cell).columns
            total += tracker.move(to: CGPoint(x: 24.1, y: 0), cellSize: cell).columns
        }
        XCTAssertEqual(total, 3, "在格线上来回抖只算一次")
        XCTAssertTrue(tracker.move(to: .zero, cellSize: .zero) == (0, 0), "格子大小未知时不动")
    }

    // MARK: 真视图

    private func sent(_ host: GhosttyProbeHost) async throws -> String {
        try await Task.sleep(for: .milliseconds(50))
        let bytes = host.bridge.inputLog?.flatMap { [UInt8]($0) } ?? []
        return String(decoding: bytes, as: UTF8.self)
    }

    /// UIKit 调的三个 UITextInput 方法：手指横着挪发 ← / →、竖着挪发 ↑ / ↓；组字期间不动（光标归输入法）。
    func testFloatingCursorSendsArrowKeys() async throws {
        let host = try GhosttyProbeHost()
        defer { host.close() }
        host.window.makeKey()
        try await host.waitUntilReady()
        XCTAssertTrue(host.view.becomeFirstResponder())
        let metrics = try XCTUnwrap(host.view.surface?.size())
        let scale = host.view.resolvedDisplayScale()
        let w = CGFloat(metrics.cellWidthPixels) / scale, h = CGFloat(metrics.cellHeightPixels) / scale
        let origin = CGPoint(x: 120, y: 80)
        let esc = "\u{1B}"

        host.bridge.inputLog = []
        host.view.beginFloatingCursor(at: origin)
        host.view.updateFloatingCursor(at: CGPoint(x: origin.x + 3.5 * w, y: origin.y))
        var bytes = try await sent(host)
        XCTAssertEqual(bytes, String(repeating: "\(esc)[C", count: 3))

        host.bridge.inputLog = []
        host.view.updateFloatingCursor(at: CGPoint(x: origin.x - 1.5 * w, y: origin.y + 1.2 * h))
        bytes = try await sent(host)
        XCTAssertEqual(bytes, String(repeating: "\(esc)[D", count: 4) + "\(esc)[B")
        host.view.endFloatingCursor()

        // 组字中：这次拖动整个不发键。
        host.view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        host.bridge.inputLog = []
        host.view.beginFloatingCursor(at: origin)
        host.view.updateFloatingCursor(at: CGPoint(x: origin.x + 5 * w, y: origin.y))
        host.view.endFloatingCursor()
        bytes = try await sent(host)
        XCTAssertEqual(bytes, "", "组字期间不挪光标")
        host.view.unmarkText()
    }
}
