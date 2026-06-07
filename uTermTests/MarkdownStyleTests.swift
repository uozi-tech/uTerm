import XCTest
import SwiftUI
import AppKit
@testable import uTerm

final class MarkdownStyleTests: XCTestCase {

    private func sRGB(_ color: Color, _ appearance: NSAppearance.Name) -> (Double, Double, Double) {
        let rgba = sRGBA(color, appearance)
        let base = appearance == .darkAqua ? (0.0, 0.0, 0.0) : (1.0, 1.0, 1.0)
        return (rgba.0 * rgba.3 + base.0 * (1 - rgba.3),
                rgba.1 * rgba.3 + base.1 * (1 - rgba.3),
                rgba.2 * rgba.3 + base.2 * (1 - rgba.3))
    }

    private func sRGBA(_ color: Color, _ appearance: NSAppearance.Name) -> (Double, Double, Double, Double) {
        var out: (Double, Double, Double, Double) = (0, 0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            out = (Double(resolved.redComponent),
                   Double(resolved.greenComponent),
                   Double(resolved.blueComponent),
                   Double(resolved.alphaComponent))
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

    @MainActor
    func test_previewBodyColor_usesOpaquePrimaryTextForReadability() {
        let light = sRGBA(MarkdownStyle.preview.bodyColor, .aqua)
        let dark = sRGBA(MarkdownStyle.preview.bodyColor, .darkAqua)

        XCTAssertEqual(light.3, 1, accuracy: 0.001,
                       "Light preview body text should not use muted alpha text.")
        XCTAssertEqual(dark.3, 1, accuracy: 0.001,
                       "Dark preview body text should not use muted alpha text.")
    }
}
