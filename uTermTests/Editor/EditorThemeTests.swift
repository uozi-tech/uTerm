import XCTest
import AppKit
@testable import uTerm

/// EditorTheme 现为随外观切换的动态 NSColor（深 VS Code Dark / 浅 VS Code Light+）。
/// 旧测试断言「钉死 #1F1F1F/#CCCCCC」已不成立——改为按外观解析到对应变体。
@MainActor
final class EditorThemeTests: XCTestCase {

    /// 在指定外观下把动态 NSColor 解析成 sRGB 三元组。
    private func sRGB(_ c: NSColor, _ appearance: NSAppearance.Name) -> (Double, Double, Double) {
        var out: (Double, Double, Double) = (0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let n = c.usingColorSpace(.sRGB) ?? c
            out = (Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent))
        }
        return out
    }
    private func near(_ a: (Double, Double, Double), _ r: Double, _ g: Double, _ b: Double) -> Bool {
        abs(a.0 - r) < 0.01 && abs(a.1 - g) < 0.01 && abs(a.2 - b) < 0.01
    }
    private func sRGBA(_ c: NSColor, _ appearance: NSAppearance.Name) -> (Double, Double, Double, Double) {
        var out: (Double, Double, Double, Double) = (0, 0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let n = c.usingColorSpace(.sRGB) ?? c
            out = (Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), Double(n.alphaComponent))
        }
        return out
    }
    private func near(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double)) -> Bool {
        abs(a.0 - b.0) < 0.01 &&
        abs(a.1 - b.1) < 0.01 &&
        abs(a.2 - b.2) < 0.01 &&
        abs(a.3 - b.3) < 0.01
    }

    /// 背景：深 VS Code Dark #1F1F1F / 浅 VS Code Light #FFFFFF。
    func test_editor_background_resolves_dark_and_light() {
        XCTAssertTrue(near(sRGB(EditorTheme.background, .darkAqua), Double(0x1F)/255, Double(0x1F)/255, Double(0x1F)/255), "深 #1F1F1F")
        XCTAssertTrue(near(sRGB(EditorTheme.background, .aqua), 1, 1, 1), "浅 #FFFFFF")
    }

    /// 前景对比翻转：深色底浅字 #CCCCCC / 浅色底深字 #3B3B3B。
    func test_editor_foreground_resolves_dark_and_light() {
        XCTAssertTrue(near(sRGB(EditorTheme.foreground, .darkAqua), Double(0xCC)/255, Double(0xCC)/255, Double(0xCC)/255), "深 #CCCCCC")
        XCTAssertTrue(near(sRGB(EditorTheme.foreground, .aqua), Double(0x3B)/255, Double(0x3B)/255, Double(0x3B)/255), "浅 #3B3B3B")
    }

    /// 语法色按外观解析：keyword 深 = #C586C0(紫) / 浅 = #0000FF(蓝)。
    func test_keyword_color_resolves_per_appearance() {
        XCTAssertTrue(near(sRGB(EditorTheme.color(for: "keyword"), .darkAqua), Double(0xC5)/255, Double(0x86)/255, Double(0xC0)/255), "深 keyword 紫")
        XCTAssertTrue(near(sRGB(EditorTheme.color(for: "keyword"), .aqua), 0, 0, 1), "浅 keyword 蓝 #0000FF")
    }

    func test_editor_and_terminal_share_default_font_settings() {
        let terminalDefaults = TerminalSettings.read(from: UserDefaults(suiteName: "EditorThemeTests-\(UUID().uuidString)")!)
        XCTAssertEqual(EditorTheme.textFontName, terminalDefaults.fontName)
        XCTAssertEqual(EditorTheme.textFontSize, CGFloat(terminalDefaults.fontSize))
    }

    func test_editor_and_terminal_share_selection_background_colors() {
        XCTAssertTrue(
            near(sRGBA(EditorTheme.selectionBg, .darkAqua),
                 sRGBA(TerminalTheme.normalSelectionColor, .darkAqua)),
            "dark selection should use the same resolved RGBA"
        )
        XCTAssertTrue(
            near(sRGBA(EditorTheme.selectionBg, .aqua),
                 sRGBA(TerminalTheme.lightSelectionColor, .aqua)),
            "light selection should use the same resolved RGBA"
        )
    }
}
