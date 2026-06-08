import XCTest
@testable import uTerm

final class LineNumberGutterTests: XCTestCase {

    // MARK: - trimmedLineRange terminator stripping (#35)

    func test_trimmedLineRange_stripsLineFeed() {
        // "abc\n" -> range covers all 4; trimmed excludes the \n.
        let ns = "abc\n" as NSString
        let r = LineNumberGutter.trimmedLineRange(NSRange(location: 0, length: 4), in: ns)
        XCTAssertEqual(r, NSRange(location: 0, length: 3))
    }

    func test_trimmedLineRange_stripsFullCRLFPair() {
        // CRLF line: only stripping the trailing \n leaves a stray \r in the
        // selection. The full \r\n pair must be excluded (#35).
        let ns = "abc\r\n" as NSString          // length 5
        let r = LineNumberGutter.trimmedLineRange(NSRange(location: 0, length: 5), in: ns)
        XCTAssertEqual(r, NSRange(location: 0, length: 3))
    }

    func test_trimmedLineRange_stripsLoneCarriageReturn() {
        // Classic-Mac line ending: a lone \r.
        let ns = "abc\r" as NSString
        let r = LineNumberGutter.trimmedLineRange(NSRange(location: 0, length: 4), in: ns)
        XCTAssertEqual(r, NSRange(location: 0, length: 3))
    }

    func test_trimmedLineRange_lastLineNoTerminator_unchanged() {
        let ns = "abc" as NSString
        let r = LineNumberGutter.trimmedLineRange(NSRange(location: 0, length: 3), in: ns)
        XCTAssertEqual(r, NSRange(location: 0, length: 3))
    }

    func test_trimmedLineRange_emptyRange_unchanged() {
        let ns = "abc\n" as NSString
        let r = LineNumberGutter.trimmedLineRange(NSRange(location: 1, length: 0), in: ns)
        XCTAssertEqual(r, NSRange(location: 1, length: 0))
    }

    func test_trimmedLineRange_crlfMidDocument_offsetPreserved() {
        // Second CRLF line in a multi-line doc: "a\r\nbcd\r\n".
        // Line "bcd\r\n" occupies offsets 3..<8 (location 3, length 5).
        let ns = "a\r\nbcd\r\n" as NSString
        let r = LineNumberGutter.trimmedLineRange(NSRange(location: 3, length: 5), in: ns)
        XCTAssertEqual(r, NSRange(location: 3, length: 3))   // "bcd"
    }

    func test_trimmedLineRange_crOnlyLine_doesNotOverstrip() {
        // A line that is just "\r" (length 1) trims to empty, never negative.
        let ns = "\r" as NSString
        let r = LineNumberGutter.trimmedLineRange(NSRange(location: 0, length: 1), in: ns)
        XCTAssertEqual(r, NSRange(location: 0, length: 0))
    }

    func test_trimmedLineRange_crlfOnlyLine_doesNotOverstrip() {
        // A line that is just "\r\n" (length 2) trims to empty, never negative.
        let ns = "\r\n" as NSString
        let r = LineNumberGutter.trimmedLineRange(NSRange(location: 0, length: 2), in: ns)
        XCTAssertEqual(r, NSRange(location: 0, length: 0))
    }
}
