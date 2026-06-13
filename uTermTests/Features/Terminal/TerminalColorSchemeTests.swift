import XCTest
import Foundation
import AppKit
import SwiftTerm
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
        let black = SwiftTerm.Color(red: 0, green: 0, blue: 0)
        let bright = TerminalColorScheme.lightenForBright(black)
        let expected: UInt16 = 19660  // (0 * 7 + 0xFFFF * 3) / 10
        XCTAssertTrue(abs(Int(bright.red)   - Int(expected)) <= 5)
        XCTAssertTrue(abs(Int(bright.green) - Int(expected)) <= 5)
        XCTAssertTrue(abs(Int(bright.blue)  - Int(expected)) <= 5)
    }

    func test_lightenForBright_pure_white_stays_white() {
        let white = SwiftTerm.Color(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF)
        let bright = TerminalColorScheme.lightenForBright(white)
        XCTAssertEqual(bright.red,   0xFFFF)
        XCTAssertEqual(bright.green, 0xFFFF)
        XCTAssertEqual(bright.blue,  0xFFFF)
    }

    private func nsColor(_ c: SwiftTerm.Color) -> NSColor {
        NSColor(srgbRed: CGFloat(c.red) / 65535,
                green: CGFloat(c.green) / 65535,
                blue: CGFloat(c.blue) / 65535,
                alpha: 1)
    }

    /// 浅色方案的 yellow / brightYellow 用 VS Code 官方原值，不再为某种段底
    /// 单独改暗（曾写死 #3F3200，导致深灰段底上的黄起点过暗、被钳成暗橄榄）。
    func test_vscode_light_yellow_uses_official_values() {
        let scheme = TerminalColorScheme.resolve(dark: false)
        XCTAssertEqual(scheme.ansiColors[3].red >> 8, 0x94)
        XCTAssertEqual(scheme.ansiColors[3].green >> 8, 0x98)
        XCTAssertEqual(scheme.ansiColors[3].blue >> 8, 0x00)
        XCTAssertEqual(scheme.ansiColors[11].red >> 8, 0xB5)
        XCTAssertEqual(scheme.ansiColors[11].green >> 8, 0xBA)
        XCTAssertEqual(scheme.ansiColors[11].blue >> 8, 0x00)
    }

    /// 黄字的逐 cell 可读性由渲染期钳制兜底：白底 / 浅灰段底 / 深灰段底
    /// （powerline 常用 ANSI 15 / 8 当段底）上钳后都必须达到最低对比度。
    func test_vscode_light_yellow_readable_after_contrast_clamp() {
        let scheme = TerminalColorScheme.resolve(dark: false)
        let yellow = nsColor(scheme.ansiColors[3])
        let ratio = TerminalColorScheme.minimumContrastRatio
        let backgrounds = [
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),  // 终端白底
            nsColor(scheme.ansiColors[15]),                    // 浅灰段底 #A5A5A5
            nsColor(scheme.ansiColors[8]),                     // 深灰段底 #666666
        ]
        for bg in backgrounds {
            let shown = TerminalContrast.ensureContrast(fg: yellow, bg: bg, ratio: ratio)
            XCTAssertGreaterThanOrEqual(TerminalContrast.contrastRatio(shown, bg), ratio - 0.01)
        }
    }

    /// 2026-06-13 回归：深灰段底上的黄必须往亮处钳（保持「亮字配深底」），
    /// 不允许往暗处修成暗橄榄。
    func test_vscode_light_yellow_brightens_on_dark_segment() {
        let scheme = TerminalColorScheme.resolve(dark: false)
        let yellow = nsColor(scheme.ansiColors[3])
        let darkSegment = nsColor(scheme.ansiColors[8])
        let shown = TerminalContrast.ensureContrast(
            fg: yellow, bg: darkSegment, ratio: TerminalColorScheme.minimumContrastRatio)
        XCTAssertGreaterThan(TerminalContrast.relativeLuminance(shown),
                             TerminalContrast.relativeLuminance(yellow),
                             "深灰段底上的黄应该被提亮而不是压暗")
    }
}
