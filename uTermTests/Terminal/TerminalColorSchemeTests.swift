import XCTest
import Foundation
import SwiftTerm
@testable import uTerm

@MainActor
final class TerminalColorSchemeTests: XCTestCase {
    private func luminance(_ color: SwiftTerm.Color) -> Double {
        let toLinear: (Double) -> Double = { component in
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let red = toLinear(Double(color.red) / Double(UInt16.max))
        let green = toLinear(Double(color.green) / Double(UInt16.max))
        let blue = toLinear(Double(color.blue) / Double(UInt16.max))
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private func contrastRatio(_ first: SwiftTerm.Color, _ second: SwiftTerm.Color) -> Double {
        let firstLum = luminance(first)
        let secondLum = luminance(second)
        let lighter = max(firstLum, secondLum)
        let darker = min(firstLum, secondLum)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func ansi(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

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

    func test_vscode_light_yellow_prompt_text_has_readable_contrast() {
        let scheme = TerminalColorScheme.resolve(dark: false)
        let terminalBackground = ansi(0xFF, 0xFF, 0xFF)
        let promptSegmentBackground = scheme.ansiColors[15]

        for index in [3, 11] {
            let color = scheme.ansiColors[index]
            XCTAssertGreaterThanOrEqual(
                contrastRatio(color, terminalBackground), 4.5,
                "ANSI \(index) should remain readable on the light terminal background"
            )
            XCTAssertGreaterThanOrEqual(
                contrastRatio(color, promptSegmentBackground), 4.5,
                "ANSI \(index) should remain readable on light prompt segment backgrounds"
            )
        }
    }
}
