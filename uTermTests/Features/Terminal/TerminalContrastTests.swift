// 【迁移中，暂未编译】这份用例还依赖 SwiftTerm 或已经删掉的 SwiftTerm 时代类型，等改写到 Ghostty + 影子终端
// （`ShadowTerminal`）上的同一条行为。改写完把这一对 `#if UTERM_LEGACY_SWIFTTERM_TESTS` / `#endif` 去掉。
// 清单与进度见 docs/ghostty-eval/migration-log.md「测试改写」。
#if UTERM_LEGACY_SWIFTTERM_TESTS
import XCTest
import AppKit
import SwiftTerm
@testable import uTerm

/// 渲染期最低对比度（vendored SwiftTerm 补丁，见 vendor/SwiftTerm/UTERM-PATCHES.md）。
/// 远端 prompt / TUI 按深色背景硬编码的 256 色 / 真彩色在浅色背景下不可读，
/// `minimumContrastRatio` 在渲染时把前景色钳制到可读对比度。钳制是保色相的：
/// OKLCH 空间只调明度，色相不动、饱和度仅按色域收缩——彩色不应被洗成黑白灰。
@MainActor
final class TerminalContrastTests: XCTestCase {

    private func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    // MARK: WCAG 对比度计算

    func test_contrast_ratio_black_on_white_is_21() {
        let ratio = TerminalContrast.contrastRatio(srgb(0x000000), srgb(0xFFFFFF))
        XCTAssertEqual(ratio, 21, accuracy: 0.1)
    }

    func test_contrast_ratio_is_symmetric() {
        let a = srgb(0xD7AF87), b = srgb(0xF6F6F3)
        XCTAssertEqual(TerminalContrast.contrastRatio(a, b),
                       TerminalContrast.contrastRatio(b, a),
                       accuracy: 0.001)
    }

    // MARK: 钳制算法

    /// p10k 一类 prompt 的典型场景：256 色 180 (#D7AF87) 按深色背景设计，
    /// 在白底上对比度 ~1.9，钳制后必须达到 4.5。
    func test_ensure_contrast_fixes_dark_designed_color_on_white() {
        let fg = srgb(0xD7AF87), bg = srgb(0xFFFFFF)
        XCTAssertLessThan(TerminalContrast.contrastRatio(fg, bg), 4.5, "前提：原始对比不足")
        let adjusted = TerminalContrast.ensureContrast(fg: fg, bg: bg, ratio: 4.5)
        XCTAssertGreaterThanOrEqual(TerminalContrast.contrastRatio(adjusted, bg), 4.5)
    }

    /// 钳制方向：浅底上的浅色变深，深底上的深色变浅。
    func test_ensure_contrast_moves_toward_correct_pole() {
        let onWhite = TerminalContrast.ensureContrast(fg: srgb(0xCCCCCC), bg: srgb(0xFFFFFF), ratio: 4.5)
        XCTAssertLessThan(TerminalContrast.relativeLuminance(onWhite),
                          TerminalContrast.relativeLuminance(srgb(0xCCCCCC)))

        let onBlack = TerminalContrast.ensureContrast(fg: srgb(0x333333), bg: srgb(0x101012), ratio: 4.5)
        XCTAssertGreaterThan(TerminalContrast.relativeLuminance(onBlack),
                             TerminalContrast.relativeLuminance(srgb(0x333333)))
    }

    /// 回归：中灰段底（#6D6D6D，p10k powerline 常用）上、比段底略暗的前景
    /// （ansi31 路径分隔符 #3D6D7E）必须随段底一起「提亮」，不能因方向取错被压成
    /// 近黑——这正是 `/` 在中灰段上发黑的根因。方向按背景判定（深/中灰一律提亮）。
    func test_ensure_contrast_lightens_near_bg_fg_on_midgray_segment() {
        let fg = srgb(0x3D6D7E), bg = srgb(0x6D6D6D)
        let adjusted = TerminalContrast.ensureContrast(fg: fg, bg: bg, ratio: 4.0)
        XCTAssertGreaterThanOrEqual(TerminalContrast.contrastRatio(adjusted, bg), 3.99)
        XCTAssertGreaterThan(TerminalContrast.relativeLuminance(adjusted),
                             TerminalContrast.relativeLuminance(bg),
                             "中灰段底上的前景应被提亮到比段底更亮，而非压黑")
    }

    /// 已达标的颜色原样返回，不做任何改动。
    func test_ensure_contrast_keeps_compliant_color() {
        let fg = srgb(0x3B3B3B), bg = srgb(0xFFFFFF)
        let adjusted = TerminalContrast.ensureContrast(fg: fg, bg: bg, ratio: 4.5)
        XCTAssertTrue(adjusted === fg, "达标颜色应原样返回")
    }

