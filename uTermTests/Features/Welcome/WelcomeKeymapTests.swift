import XCTest
@testable import uTerm

final class WelcomeKeymapTests: XCTestCase {
    // macOS 虚拟键码，与 WelcomeKeymap 内部常量保持一致。
    private let up: UInt16 = 126
    private let down: UInt16 = 125
    private let del: UInt16 = 51

    private func action(_ keyCode: UInt16, chars: String = "",
                        command: Bool = false, option: Bool = false,
                        control: Bool = false, isTextEditing: Bool = false) -> WelcomeListKey? {
        WelcomeKeymap.listAction(keyCode: keyCode, chars: chars,
                                 command: command, option: option,
                                 control: control, isTextEditing: isTextEditing)
    }

    // MARK: 方向键

    func testBareArrowsMoveSelection() {
        XCTAssertEqual(action(up), .prev)
        XCTAssertEqual(action(down), .next)
    }

    func testCommandArrowsJumpToEnds() {
        XCTAssertEqual(action(up, command: true), .first)
        XCTAssertEqual(action(down, command: true), .last)
    }

    func testArrowsWorkWhileTypingInSearch() {
        // 在搜索框输入时上下键仍移动列表选中（命令面板式行为）。
        XCTAssertEqual(action(up, isTextEditing: true), .prev)
        XCTAssertEqual(action(down, isTextEditing: true), .next)
    }

    // MARK: ⌘E / ⌘⌫

    func testCommandEEdits() {
        XCTAssertEqual(action(0, chars: "e", command: true), .edit)
    }

    func testCommandDeleteDeletesWhenNotEditingText() {
        XCTAssertEqual(action(del, command: true, isTextEditing: false), .delete)
    }

    func testCommandDeleteIsSuppressedWhileTypingText() {
        // 文本编辑态下 ⌘⌫ = 删到行首，绝不能当成「删服务器」。
        XCTAssertNil(action(del, command: true, isTextEditing: true))
    }

    func testBareDeleteIsIgnored() {
        XCTAssertNil(action(del))
    }

    // MARK: ⌘D 复制为新服务器

    func testCommandDDuplicates() {
        XCTAssertEqual(action(0, chars: "d", command: true, isTextEditing: false), .duplicate)
    }

    func testCommandDIsSuppressedWhileTypingText() {
        XCTAssertNil(action(0, chars: "d", command: true, isTextEditing: true))
    }

    func testBareDIsIgnored() {
        XCTAssertNil(action(0, chars: "d"))
    }

    // MARK: 修饰键边界

    func testOptionOrControlCombosAreIgnored() {
        // ⌥↑/⌥↓ 留给侧栏，⌃ 组合留给系统——主列表都不接。
        XCTAssertNil(action(up, option: true))
        XCTAssertNil(action(down, option: true))
        XCTAssertNil(action(up, control: true))
        XCTAssertNil(action(del, command: true, control: true))
        XCTAssertNil(action(0, chars: "e", command: true, option: true))
    }

    func testUnknownKeysReturnNil() {
        XCTAssertNil(action(0, chars: "x", command: true))
        XCTAssertNil(action(0, chars: "a"))
    }
}

final class WelcomeSidebarNavTests: XCTestCase {
    func testFullEntryOrderMatchesSidebarRendering() {
        let entries = WelcomeSidebarNav.entries(
            pinnedCount: 2,
            recentCount: 3,
            showsGroupSection: true,
            groupNames: ["阿里", "vps"],
            ungroupedCount: 1
        )

        XCTAssertEqual(entries, [
            .section(.pinned),
            .section(.recent),
            .section(.allHosts),
            .section(.group("阿里")),
            .section(.group("vps")),
            .section(.ungrouped),
            .quickCommands,
        ])
    }

    func testEmptyViewAndGroupSectionsCollapse() {
        // 无置顶/最近/分组/未分组时，只剩「快捷命令」一项（始终存在）。
        let entries = WelcomeSidebarNav.entries(
            pinnedCount: 0,
            recentCount: 0,
            showsGroupSection: false,
            groupNames: [],
            ungroupedCount: 0
        )

        XCTAssertEqual(entries, [.quickCommands])
    }

    func testShortcutHintNumbersFirstNineOnly() {
        var entries: [WelcomeNavTarget] = (0..<9).map { .section(.group("g\($0)")) }
        entries.append(.quickCommands)   // 第 10 项

        XCTAssertEqual(WelcomeSidebarNav.shortcutHint(for: .section(.group("g0")), in: entries), "⌘1")
        XCTAssertEqual(WelcomeSidebarNav.shortcutHint(for: .section(.group("g8")), in: entries), "⌘9")
        // 第 10 项无数字提示。
        XCTAssertNil(WelcomeSidebarNav.shortcutHint(for: .quickCommands, in: entries))
        // 不在表内的目标也无提示。
        XCTAssertNil(WelcomeSidebarNav.shortcutHint(for: .section(.pinned), in: entries))
    }
}
