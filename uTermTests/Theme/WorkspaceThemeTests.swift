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
        XCTAssertTrue(near(srgb(WS.bgNSColor, .darkAqua), 16/255, 16/255, 18/255), "dark = #101012")
        XCTAssertTrue(near(srgb(WS.bgNSColor, .aqua), 1, 1, 1), "light = #FFFFFF")
    }

    func test_panelNSColor_resolves_dark_and_light() {
        XCTAssertTrue(near(srgb(WS.panelNSColor, .darkAqua), 23/255, 23/255, 26/255), "dark = #17171A")
        XCTAssertTrue(near(srgb(WS.panelNSColor, .aqua), 0xF6/255, 0xF6/255, 0xF3/255), "light = #F6F6F3")
    }
}
