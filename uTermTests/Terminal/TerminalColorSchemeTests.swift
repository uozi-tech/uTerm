import XCTest
import SwiftTerm
@testable import uTerm

final class TerminalColorSchemeTests: XCTestCase {
    func test_all_has_5_schemes() {
        XCTAssertEqual(TerminalColorScheme.all.count, 5)
    }

    func test_scheme_for_id_returns_matching_scheme() {
        XCTAssertEqual(TerminalColorScheme.scheme(for: .vscodeDark).id, .vscodeDark)
        XCTAssertEqual(TerminalColorScheme.scheme(for: .tokyoNight).id, .tokyoNight)
        XCTAssertEqual(TerminalColorScheme.scheme(for: .solarized).id, .solarized)
        XCTAssertEqual(TerminalColorScheme.scheme(for: .gruvbox).id,   .gruvbox)
        XCTAssertEqual(TerminalColorScheme.scheme(for: .oneDark).id,   .oneDark)
    }

    func test_each_scheme_has_16_ansi_colors() {
        for scheme in TerminalColorScheme.all {
            XCTAssertEqual(scheme.ansiColors.count, 16,
                "\(scheme.id.rawValue) 应有 16 色 ANSI palette")
        }
    }

    func test_color_scheme_id_rawValues() {
        XCTAssertEqual(TerminalColorSchemeID.vscodeDark.rawValue, "vscode-dark")
        XCTAssertEqual(TerminalColorSchemeID.tokyoNight.rawValue, "tokyonight")
        XCTAssertEqual(TerminalColorSchemeID.solarized.rawValue,  "solarized")
        XCTAssertEqual(TerminalColorSchemeID.gruvbox.rawValue,    "gruvbox")
        XCTAssertEqual(TerminalColorSchemeID.oneDark.rawValue,    "one-dark")
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

    func test_unknown_id_via_invalid_raw_returns_nil() {
        XCTAssertNil(TerminalColorSchemeID(rawValue: "garbage"))
    }
}
