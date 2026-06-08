// uTermTests/Editor/FindMatcherTests.swift
import XCTest
@testable import uTerm

final class FindMatcherTests: XCTestCase {

    func test_literal_caseInsensitive_findsAllOccurrences() {
        let r = try! FindMatcher.find(in: "Foo foo FOO bar", query: "foo",
                                      options: FindMatcher.Options(caseSensitive: false,
                                                                   regex: false,
                                                                   wholeWord: false))
        XCTAssertEqual(r.map { $0.location }, [0, 4, 8])
    }

    func test_literal_caseSensitive_filtersCases() {
        let r = try! FindMatcher.find(in: "Foo foo FOO", query: "foo",
                                      options: .init(caseSensitive: true, regex: false, wholeWord: false))
        XCTAssertEqual(r.map { $0.location }, [4])
    }

    func test_wholeWord_skipsSubstring() {
        let r = try! FindMatcher.find(in: "foo foobar foo_bar bafoo", query: "foo",
                                      options: .init(caseSensitive: false, regex: false, wholeWord: true))
        // Only the standalone "foo" at offset 0 matches.
        XCTAssertEqual(r.map { $0.location }, [0])
    }

    func test_regex_findsPattern() {
        let r = try! FindMatcher.find(in: "abc 123 def 456", query: "\\d+",
                                      options: .init(caseSensitive: false, regex: true, wholeWord: false))
        XCTAssertEqual(r.map { $0.location }, [4, 12])
        XCTAssertEqual(r.map { $0.length }, [3, 3])
    }

    func test_invalidRegex_throws() {
        XCTAssertThrowsError(try FindMatcher.find(in: "anything", query: "[unclosed",
                                                  options: .init(caseSensitive: false, regex: true, wholeWord: false)))
    }

    func test_emptyQuery_returnsEmpty() {
        let r = try! FindMatcher.find(in: "anything", query: "",
                                      options: .init(caseSensitive: false, regex: false, wholeWord: false))
        XCTAssertEqual(r, [])
    }

    func test_overlappingLiteral_noOverlap() {
        // VSCode behavior: "aaaa" with query "aa" → matches at 0 and 2, not 0/1/2.
        let r = try! FindMatcher.find(in: "aaaa", query: "aa",
                                      options: .init(caseSensitive: false, regex: false, wholeWord: false))
        XCTAssertEqual(r.map { $0.location }, [0, 2])
    }

    func test_crlf_offsetsAreUtf16() {
        // NSRange uses UTF-16 units; ensure CRLF doesn't desync.
        let r = try! FindMatcher.find(in: "ab\r\nfoo\r\nfoo", query: "foo",
                                      options: .init(caseSensitive: false, regex: false, wholeWord: false))
        XCTAssertEqual(r.map { $0.location }, [4, 9])
    }

    // MARK: - Replacement template expansion (#33)

    func test_replacement_literalMode_returnsTemplateVerbatim() {
        // In literal mode "$1" must be written verbatim, not expanded.
        let text = "foo bar"
        let r = FindMatcher.replacement(for: NSRange(location: 0, length: 3),
                                        in: text, query: "foo", template: "[$1]",
                                        options: .init(caseSensitive: false, regex: false, wholeWord: false))
        XCTAssertEqual(r, "[$1]")
    }

    func test_replacement_regexMode_expandsCaptureGroup() {
        // (\w+)=(\w+) → $2:$1  on "key=val"
        let text = "key=val"
        let opts = FindMatcher.Options(caseSensitive: false, regex: true, wholeWord: false)
        let matches = try! FindMatcher.find(in: text, query: "(\\w+)=(\\w+)", options: opts)
        XCTAssertEqual(matches.count, 1)
        let r = FindMatcher.replacement(for: matches[0], in: text,
                                        query: "(\\w+)=(\\w+)", template: "$2:$1", options: opts)
        XCTAssertEqual(r, "val:key")
    }

    func test_replacement_regexMode_perMatchExpansion() {
        // Each match expands $1 from its own capture group.
        let text = "a1 b2 c3"
        let opts = FindMatcher.Options(caseSensitive: false, regex: true, wholeWord: false)
        let matches = try! FindMatcher.find(in: text, query: "([a-z])(\\d)", options: opts)
        XCTAssertEqual(matches.count, 3)
        let expanded = matches.map {
            FindMatcher.replacement(for: $0, in: text, query: "([a-z])(\\d)", template: "$2$1", options: opts)
        }
        XCTAssertEqual(expanded, ["1a", "2b", "3c"])
    }

    func test_replacement_regexMode_dollarZeroIsWholeMatch() {
        let text = "wrap me"
        let opts = FindMatcher.Options(caseSensitive: false, regex: true, wholeWord: false)
        let matches = try! FindMatcher.find(in: text, query: "wrap", options: opts)
        let r = FindMatcher.replacement(for: matches[0], in: text,
                                        query: "wrap", template: "<$0>", options: opts)
        XCTAssertEqual(r, "<wrap>")
    }
}
