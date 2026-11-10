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

    // 原来这里还有两条核「浅色方案的黄经渲染期钳制后可读 / 在深灰段底上被提亮」（SwiftTerm 补丁的 `TerminalContrast`）。
    // 钳制现在在引擎的 shader 里，要读 surface 画出来的像素，挪到了 `TerminalContrastTests`
    // （test_vscode_light_yellow_readable_after_contrast_clamp / …_brightens_on_dark_segment）。
}
