import XCTest
import AppKit
@testable import uTerm

@MainActor
final class CodeHighlighterTests: XCTestCase {

    func test_unknownLanguage_returnsPlainText() {
        let s = CodeHighlighter.attributed(code: "foo bar", language: "no-such-lang")
        XCTAssertEqual(String(s.characters), "foo bar")
    }

    func test_nilLanguage_returnsPlainText() {
        let s = CodeHighlighter.attributed(code: "x = 1", language: nil)
        XCTAssertEqual(String(s.characters), "x = 1")
    }

    func test_knownLanguage_preservesText() {
        let code = "let x = 1"
        let s = CodeHighlighter.attributed(code: code, language: "swift")
        XCTAssertEqual(String(s.characters), code)
    }
}
