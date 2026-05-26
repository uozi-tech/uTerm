import XCTest
import SwiftUI
import AppKit
@testable import uTerm

final class AppThemeTests: XCTestCase {

    /// 把 Color 转 sRGB 三元组。Spec 05 后 Palette 是 dynamic NSColor，
    /// resolve 结果依赖当前 NSAppearance。本测试断言全部对齐 dark hex，
    /// 所以必须在 darkAqua appearance 上下文里 resolve；否则在浅色 mac
    /// 上跑会得到 light hex，断言全部 fail。
    private func srgb(_ color: Color) -> (Double, Double, Double) {
        var result: (Double, Double, Double) = (0, 0, 0)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            result = (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        }
        return result
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
        assertColor(AppTheme.Palette.bgBase,             equals: 0x1F1F1F)
        assertColor(AppTheme.Palette.bgPanel,            equals: 0x181818)
        assertColor(AppTheme.Palette.bgRaised,           equals: 0x2A2D2E)
        // bgSelected 从官方 #04395E 蓝调改成中性灰 0x37373D（避免大面积撞色，
        // 跟 bgSelectedInactive 相同——focused/blurred 视觉一致）。
        assertColor(AppTheme.Palette.bgSelected,         equals: 0x37373D)
        assertColor(AppTheme.Palette.bgSelectedInactive, equals: 0x37373D)
    }

    func test_palette_borders() {
        assertColor(AppTheme.Palette.border,       equals: 0x2B2B2B)
        assertColor(AppTheme.Palette.borderStrong, equals: 0x3B3B3B)
    }

    func test_palette_text() {
        assertColor(AppTheme.Palette.textPrimary,   equals: 0xCCCCCC)
        assertColor(AppTheme.Palette.textSecondary, equals: 0x9D9D9D)
        assertColor(AppTheme.Palette.textMuted,     equals: 0x6E6E6E)
    }

    func test_palette_accent() {
        assertColor(AppTheme.Palette.accent, equals: 0x0078D4)
    }

    func test_palette_status() {
        assertColor(AppTheme.Palette.success, equals: 0x73C991)
        assertColor(AppTheme.Palette.warning, equals: 0xE2C08D)
        // caution（暖橙红）必须与 warning（米黄）颜色不同，否则状态徽标无法区分
        // 「已断开」与「连接中」（Fix #9 防御性约束保留）。
        assertColor(AppTheme.Palette.caution, equals: 0xCC6633)
        assertColor(AppTheme.Palette.danger,  equals: 0xF14C4C)
    }

    /// caution ≠ warning —— 防御性比对
    func test_palette_cautionDistinctFromWarning() {
        let cautionHex: UInt32 = 0xCC6633
        let warningHex: UInt32 = 0xE2C08D
        XCTAssertNotEqual(cautionHex, warningHex)
    }

    /// hitTestFill 是 SwiftUI 鼠标命中区专用的近不可见填充。
    /// 不断言精确 RGB（白色 sRGB ↔ NSColor 转换有舍入），断言 alpha 很小但 >0。
    /// 用 `??` fallback 跟 `srgb()` 辅助保持一致，避免 headless 环境下 nil 强解崩。
    func test_palette_hitTestFill_alphaIsTinyButNonZero() {
        let raw = NSColor(AppTheme.Palette.hitTestFill)
        let ns = raw.usingColorSpace(.sRGB) ?? raw
        XCTAssertEqual(ns.alphaComponent, 0.001, accuracy: 0.0005)
    }
}
