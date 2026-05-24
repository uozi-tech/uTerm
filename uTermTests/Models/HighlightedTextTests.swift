// uTermTests/Models/HighlightedTextTests.swift
import XCTest
import SwiftUI
@testable import uTerm

final class HighlightedTextTests: XCTestCase {

    func test_emptyQuery_returnsPlain() {
        let a = HighlightedText.attributed("hello", highlighting: "")
        // 无 attribute run 带 backgroundColor
        let runs = a.runs
        XCTAssertEqual(runs.count, 1)
    }

    func test_singleMatch_marksRangeWithBackground() {
        let a = HighlightedText.attributed("hello world", highlighting: "world")
        let str = String(a.characters)
        XCTAssertEqual(str, "hello world")
        // 应至少有 2 个 run（前段 + 命中段）；命中段有 backgroundColor
        let hasBackground = a.runs.contains { $0.backgroundColor != nil }
        XCTAssertTrue(hasBackground)
    }

    func test_caseInsensitive() {
        let a = HighlightedText.attributed("Hello World", highlighting: "WORLD")
        let hasBackground = a.runs.contains { $0.backgroundColor != nil }
        XCTAssertTrue(hasBackground)
    }

    func test_multipleMatches_allHighlighted() {
        let a = HighlightedText.attributed("abc abc abc", highlighting: "abc")
        let bgRuns = a.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(bgRuns.count, 3)
    }

    func test_emptySource_returnsEmpty() {
        let a = HighlightedText.attributed("", highlighting: "x")
        XCTAssertEqual(String(a.characters), "")
    }

    func test_noMatch_noHighlight() {
        let a = HighlightedText.attributed("hello", highlighting: "xyz")
        let hasBackground = a.runs.contains { $0.backgroundColor != nil }
        XCTAssertFalse(hasBackground)
    }
}
