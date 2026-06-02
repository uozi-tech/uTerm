import XCTest
@testable import uTerm

@MainActor
final class TerminalFontTests: XCTestCase {
    func test_allCases_count_and_order() {
        XCTAssertEqual(TerminalFont.allCases, [.menlo, .sfMono, .monaco])
    }

    func test_rawValues_match_NSFont_names() {
        XCTAssertEqual(TerminalFont.menlo.rawValue,  "Menlo")
        XCTAssertEqual(TerminalFont.sfMono.rawValue, "SF Mono")
        XCTAssertEqual(TerminalFont.monaco.rawValue, "Monaco")
    }

    func test_displayName_equals_rawValue() {
        for f in TerminalFont.allCases {
            XCTAssertEqual(f.displayName, f.rawValue)
        }
    }

    func test_id_equals_rawValue() {
        XCTAssertEqual(TerminalFont.menlo.id, "Menlo")
    }

    func test_init_from_unknown_returns_nil() {
        XCTAssertNil(TerminalFont(rawValue: "Comic Sans"))
    }
}
