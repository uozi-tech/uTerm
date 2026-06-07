// uTermTests/Editor/SameWordEmphasisTests.swift
import XCTest
@testable import uTerm

final class SameWordEmphasisTests: XCTestCase {

    func test_singleChar_doesNotEmphasize() {
        XCTAssertNil(SameWordEmphasis.targetWord(in: "foo bar baz", selection: NSRange(location: 0, length: 1)))
    }

    func test_whitespaceSelection_doesNotEmphasize() {
        XCTAssertNil(SameWordEmphasis.targetWord(in: "foo  bar", selection: NSRange(location: 3, length: 2)))
    }

    func test_crossLineSelection_doesNotEmphasize() {
        XCTAssertNil(SameWordEmphasis.targetWord(in: "foo\nbar", selection: NSRange(location: 0, length: 5)))
    }

    func test_fullIdentifier_emphasizes() {
        XCTAssertEqual(SameWordEmphasis.targetWord(in: "foo bar foo", selection: NSRange(location: 0, length: 3)), "foo")
    }

    func test_findsAllOccurrences() {
        let ranges = SameWordEmphasis.matches(of: "foo", in: "foo bar foo baz foo")
        XCTAssertEqual(ranges.map { $0.location }, [0, 8, 16])
    }
}
