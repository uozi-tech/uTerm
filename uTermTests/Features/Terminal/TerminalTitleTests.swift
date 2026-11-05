import XCTest
@testable import uTerm

/// 两端共用的 OSC 0 / 2 标题规整。
final class TerminalTitleTests: XCTestCase {
    func test_trims_surrounding_whitespace() {
        XCTAssertEqual(TerminalTitle.normalize("  vim main.swift \n"), "vim main.swift")
    }

    func test_empty_or_blank_title_means_cleared() {
        XCTAssertNil(TerminalTitle.normalize(""))
        XCTAssertNil(TerminalTitle.normalize(" \t\n"))
    }

    func test_inner_whitespace_is_kept() {
        XCTAssertEqual(TerminalTitle.normalize("user@host: ~/a b"), "user@host: ~/a b")
    }
}
