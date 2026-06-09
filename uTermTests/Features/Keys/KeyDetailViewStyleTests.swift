import XCTest
import SwiftUI
import AppKit
@testable import uTerm

final class KeyDetailViewStyleTests: XCTestCase {
    private func sRGB(_ color: Color, _ appearance: NSAppearance.Name) -> (Double, Double, Double) {
        var out: (Double, Double, Double) = (0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            out = (Double(resolved.redComponent),
                   Double(resolved.greenComponent),
                   Double(resolved.blueComponent))
        }
        return out
    }

    @MainActor
    func testPublicKeyBlockBackgroundFollowsWindowAppearance() {
        let light = sRGB(KeyDetailView.publicKeyBlockBackground, .aqua)
        let dark = sRGB(KeyDetailView.publicKeyBlockBackground, .darkAqua)

        XCTAssertGreaterThan(light.0 + light.1 + light.2, 2.2,
                             "Light mode public-key block should use a light code surface.")
        XCTAssertLessThan(dark.0 + dark.1 + dark.2, 0.6,
                          "Dark mode public-key block should stay on a dark surface.")
    }
}
