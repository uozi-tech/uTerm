import XCTest
import AppKit
import CodeEditTextView
@testable import uTerm

/// EditorTheme 现为随外观切换的动态 NSColor（深色背景对齐工作区 / 浅 VS Code Light+）。
/// 旧测试断言「钉死编辑器深灰/#CCCCCC」已不成立——改为按外观解析到对应变体。
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

    /// 背景：暗色跟工作区/侧栏基底一致，浅色保留 VS Code Light #FFFFFF。
    func test_editor_background_resolves_dark_and_light() {
        XCTAssertTrue(near(sRGB(EditorTheme.background, .darkAqua), 0x14/255, 0x14/255, 0x14/255), "深 #141414 = 卡面色")
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
        XCTAssertEqual(EditorTheme.textFontName, TerminalSettings.fontName)
        XCTAssertEqual(EditorTheme.textFontSize, CGFloat(TerminalSettings.fontSize))
    }

    func test_editor_uses_fixed_pitch_font() {
        XCTAssertTrue(EditorTheme.textFont().isFixedPitch)
    }

    func test_line_number_gutter_uses_editor_font_size() {
        let controller = CodeEditorController()
        let textView = TextView(
            string: "echo test\n",
            font: EditorTheme.textFont(),
            textColor: EditorTheme.foreground,
            lineHeightMultiplier: 1.4,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            useSystemCursor: false,
            delegate: controller
        )
        let gutter = LineNumberGutter(textView: textView)
        let font = Mirror(reflecting: gutter).children.first { $0.label == "font" }?.value as? NSFont

        guard let font else {
            XCTFail("LineNumberGutter should keep a concrete drawing font")
            return
        }
        XCTAssertEqual(font.pointSize, EditorTheme.textFontSize, accuracy: 0.01)
    }

    func test_cursor_frame_is_clamped_to_font_height_and_centered() {
        let font = EditorTheme.textFont()
        let glyphHeight = ceil(font.ascender - font.descender)
        let frame = CGRect(x: 48, y: 20, width: 1, height: glyphHeight * 1.4)

        let normalized = CodeEditorController.normalizedCursorFrame(frame, font: font)

        XCTAssertEqual(normalized.height, glyphHeight, accuracy: 0.01)
        XCTAssertEqual(normalized.minY, frame.minY + (frame.height - glyphHeight) / 2, accuracy: 0.01)
        XCTAssertEqual(normalized.minX, frame.minX, accuracy: 0.01)
        XCTAssertEqual(normalized.width, CodeEditorController.cursorWidth(for: font), accuracy: 0.01)
    }

    /// caret 不能用库默认的 1pt（Retina 上仅 2 物理像素，浅色下几乎不可见）：
    /// 2pt 起步，随字号放大，封顶 4pt。
    func test_cursor_width_starts_at_two_points_and_scales_with_font() {
        let small = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let normal = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let large = NSFont.monospacedSystemFont(ofSize: 22, weight: .regular)
        let huge = NSFont.monospacedSystemFont(ofSize: 96, weight: .regular)

        XCTAssertEqual(CodeEditorController.cursorWidth(for: small), 2, accuracy: 0.01)
        XCTAssertEqual(CodeEditorController.cursorWidth(for: normal), 2, accuracy: 0.01)
        XCTAssertEqual(CodeEditorController.cursorWidth(for: large), 3, accuracy: 0.01)
        XCTAssertEqual(CodeEditorController.cursorWidth(for: huge), 4, accuracy: 0.01)
    }

    /// 小数 x 上的实心细矩形会被抗锯齿摊成两条半透明边（看着比 1pt 还虚），
    /// 所以要吸附到物理像素网格；scale <= 0 时保持原值。
    func test_cursor_x_snaps_to_backing_pixel_grid() {
        let font = EditorTheme.textFont()
        let frame = CGRect(x: 48.3, y: 20, width: 1, height: 10)

        XCTAssertEqual(CodeEditorController.normalizedCursorFrame(frame, font: font, scale: 2).minX,
                       48.5, accuracy: 0.001)
        XCTAssertEqual(CodeEditorController.normalizedCursorFrame(frame, font: font, scale: 1).minX,
                       48, accuracy: 0.001)
        XCTAssertEqual(CodeEditorController.normalizedCursorFrame(frame, font: font, scale: 0).minX,
                       48.3, accuracy: 0.001)
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
