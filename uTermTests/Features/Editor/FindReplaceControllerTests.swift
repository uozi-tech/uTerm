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

    // MARK: - Regex template expansion through the controller (#33)

    func test_replaceCurrent_regexMode_expandsCaptureGroups() {
        var text = "key=val rest"
        let c = FindReplaceController(text: { text })
        c.onReplace = { range, str in
            text = (text as NSString).replacingCharacters(in: range, with: str)
        }
        c.options = .init(caseSensitive: false, regex: true, wholeWord: false)
        c.query = "(\\w+)=(\\w+)"
        c.replacement = "$2:$1"
        c.search()
        c.replaceCurrent()
        XCTAssertEqual(text, "val:key rest")
    }

    func test_replaceAll_regexMode_expandsCaptureGroupsPerMatch() {
        var text = "a1 b2 c3"
        let c = FindReplaceController(text: { text })
        c.onReplace = { range, str in
            text = (text as NSString).replacingCharacters(in: range, with: str)
        }
        c.options = .init(caseSensitive: false, regex: true, wholeWord: false)
        c.query = "([a-z])(\\d)"
        c.replacement = "$2$1"
        c.search()
        c.replaceAll()
        XCTAssertEqual(text, "1a 2b 3c")
    }

    func test_replaceCurrent_literalMode_writesDollarVerbatim() {
        var text = "foo bar"
        let c = FindReplaceController(text: { text })
        c.onReplace = { range, str in
            text = (text as NSString).replacingCharacters(in: range, with: str)
        }
        c.replacement = "$1"
        c.query = "foo"
        c.search()
        c.replaceCurrent()
        XCTAssertEqual(text, "$1 bar")
    }

    // MARK: - Replace advances past self-matching replacement (#34)

    func test_replaceCurrent_advancesPastSelfMatchingReplacement() {
        // Replacing "foo" with "foofoo" must NOT re-select the inserted text;
        // the active match must land on the next original "foo".
        var text = "foo foo"
        let c = FindReplaceController(text: { text })
        c.onReplace = { range, str in
            text = (text as NSString).replacingCharacters(in: range, with: str)
        }
        c.replacement = "foofoo"
        c.query = "foo"
        c.search()
        XCTAssertEqual(c.activeIndex, 0)
        c.replaceCurrent()
        // text is now "foofoo foo"; matches at [0, 3, 7].
        XCTAssertEqual(text, "foofoo foo")
        XCTAssertEqual(c.matches.count, 3)
        // Active must be the original trailing "foo" at offset 7 (index 2),
        // not the inserted text at offsets 0/3.
        XCTAssertEqual(c.matches[c.activeIndex].location, 7)
    }

    func test_replaceCurrent_repeatedReplaceTerminates() {
        // Without the #34 fix this loops forever (document grows each press).
        // After replacing both originals, the only matches left are inserted
        // text, so a final press wraps to index 0 and the count stabilizes.
        var text = "foo foo"
        let c = FindReplaceController(text: { text })
        c.onReplace = { range, str in
            text = (text as NSString).replacingCharacters(in: range, with: str)
        }
        c.replacement = "foofoo"
        c.query = "foo"
        c.search()
        c.replaceCurrent()   // first original -> "foofoo foo", active at trailing foo
        c.replaceCurrent()   // second original -> "foofoo foofoo"
        XCTAssertEqual(text, "foofoo foofoo")
    }

    // MARK: - Re-search picks nearest prior position (#36)

    func test_search_picksNearestMatchToPriorActive_onShrink() {
        // Prior active at offset 12 (index 3). The text is then shortened so
        // the trailing match disappears, leaving matches at 0,4,8. Old behavior
        // clamps activeIndex to count-1 (= index 2, offset 8). Nearest-by-offset
        // to prior offset 12 also resolves to offset 8 here — the key property
        // is that the active index never escapes bounds and lands on the match
        // visually closest to where the user was.
        var text = "x . x . x . x"       // matches at 0,4,8,12
        let c = FindReplaceController(text: { text })
        c.query = "x"
        c.search()
        c.next(); c.next(); c.next()      // activeIndex = 3 (offset 12)
        XCTAssertEqual(c.matches[c.activeIndex].location, 12)
        text = "x . x . x"               // matches at 0,4,8
        c.search()
        XCTAssertEqual(c.matches[c.activeIndex].location, 8)
    }

    func test_search_nearestPrefersCloserOverClampedIndex() {
        // Genuinely distinguishes nearest-by-offset from blind count-clamp.
        // Prior active at the far-right match (index 1 of two). The text is then
        // edited to contain MANY matches; the one nearest the prior offset is
        // the last, far-right match. Old `min(activeIndex=1, count-1)` would
        // pick index 1 (an early, wrong match); nearest-by-offset picks the
        // far-right match. Strings built programmatically so offsets are exact.
        let before = "a" + String(repeating: " ", count: 19) + "a"   // matches 0, 20
        let after  = "a a a a a" + String(repeating: " ", count: 12) + "a" // 0,2,4,6,8,21
        var text = before
        let c = FindReplaceController(text: { text })
        c.query = "a"
        c.search()                            // matches 0,20; activeIndex 0
        c.next()                              // activeIndex = 1 (offset 20)
        XCTAssertEqual(c.matches[c.activeIndex].location, 20)
        text = after
        c.search()
        // Old clamp: min(1, 5) = index 1 -> offset 2 (wrong).
        // Nearest to prior offset 20: offset 21 (index 5) is closest.
        XCTAssertEqual(c.activeIndex, 5)
        XCTAssertEqual(c.matches[c.activeIndex].location, 21)
    }

    func test_search_clampsWhenMatchesShrink() {
        // Re-search with fewer matches must never leave activeIndex out of
        // bounds (regression guard for the NSRangeException class of bug).
        var text = "z z z z z"            // 5 matches
        let c = FindReplaceController(text: { text })
        c.query = "z"
        c.search()
        c.next(); c.next(); c.next(); c.next()   // activeIndex = 4
        XCTAssertEqual(c.activeIndex, 4)
        text = "z"                        // 1 match
        c.search()
        XCTAssertTrue(c.matches.indices.contains(c.activeIndex))
        XCTAssertEqual(c.activeIndex, 0)
    }
}
