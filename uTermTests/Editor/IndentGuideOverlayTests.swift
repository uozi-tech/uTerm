import XCTest
@testable import uTerm

final class IndentGuideOverlayTests: XCTestCase {
    func test_leadingIndentColumns_expandTabsToTabStops() {
        XCTAssertEqual(IndentGuideLayout.leadingIndentColumns(in: "    key", tabWidth: 4), [4])
        XCTAssertEqual(IndentGuideLayout.leadingIndentColumns(in: "        child", tabWidth: 4), [4, 8])
        XCTAssertEqual(IndentGuideLayout.leadingIndentColumns(in: "\t\tvalue", tabWidth: 4), [4, 8])
        XCTAssertEqual(IndentGuideLayout.leadingIndentColumns(in: "  \tvalue", tabWidth: 4), [4])
    }
}
