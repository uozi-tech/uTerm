import XCTest
import AppKit
@testable import uTerm

@MainActor
final class TerminalColorSchemeResolveTests: XCTestCase {
    private func luminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB)!
        return 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
    }

    func test_resolve_dark_returns_dark_variant() {
        for id in TerminalColorSchemeID.allCases {
            let dark = TerminalColorScheme.resolve(id, dark: true)
            XCTAssertLessThan(luminance(dark.backgroundColor), 0.4, "\(id) 深色底应暗")
        }
    }

    func test_resolve_light_returns_light_variant() {
        for id in TerminalColorSchemeID.allCases {
            let light = TerminalColorScheme.resolve(id, dark: false)
            XCTAssertGreaterThan(luminance(light.backgroundColor), 0.6, "\(id) 浅色底应亮")
            XCTAssertLessThan(luminance(light.foregroundColor), 0.6, "\(id) 浅色字应深，保证对比")
        }
    }

    func test_resolve_dark_matches_legacy_scheme_for() {
        for id in TerminalColorSchemeID.allCases {
            XCTAssertEqual(TerminalColorScheme.resolve(id, dark: true).displayName,
                           TerminalColorScheme.scheme(for: id).displayName)
        }
    }
}
