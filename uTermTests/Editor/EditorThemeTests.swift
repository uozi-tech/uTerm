import XCTest
import AppKit
@testable import uTerm

final class EditorThemeTests: XCTestCase {

    private func sRGB(_ c: NSColor) -> (Double, Double, Double) {
        let n = c.usingColorSpace(.sRGB) ?? c
        return (Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent))
    }

    /// 编辑器背景钉死 VS Code Dark #1F1F1F —— 与 app 主题脱钩。
    func test_editor_background_pinned_1F1F1F() {
        let (r, g, b) = sRGB(EditorTheme.background)
        XCTAssertEqual(r, Double(0x1F)/255, accuracy: 0.01)
        XCTAssertEqual(g, Double(0x1F)/255, accuracy: 0.01)
        XCTAssertEqual(b, Double(0x1F)/255, accuracy: 0.01)
    }

    /// 编辑器默认文字钉死 VS Code Dark #CCCCCC。
    func test_editor_foreground_pinned_CCCCCC() {
        let (r, g, b) = sRGB(EditorTheme.foreground)
        XCTAssertEqual(r, Double(0xCC)/255, accuracy: 0.01)
        XCTAssertEqual(g, Double(0xCC)/255, accuracy: 0.01)
        XCTAssertEqual(b, Double(0xCC)/255, accuracy: 0.01)
    }
}
