import XCTest
import AppKit
@testable import uTerm

final class WorkspaceThemeTests: XCTestCase {
    private func srgb(_ color: NSColor, _ appearance: NSAppearance.Name) -> (Double, Double, Double) {
        var out: (Double, Double, Double) = (0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let ns = color.usingColorSpace(.sRGB)!
            out = (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        }
        return out
    }

    private func near(_ a: (Double, Double, Double), _ r: Double, _ g: Double, _ b: Double) -> Bool {
        abs(a.0 - r) < 0.01 && abs(a.1 - g) < 0.01 && abs(a.2 - b) < 0.01
    }

    func test_bgNSColor_resolves_dark_and_light() {
        XCTAssertTrue(near(srgb(WS.bgNSColor, .darkAqua), 0, 0, 0), "dark = #000000")
        XCTAssertTrue(near(srgb(WS.bgNSColor, .aqua), 1, 1, 1), "light = #FFFFFF")
    }

    func test_panelNSColor_resolves_dark_and_light() {
        XCTAssertTrue(near(srgb(WS.panelNSColor, .darkAqua), 20/255, 20/255, 20/255), "dark = #141414")
        XCTAssertTrue(near(srgb(WS.panelNSColor, .aqua), 1, 1, 1), "light = #FFFFFF")
    }

    /// 分区方案 v3 的窗口画布 = `UD.pageBg`：AppKit 钉色必须与 SwiftUI 画布同值，
    /// 否则窗口缩放瞬间 / 标题栏拖动手柄露出一条色差。
    func test_canvasNSColor_matches_pageBg() {
        XCTAssertTrue(near(srgb(WS.canvasNSColor, .darkAqua), 0, 0, 0), "dark = #000000")
        XCTAssertTrue(near(srgb(WS.canvasNSColor, .aqua), 245/255, 245/255, 245/255), "light = #F5F5F5")
    }
}
