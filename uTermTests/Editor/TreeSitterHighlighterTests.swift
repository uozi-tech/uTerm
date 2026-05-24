// uTermTests/Editor/TreeSitterHighlighterTests.swift
import XCTest
import SwiftTreeSitter
import TreeSitterGo
@testable import uTerm

@MainActor
final class TreeSitterHighlighterTests: XCTestCase {

    private func makeGoHighlighter() -> TreeSitterHighlighter {
        let lang = Language(language: tree_sitter_go())
        // Minimal inline query covering the tokens our assertions check.
        // debounceMs: 0 → synchronous reparse for test determinism.
        let query = """
        (comment) @comment
        ["func" "var" "const" "return" "if" "else" "for" "package" "import"] @keyword
        (int_literal) @number
        """
        return TreeSitterHighlighter(language: lang,
                                     highlightsQueryText: query,
                                     debounceMs: 0)
    }

    func test_go_simpleSnippet_yieldsKeywordAndNumber() {
        let h = makeGoHighlighter()
        var captured: [(NSRange, NSColor)] = []
        h.initialHighlight(text: "package main") { captured = $0 }
        XCTAssertFalse(captured.isEmpty, "Expected at least one highlight")
        XCTAssertTrue(captured.contains(where: { $0.1 == EditorTheme.synKeyword }),
                      "Expected a keyword color for 'package'")
    }

    func test_initialHighlight_returnsNonEmptyForKnownTokens() {
        let h = makeGoHighlighter()
        var captured: [(NSRange, NSColor)] = []
        h.initialHighlight(text: "func main() { var x = 1 }") { captured = $0 }
        XCTAssertFalse(captured.isEmpty)
    }

    func test_incrementalEdit_reusesTreeAndFindsComment() {
        let h = makeGoHighlighter()
        h.initialHighlight(text: "var x = 1") { _ in }
        var applied: [(NSRange, NSColor)] = []
        // Append " // hello" at the end — synchronous because debounceMs == 0
        h.didEdit(range: NSRange(location: 9, length: 0),
                  replacement: " // hello",
                  fullText: "var x = 1 // hello") { applied = $0 }
        XCTAssertTrue(applied.contains(where: { $0.1 == EditorTheme.synComment }),
                      "Expected comment color after incremental edit")
    }

    func test_dispose_cancelsDebounce() {
        let h = makeGoHighlighter()
        h.initialHighlight(text: "var x = 1") { _ in }
        // Should not crash
        h.dispose()
    }

    func test_emptyText_returnsNoHighlights() {
        let h = makeGoHighlighter()
        var captured: [(NSRange, NSColor)] = []
        h.initialHighlight(text: "") { captured = $0 }
        XCTAssertTrue(captured.isEmpty)
    }
}
