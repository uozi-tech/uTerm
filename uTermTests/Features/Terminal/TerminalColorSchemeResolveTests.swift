import XCTest
import AppKit
@testable import uTerm

@MainActor
final class TerminalColorSchemeResolveTests: XCTestCase {
    private func luminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB)!
        return 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
    }

    func test_resolve_dark_returns_dark_variant() {
        let dark = TerminalColorScheme.resolve(dark: true)
        XCTAssertEqual(dark.displayName, TerminalColorScheme.vscodeDark.displayName)
        XCTAssertLessThan(luminance(dark.backgroundColor), 0.4, "深色底应暗")
    }

    /// VS Code Dark 终端底 = 终端凹槽底 `UD.termBg` 暗夜值 #000000（分区方案 v3 配色：
    /// 原先对齐旧工作区侧栏的 #101012，随本轮配色改成 #000 后同步）。
    func test_resolve_dark_background_matches_workspace_sidebar_background() {
        let n = TerminalColorScheme.resolve(dark: true).backgroundColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(n.redComponent), 0, accuracy: 0.01)
        XCTAssertEqual(Double(n.greenComponent), 0, accuracy: 0.01)
        XCTAssertEqual(Double(n.blueComponent), 0, accuracy: 0.01)
    }

    func test_resolve_light_returns_light_variant() {
        let light = TerminalColorScheme.resolve(dark: false)
        XCTAssertEqual(light.displayName, TerminalColorScheme.vscodeLight.displayName)
        XCTAssertGreaterThan(luminance(light.backgroundColor), 0.6, "浅色底应亮")
        XCTAssertLessThan(luminance(light.foregroundColor), 0.6, "浅色字应深，保证对比")
    }
}
