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
}
