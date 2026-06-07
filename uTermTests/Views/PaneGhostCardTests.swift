import XCTest
import AppKit
@testable import uTerm

/// `PaneGhostCard` 在独立 `NSPanel` 渲染，拿不到 SwiftUI `@Environment(\.colorScheme)`，
/// 故背景须按 app 外观解析终端配色（修浅色下幽灵仍恒深的 bug）。配色已固定 VS Code
/// 家族，只随外观切深 / 浅。这里测纯解析逻辑 `terminalBackgroundColor(dark:)`；
/// 外观→dark 的 `NSApp.effectiveAppearance` 读取留在视图体里（全局态，不单测）。
@MainActor
final class PaneGhostCardTests: XCTestCase {
    private func assertRGB(_ color: NSColor, _ r: Int, _ g: Int, _ b: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
        let n = color.usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(n.redComponent),   Double(r) / 255, accuracy: 0.01, "red",   file: file, line: line)
        XCTAssertEqual(Double(n.greenComponent), Double(g) / 255, accuracy: 0.01, "green", file: file, line: line)
        XCTAssertEqual(Double(n.blueComponent),  Double(b) / 255, accuracy: 0.01, "blue",  file: file, line: line)
    }

    /// bug 回归：浅色下幽灵不能再用钉死的深色背景，应取 VS Code Light 背景（纯白）。
    func test_lightMode_uses_light_background_not_dark_constant() {
        let bg = PaneGhostCard.terminalBackgroundColor(dark: false)
        assertRGB(bg, 0xFF, 0xFF, 0xFF)
        let srgb = bg.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(Double(srgb.redComponent), 0.5, "浅色背景不应是深色背景")
    }

    /// 深色下取工作区/侧栏基底 #101012。
    func test_darkMode_uses_dark_background() {
        let bg = PaneGhostCard.terminalBackgroundColor(dark: true)
        assertRGB(bg, 0x10, 0x10, 0x12)
    }
}
