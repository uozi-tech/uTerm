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

    /// 标签上已有状态圆点，程序画在标题开头的状态符号去掉，免得和别的标签对不齐。
    func test_leading_status_glyph_is_stripped() {
        XCTAssertEqual(TerminalTitle.normalize("◐ 多 Agent 进度统筹"), "多 Agent 进度统筹")
        XCTAssertEqual(TerminalTitle.normalize("✳ Claude Code"), "Claude Code")
        XCTAssertEqual(TerminalTitle.normalize("⠋ codex"), "codex")
    }

    /// 只有一个符号、后面没有文字：不是状态前缀，原样留着。
    func test_lone_glyph_is_kept() {
        XCTAssertEqual(TerminalTitle.normalize("◐ "), "◐")
    }

    func test_other_leading_characters_are_kept() {
        XCTAssertEqual(TerminalTitle.normalize("◐build"), "◐build")
        XCTAssertEqual(TerminalTitle.normalize("vim ◐ x"), "vim ◐ x")
        XCTAssertEqual(TerminalTitle.normalize("~ /tmp"), "~ /tmp")
    }
}
