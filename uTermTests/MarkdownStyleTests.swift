import XCTest
import SwiftUI
import AppKit
@testable import uTerm

final class MarkdownStyleTests: XCTestCase {

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
    func test_chatCodeBlockBackground_resolvesForLightAndDarkAppearance() {
        let light = sRGB(MarkdownStyle.chat.codeBlockBackground, .aqua)
        let dark = sRGB(MarkdownStyle.chat.codeBlockBackground, .darkAqua)

        XCTAssertGreaterThan(light.0 + light.1 + light.2, 2.2,
                             "Light mode chat code blocks should use a light surface.")
        XCTAssertLessThan(dark.0 + dark.1 + dark.2, 0.6,
                          "Dark mode chat code blocks should keep a dark surface.")
    }
}