    /// ratio = 1 即关闭（上游默认行为）。
    func test_ensure_contrast_ratio_one_is_noop() {
        let fg = srgb(0xFFFFFF)
        let adjusted = TerminalContrast.ensureContrast(fg: fg, bg: srgb(0xFFFFFF), ratio: 1)
        XCTAssertTrue(adjusted === fg)
    }

    /// 极端：白底白字 / 黑底黑字也必须钳出可读对比（极点兜底）。
    func test_ensure_contrast_handles_identical_fg_bg() {
        for hex in [UInt32(0xFFFFFF), 0x000000, 0x808080] {
            let adjusted = TerminalContrast.ensureContrast(fg: srgb(hex), bg: srgb(hex), ratio: 4.5)
            XCTAssertGreaterThanOrEqual(TerminalContrast.contrastRatio(adjusted, srgb(hex)), 4.4,
                                        "fg==bg #\(String(hex, radix: 16)) 应钳出可读对比")
        }
    }

    // MARK: 保色相

    /// 白底上的琥珀色被压暗后仍应是「暖色」（R > G > B 且有可感知饱和度），
    /// 不是灰黑——这是与 xterm.js 黑白混色钳制的关键差异。
    func test_ensure_contrast_preserves_hue_on_white() {
        let fg = srgb(0xD7AF87), bg = srgb(0xFFFFFF)
        let adjusted = TerminalContrast.ensureContrast(fg: fg, bg: bg, ratio: 3.0).usingColorSpace(.sRGB)!
        XCTAssertGreaterThanOrEqual(TerminalContrast.contrastRatio(adjusted, bg), 2.99)
        XCTAssertGreaterThan(adjusted.redComponent, adjusted.greenComponent)
        XCTAssertGreaterThan(adjusted.greenComponent, adjusted.blueComponent)
        XCTAssertGreaterThan(adjusted.redComponent - adjusted.blueComponent, 0.08,
                             "钳制后不应被去饱和成灰黑")
    }

    /// 中灰底（p10k 分段底色的典型场景）上的琥珀字：达标的同时必须保持彩色，
    /// 不允许漂白成接近纯白。
    func test_ensure_contrast_on_midgray_keeps_color() {
        let fg = srgb(0xD7AF87), bg = srgb(0x767676)
        XCTAssertLessThan(TerminalContrast.contrastRatio(fg, bg), 3, "前提：原始对比不足")
        let adjusted = TerminalContrast.ensureContrast(fg: fg, bg: bg, ratio: 3.0).usingColorSpace(.sRGB)!
        XCTAssertGreaterThanOrEqual(TerminalContrast.contrastRatio(adjusted, bg), 2.99)
        XCTAssertGreaterThan(adjusted.redComponent - adjusted.blueComponent, 0.05,
                             "中灰底上不应被漂白成白色")
    }

    // MARK: 装饰字形也钳制

    /// 装饰字形（盒线 / 块元素 / powerline）不再豁免——远端 prompt 按深色背景
    /// 硬编码的灰色分隔符在浅底上是不可读的灰块，必须和普通文本一样钳制。
    /// 典型场景：p10k 段分隔用的中灰 (#8A8A8A) 在白底上对比 ~3.1，钳到 4.5 须变深。
    func test_decorative_glyph_color_is_clamped_on_light_background() {
        let sep = srgb(0x8A8A8A), bg = srgb(0xFFFFFF)
        XCTAssertLessThan(TerminalContrast.contrastRatio(sep, bg), 4.5, "前提：原始灰对比不足")
        let adjusted = TerminalContrast.ensureContrast(fg: sep, bg: bg, ratio: 4.5)
        XCTAssertGreaterThanOrEqual(TerminalContrast.contrastRatio(adjusted, bg), 4.5)
        XCTAssertLessThan(TerminalContrast.relativeLuminance(adjusted),
                          TerminalContrast.relativeLuminance(sep), "白底上的灰分隔符应变深可读")
    }

    // MARK: TerminalTheme 接线

    /// apply 必须给深 / 浅两种外观都垫上最低对比度。
    func test_apply_sets_minimum_contrast_ratio() {
        for dark in [true, false] {
            let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            TerminalTheme.apply(to: view, settings: .read(), dark: dark)
            XCTAssertEqual(view.minimumContrastRatio, TerminalColorScheme.minimumContrastRatio,
                           "dark=\(dark) 时 minimumContrastRatio 未生效")
        }
        // 3.0 = WCAG 大字号 / UI 组件 AA 下限（方向按背景判定，深 / 中灰段底统一提亮）
        XCTAssertEqual(TerminalColorScheme.minimumContrastRatio, 3.0)
    }
}
#endif
