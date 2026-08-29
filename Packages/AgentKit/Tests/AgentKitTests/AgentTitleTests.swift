import XCTest
@testable import AgentKit

final class AgentTitleTests: XCTestCase {
    func testTrimsAndTakesFirstLine() {
        XCTAssertEqual(AgentTitle.derive(from: "  hello  "), "hello")
        XCTAssertEqual(AgentTitle.derive(from: "line1\nline2"), "line1")
    }

    func testTruncatesLongPromptTo24CharsPlusEllipsis() {
        let long = String(repeating: "字", count: 40)
        let title = AgentTitle.derive(from: long)
        XCTAssertEqual(title.count, 25) // 24 chars + ellipsis
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(title, String(repeating: "字", count: 24) + "…")
    }

    func testShortPromptIsUnchanged() {
        XCTAssertEqual(AgentTitle.derive(from: "第一行\n第二行"), "第一行")
    }
}
