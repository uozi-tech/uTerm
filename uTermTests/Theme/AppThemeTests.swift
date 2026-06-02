import XCTest
import SwiftUI
import AppKit
@testable import uTerm

final class AppThemeTests: XCTestCase {

    /// 在 darkAqua 下把 Color resolve 成 sRGB 三元组（系统语义色依赖当前 appearance）。
    private func srgb(_ color: Color) -> (Double, Double, Double) {
        var result: (Double, Double, Double) = (0, 0, 0)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            result = (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        }
        return result
    }

    /// 状态色映射系统 green/yellow/orange/red —— 必须两两可区分，
    /// 尤其 caution(orange) ≠ warning(yellow)（状态徽标区分「已断开」与「连接中」）。
    func test_status_colors_distinct() {
        let s = srgb(AppTheme.Palette.success)
        let w = srgb(AppTheme.Palette.warning)
        let c = srgb(AppTheme.Palette.caution)
        let d = srgb(AppTheme.Palette.danger)
        func eq(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Bool {
            abs(a.0 - b.0) < 0.02 && abs(a.1 - b.1) < 0.02 && abs(a.2 - b.2) < 0.02
        }
        XCTAssertFalse(eq(s, w) || eq(s, c) || eq(s, d) || eq(w, c) || eq(w, d) || eq(c, d),
                       "状态色必须两两不同")
    }

    /// accent 跟随系统强调色（controlAccentColor）。
    func test_accent_follows_system_control_accent() {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let accent = NSColor(AppTheme.Palette.accent).usingColorSpace(.sRGB)!
            let system = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
            XCTAssertEqual(Double(accent.redComponent),   Double(system.redComponent),   accuracy: 0.02)
            XCTAssertEqual(Double(accent.greenComponent), Double(system.greenComponent), accuracy: 0.02)
            XCTAssertEqual(Double(accent.blueComponent),  Double(system.blueComponent),  accuracy: 0.02)
        }
    }

    /// 回归：textPrimary 不再是旧写死 #CCCCCC（已改系统 label 色）。
    func test_chrome_text_no_longer_hardcoded() {
        let tp = srgb(AppTheme.Palette.textPrimary)
        let old = (Double(0xCC)/255, Double(0xCC)/255, Double(0xCC)/255)
        let same = abs(tp.0 - old.0) < 0.01 && abs(tp.1 - old.1) < 0.01 && abs(tp.2 - old.2) < 0.01
        XCTAssertFalse(same, "textPrimary 应已改为系统 label 色")
    }

    /// hitTestFill 不变：近不可见命中区填充。
    func test_hitTestFill_alphaIsTinyButNonZero() {
        let raw = NSColor(AppTheme.Palette.hitTestFill)
        let ns = raw.usingColorSpace(.sRGB) ?? raw
        XCTAssertEqual(ns.alphaComponent, 0.001, accuracy: 0.0005)
    }
}
