// uTermTests/Editor/FindReplaceControllerTests.swift
import XCTest
@testable import uTerm

@MainActor
final class FindReplaceControllerTests: XCTestCase {

    func test_search_populatesMatches() {
        let c = FindReplaceController(text: { "foo bar foo baz foo" })
        c.options = .init(caseSensitive: false, regex: false, wholeWord: false)
        c.query = "foo"
        c.search()
        XCTAssertEqual(c.matches.count, 3)
        XCTAssertEqual(c.activeIndex, 0)
    }

    func test_next_wrapsAroundAtEnd() {
        let c = FindReplaceController(text: { "x x x" })
        c.query = "x"; c.search()
        c.next(); c.next()                    // 0 → 1 → 2
        XCTAssertEqual(c.activeIndex, 2)
        c.next()                               // → wraps to 0
        XCTAssertEqual(c.activeIndex, 0)
    }

    func test_previous_wrapsAroundAtStart() {
        let c = FindReplaceController(text: { "x x x" })
        c.query = "x"; c.search()
        c.previous()                          // wraps 0 → 2
        XCTAssertEqual(c.activeIndex, 2)
    }

    func test_replace_single_replacesActiveAndAdvances() {
        var text = "foo foo foo"
        let c = FindReplaceController(text: { text })
        c.replacement = "BAR"
        c.query = "foo"; c.search()
        c.onReplace = { range, str in
            text = (text as NSString).replacingCharacters(in: range, with: str)
        }
        c.replaceCurrent()
        XCTAssertEqual(text, "BAR foo foo")
        // After replace, search re-runs and activeIndex stays on current visual position.
        XCTAssertEqual(c.matches.count, 2)
    }

    func test_replaceAll_replacesEveryMatchInsideUndoGroup() {
        var text = "foo foo foo"
        var beginCalls = 0, endCalls = 0
        let c = FindReplaceController(text: { text })
        c.replacement = "X"
        c.query = "foo"; c.search()
        c.onReplace = { range, str in
            text = (text as NSString).replacingCharacters(in: range, with: str)
        }
        c.onBeginUndoGroup = { beginCalls += 1 }
        c.onEndUndoGroup = { endCalls += 1 }
        c.replaceAll()
        XCTAssertEqual(text, "X X X")
        XCTAssertEqual(beginCalls, 1)
        XCTAssertEqual(endCalls, 1)
        XCTAssertEqual(c.matches.count, 0)
    }

    func test_invalidRegex_setsErrorAndClearsMatches() {
        let c = FindReplaceController(text: { "anything" })
        c.options = .init(caseSensitive: false, regex: true, wholeWord: false)
        c.query = "[bad"
        c.search()
        XCTAssertNotNil(c.errorMessage)
        XCTAssertEqual(c.matches.count, 0)
    }
}
