import XCTest
import AppKit
@testable import uTerm

/// `PaneGhostCard` 在独立 `NSPanel` 渲染，拿不到 SwiftUI `@Environment(\.colorScheme)`，
/// 故背景须按 app 外观 + 所选终端配色解析（修浅色下幽灵仍恒深的 bug）。
/// 这里测纯解析逻辑 `terminalBackgroundColor(dark:defaults:)`；外观→dark 的
/// `NSApp.effectiveAppearance` 读取留在视图体里（全局态，不单测）。
@MainActor
final class PaneGhostCardTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PaneGhostCardTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func assertRGB(_ color: NSColor, _ r: Int, _ g: Int, _ b: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
        let n = color.usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(n.redComponent),   Double(r) / 255, accuracy: 0.01, "red",   file: file, line: line)
        XCTAssertEqual(Double(n.greenComponent), Double(g) / 255, accuracy: 0.01, "green", file: file, line: line)
        XCTAssertEqual(Double(n.blueComponent),  Double(b) / 255, accuracy: 0.01, "blue",  file: file, line: line)
    }

    /// bug 回归：浅色下幽灵不能再用钉死的 #1E1E1E，应取所选方案的浅色背景（VS Code Light = 纯白）。
    func test_lightMode_default_uses_light_background_not_dark_constant() {
        let bg = PaneGhostCard.terminalBackgroundColor(dark: false, defaults: defaults)
        assertRGB(bg, 0xFF, 0xFF, 0xFF)
        let srgb = bg.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(Double(srgb.redComponent), 0.5, "浅色背景不应是深 #1E1E1E")
    }

    /// 深色下取所选方案的深色背景（默认 VS Code Dark #1E1E1E）。
    func test_darkMode_default_uses_dark_background() {
        let bg = PaneGhostCard.terminalBackgroundColor(dark: true, defaults: defaults)
        assertRGB(bg, 0x1E, 0x1E, 0x1E)
    }

    /// 尊重所选方案：tokyonight 浅色 → Tokyo Night Day 背景 #E1E2E7。
    func test_lightMode_respects_selected_scheme() {
        defaults.set("tokyonight", forKey: "terminalColorScheme")
        let bg = PaneGhostCard.terminalBackgroundColor(dark: false, defaults: defaults)
        assertRGB(bg, 0xE1, 0xE2, 0xE7)
    }

    /// 尊重所选方案：tokyonight 深色 → Tokyo Night 背景 #1A1B26。
    func test_darkMode_respects_selected_scheme() {
        defaults.set("tokyonight", forKey: "terminalColorScheme")
        let bg = PaneGhostCard.terminalBackgroundColor(dark: true, defaults: defaults)
        assertRGB(bg, 0x1A, 0x1B, 0x26)
    }

    /// 损坏的 raw 值回退到默认 vscodeDark 家族（沿用 TerminalSettings.read 的 fallback）。
    func test_corrupt_scheme_falls_back_to_vscode_family() {
        defaults.set("garbage", forKey: "terminalColorScheme")
        assertRGB(PaneGhostCard.terminalBackgroundColor(dark: true,  defaults: defaults), 0x1E, 0x1E, 0x1E)
        assertRGB(PaneGhostCard.terminalBackgroundColor(dark: false, defaults: defaults), 0xFF, 0xFF, 0xFF)
    }
}
