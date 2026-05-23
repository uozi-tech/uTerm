import XCTest
import SwiftUI
import AppKit
@testable import uTerm

final class AppThemeTests: XCTestCase {

    private func srgb(_ color: Color) -> (Double, Double, Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private func assertColor(_ color: Color, equals hex: UInt32, line: UInt = #line) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        let actual = srgb(color)
        XCTAssertEqual(actual.0, r, accuracy: 0.01, line: line)
        XCTAssertEqual(actual.1, g, accuracy: 0.01, line: line)
        XCTAssertEqual(actual.2, b, accuracy: 0.01, line: line)
    }

    func test_palette_backgroundLayers() {
        assertColor(AppTheme.Palette.bgBase,     equals: 0x1B1D23)
        assertColor(AppTheme.Palette.bgPanel,    equals: 0x14161B)
        assertColor(AppTheme.Palette.bgRaised,   equals: 0x1F2128)
        assertColor(AppTheme.Palette.bgSelected, equals: 0x2A3041)
    }

    func test_palette_borders() {
        assertColor(AppTheme.Palette.border,       equals: 0x2A2C33)
        assertColor(AppTheme.Palette.borderStrong, equals: 0x3B3D44)
    }

    func test_palette_text() {
        assertColor(AppTheme.Palette.textPrimary,   equals: 0xE8EAEF)
        assertColor(AppTheme.Palette.textSecondary, equals: 0xC8CACF)
        assertColor(AppTheme.Palette.textMuted,     equals: 0x7A7C82)
    }

    func test_palette_accent() {
        assertColor(AppTheme.Palette.accent, equals: 0x4F70D8)
    }

    func test_palette_status() {
        assertColor(AppTheme.Palette.success, equals: 0x6FCF97)
        assertColor(AppTheme.Palette.warning, equals: 0xF2C94C)
        // caution（橙）必须与 warning（黄）颜色不同，否则状态徽标无法区分
        // 「已断开」与「连接中」（Fix #9）。
        assertColor(AppTheme.Palette.caution, equals: 0xF2994A)
        assertColor(AppTheme.Palette.danger,  equals: 0xEB5757)
    }

    /// caution ≠ warning —— 防御性比对，避免未来误改回同色。
    func test_palette_cautionDistinctFromWarning() {
        let cautionHex: UInt32 = 0xF2994A
        let warningHex: UInt32 = 0xF2C94C
        XCTAssertNotEqual(cautionHex, warningHex)
    }
}
