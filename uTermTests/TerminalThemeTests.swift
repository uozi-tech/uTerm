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
        TerminalTheme.apply(to: view, fontSize: 13, scrollback: 1000)
        XCTAssertNotEqual(view.caretColor, .clear, "光标颜色不应被清空")
    }
}
