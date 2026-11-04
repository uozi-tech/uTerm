import UPaneGroups
import XCTest
@testable import uTerm

/// 本机终端窗口的分屏布局。不起真 shell：`startShell` 只记账。
@MainActor
final class LocalShellWindowModelTests: XCTestCase {
    private var started: [UUID] = []

    private func makeModel() -> LocalShellWindowModel {
        LocalShellWindowModel(startShell: { [weak self] pane in self?.started.append(pane.id) })
    }

    func test_preset_tab_id_is_the_session_id_the_phone_waits_for() {
        let model = makeModel()
        let id = UUID()
        model.addTab(id: id)
        XCTAssertEqual(model.active?.id, id)
        XCTAssertEqual(model.groups.tab(id)?.payload.id, id)
        XCTAssertEqual(started, [id])
    }

    func test_dragging_a_tab_to_another_groups_edge_splits_and_keeps_the_same_shell() throws {
        let model = makeModel()
        let first = model.addTab()
        let second = model.addTab()
        let secondPane = try XCTUnwrap(model.groups.tab(second)?.payload)
        let group = try XCTUnwrap(model.groups.activeGroupID)

        model.groups.moveTab(second, toGroup: group, zone: .trailing)

        XCTAssertEqual(model.groups.groupCount, 2)
        XCTAssertTrue(model.groups.tab(second)?.payload === secondPane, "拖动不能换掉正在跑的 shell")
        XCTAssertEqual(model.active?.id, second)
        XCTAssertEqual(started, [first, second], "拖动不该多起 shell")
    }

    func test_dragging_the_only_tab_to_its_own_edge_opens_a_new_shell() throws {
        let model = makeModel()
        let only = model.addTab()
        let group = try XCTUnwrap(model.groups.activeGroupID)

        model.groups.moveTab(only, toGroup: group, zone: .bottom)

        XCTAssertEqual(model.groups.groupCount, 2)
        XCTAssertNotNil(model.groups.tab(only), "原来的 shell 还在")
        XCTAssertEqual(model.panes.count, 2)
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(Set(model.panes.map(\.id)).count, 2)
    }

    func test_split_opens_a_new_shell_in_a_new_group() {
        let model = makeModel()
        model.addTab()

        model.splitActiveGroup(direction: .horizontal)

        XCTAssertEqual(model.groups.groupCount, 2)
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(model.active?.id, started.last)
    }

    func test_closing_a_group_last_tab_collapses_it_and_closing_everything_empties_the_area() {
        let model = makeModel()
        let first = model.addTab()
        model.splitActiveGroup(direction: .horizontal)
        let second = started[1]

        XCTAssertTrue(model.close(second))
        XCTAssertEqual(model.groups.groupCount, 1)
        XCTAssertFalse(model.groups.isEmpty)
        XCTAssertFalse(model.close(second), "已经关了")

        XCTAssertTrue(model.close(first))
        XCTAssertTrue(model.groups.isEmpty, "窗口靠这个判断要不要关")
    }

    func test_tab_names_stay_put_when_tabs_move_and_freed_numbers_get_reused() throws {
        let model = makeModel()
        let first = model.addTab()
        let second = model.addTab()
        let third = model.addTab()
        let name = try XCTUnwrap(model.groups.tab(first)?.payload.shellName)
        func title(_ id: UUID) -> String? { model.groups.tab(id)?.payload.defaultTitle }

        XCTAssertEqual(title(first), name)
        XCTAssertEqual(title(second), "\(name) 2")
        XCTAssertEqual(title(third), "\(name) 3")

        let group = try XCTUnwrap(model.groups.activeGroupID)
        model.groups.moveTab(first, toGroup: group, zone: .trailing)
        XCTAssertEqual(title(first), name, "标签顺序变了名字也不变")
        XCTAssertEqual(title(second), "\(name) 2")

        model.close(second)
        XCTAssertEqual(title(third), "\(name) 3", "关别的标签也不改名")
        XCTAssertEqual(title(model.addTab()), "\(name) 2", "空出来的序号复用")
    }

    // MARK: - 新建本机终端的路由

    func test_new_shell_opens_a_window_when_no_local_shell_window_exists() {
        var opened: [LocalShellWindowID] = []

        let paneID = LocalShellWindowRouter.shared.openShell { opened.append($0) }

        XCTAssertEqual(opened.map(\.firstPaneID), [paneID], "新窗口的第一个标签要用返回的会话 id")
    }

    func test_new_shell_joins_the_most_recently_active_window_instead_of_opening_another() {
        let router = LocalShellWindowRouter.shared
        let older = makeModel()
        let newer = makeModel()
        let olderWindow = UUID()
        let newerWindow = UUID()
        router.register(windowID: olderWindow, window: nil, model: older)
        router.register(windowID: newerWindow, window: nil, model: newer)
        defer {
            router.unregister(windowID: olderWindow)
            router.unregister(windowID: newerWindow)
        }
        router.markActive(windowID: olderWindow)

        let paneID = router.openShell { _ in XCTFail("已有本机终端窗口时不该再开窗口") }

        XCTAssertEqual(older.active?.id, paneID)
        XCTAssertTrue(newer.panes.isEmpty)
        XCTAssertEqual(started, [paneID])
    }
}
