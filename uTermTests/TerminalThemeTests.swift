import XCTest
import AppKit
import SwiftTerm
@testable import uTerm

@MainActor
final class TerminalThemeTests: XCTestCase {

    /// uTerm 是交互式终端，光标必须可见。早先从 uService 移植过来的
    /// `hideInputCursor` 把 caretColor 抹成 `.clear`，导致输入时看不到光标。
    /// 现在 `apply(...)` 必须保留 SwiftTerm 的默认光标（非清空色）。
    func testApplyKeepsCaretVisible() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalTheme.apply(to: view, settings: .read(), dark: true)
        XCTAssertNotEqual(view.caretColor, .clear, "光标颜色不应被清空")
    }

    func testApplyUsesFixedPitchFont() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalTheme.apply(to: view, settings: .read(), dark: true)
        XCTAssertTrue(view.font.isFixedPitch)
    }

    /// 终端容器兜底背景跟工作区/侧栏基底一致，避免 SwiftTerm 初始层露出不同深色。
    func test_terminal_background_matches_workspace_sidebar_background() {
        let n = TerminalTheme.backgroundColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(n.redComponent), 16/255, accuracy: 0.01)
        XCTAssertEqual(Double(n.greenComponent), 16/255, accuracy: 0.01)
        XCTAssertEqual(Double(n.blueComponent), 18/255, accuracy: 0.01)
    }
}
