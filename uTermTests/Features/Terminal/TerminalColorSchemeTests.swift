import XCTest
import Foundation
import AppKit
@testable import uTerm

@MainActor
final class TerminalColorSchemeTests: XCTestCase {
    func test_both_schemes_have_16_ansi_colors() {
        for scheme in [TerminalColorScheme.vscodeDark, .vscodeLight] {
            XCTAssertEqual(scheme.ansiColors.count, 16,
                "\(scheme.displayName) 应有 16 色 ANSI palette")
        }
    }

    func test_lightenForBright_pure_black_lightens() {
        let black = TerminalRGB(red: 0, green: 0, blue: 0)
        let bright = TerminalColorScheme.lightenForBright(black)
        let expected = 76  // (0 * 7 + 0xFF * 3) / 10
        XCTAssertTrue(abs(Int(bright.red)   - expected) <= 1)
        XCTAssertTrue(abs(Int(bright.green) - expected) <= 1)
        XCTAssertTrue(abs(Int(bright.blue)  - expected) <= 1)
    }

    func test_lightenForBright_pure_white_stays_white() {
        let white = TerminalRGB(red: 0xFF, green: 0xFF, blue: 0xFF)
        let bright = TerminalColorScheme.lightenForBright(white)
        XCTAssertEqual(bright.red,   0xFF)
        XCTAssertEqual(bright.green, 0xFF)
        XCTAssertEqual(bright.blue,  0xFF)
    }

    /// 浅色下正文要和 Agent 的次要文字拉得开。Claude Code 浅色主题把「Ran 1 shell command」「· 28m 47s」这类次要文字
    /// 画成真彩 #666666；前景原来是 VS Code Light Modern 的 #3B3B3B，两者对比只有 1.95，正文和次要文字看上去差不多
    /// （用户拿 iGhostVT 的纯黑前景对比报的）。要求前景对 #666666 的 WCAG 对比 ≥ 2.5，前景本身对底色 ≥ 15。
    func test_vscode_light_foreground_stands_apart_from_secondary_gray() {
        let scheme = TerminalColorScheme.resolve(dark: false)
        let fg = scheme.foregroundColor.usingColorSpace(.sRGB)!
        let bg = scheme.backgroundColor.usingColorSpace(.sRGB)!
        let secondary = NSColor(srgbRed: 0x66 / 255.0, green: 0x66 / 255.0, blue: 0x66 / 255.0, alpha: 1)
        XCTAssertGreaterThanOrEqual(contrast(fg, secondary), 3.5, "正文与 #666666 次要文字的对比 \(contrast(fg, secondary))")
        XCTAssertGreaterThanOrEqual(contrast(fg, bg), 15, "正文对底色的对比 \(contrast(fg, bg))")
        XCTAssertEqual(scheme.cursorColor.usingColorSpace(.sRGB), fg, "块光标与正文同色")
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func lum(_ c: NSColor) -> Double {
            func lin(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func nsColor(_ c: TerminalRGB) -> NSColor {
        NSColor(srgbRed: CGFloat(c.red) / 255,
                green: CGFloat(c.green) / 255,
                blue: CGFloat(c.blue) / 255,
                alpha: 1)
    }

    /// 浅色方案的 yellow / brightYellow 用 VS Code 官方原值，不再为某种段底
    /// 单独改暗（曾写死 #3F3200，导致深灰段底上的黄起点过暗、被钳成暗橄榄）。
    func test_vscode_light_yellow_uses_official_values() {
        let scheme = TerminalColorScheme.resolve(dark: false)
        XCTAssertEqual(scheme.ansiColors[3].red, 0x94)
        XCTAssertEqual(scheme.ansiColors[3].green, 0x98)
        XCTAssertEqual(scheme.ansiColors[3].blue, 0x00)
        XCTAssertEqual(scheme.ansiColors[11].red, 0xB5)
        XCTAssertEqual(scheme.ansiColors[11].green, 0xBA)
        XCTAssertEqual(scheme.ansiColors[11].blue, 0x00)
    }

    // 原来这里还有两条核「浅色方案的黄经渲染期钳制后可读 / 在深灰段底上被提亮」（旧引擎的本地补丁的 `TerminalContrast`）。
    // 钳制现在在引擎的 shader 里，要读 surface 画出来的像素，挪到了 `TerminalContrastTests`
    // （test_vscode_light_yellow_readable_after_contrast_clamp / …_brightens_on_dark_segment）。
}
