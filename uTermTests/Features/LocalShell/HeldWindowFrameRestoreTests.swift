import UPaneGroups
import XCTest
@testable import uTerm

/// 重启接回时终端窗口回到原来的位置与大小，屏幕变了就夹回看得见的地方，多个窗口按上次的前后叠放。
@MainActor
final class HeldWindowFrameRestoreTests: XCTestCase {
    private let registry = TerminalSessionRegistry()
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func window(_ frame: CGRect = CGRect(x: 40, y: 40, width: 860, height: 560)) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: false)
        windows.append(window)
        return window
    }

    /// 主屏可见区域里一个确定放得下的位置（测试机屏幕多大都行）。
    private var savedOnMainScreen: CGRect {
        let screen = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: screen.minX + 30, y: screen.minY + 20,
                      width: min(1000, screen.width - 60).rounded(), height: min(640, screen.height - 40).rounded())
    }

    private func wait(timeout: TimeInterval = 3, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: 摆放（纯函数）

    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 920)
    private let external = CGRect(x: 1512, y: 0, width: 2304, height: 1240)

    func test_frame_on_a_present_screen_stays_where_it_was() {
        let frame = CGRect(x: 1600, y: 100, width: 1400, height: 900)
        XCTAssertEqual(HeldWindowFrame.placement(of: frame, screens: [laptop, external], minSize: .zero), frame)
    }

    func test_frame_hanging_off_the_screen_is_pushed_back_inside() {
        let frame = CGRect(x: 1200, y: 600, width: 800, height: 500)
        let placed = HeldWindowFrame.placement(of: frame, screens: [laptop], minSize: .zero)
        XCTAssertEqual(placed, CGRect(x: 712, y: 420, width: 800, height: 500))
    }

    func test_frame_on_a_removed_display_moves_to_the_main_screen() {
        // 上次在外接屏上，这次只剩笔记本屏。
        let frame = CGRect(x: 2000, y: 200, width: 1400, height: 900)
        let placed = HeldWindowFrame.placement(of: frame, screens: [laptop], minSize: .zero)
        XCTAssertEqual(placed, CGRect(x: 56, y: 10, width: 1400, height: 900))
        XCTAssertTrue(laptop.contains(placed))
    }

    func test_frame_larger_than_the_screen_shrinks_to_it_but_not_below_the_minimum() {
        let huge = CGRect(x: -100, y: -50, width: 3000, height: 2000)
        XCTAssertEqual(HeldWindowFrame.placement(of: huge, screens: [laptop], minSize: .zero), laptop)
        let tiny = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(HeldWindowFrame.placement(of: tiny, screens: [laptop], minSize: CGSize(width: 560, height: 398)),
                       CGRect(x: 100, y: 100, width: 560, height: 398))
    }

    func test_windows_stack_by_last_activation_with_the_newest_on_top() {
        XCTAssertEqual(HeldWindowStacking.order([("b", 20.0), ("a", 10.0), ("c", 30.0), ("old", 0.0)]),
                       ["old", "a", "b", "c"])
    }

    // MARK: 存储格式

    func test_layout_written_before_window_frames_still_decodes() throws {
        let id = UUID()
        let old = HeldSessionLayout(revision: 1, tree: UPaneGroupsSnapshot(
            root: .leaf(groupIndex: 0), groups: [.init(tabs: [id], activeIndex: 0)], activeGroupIndex: 0))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["window"] = nil
        let decoded = try JSONDecoder().decode(HeldSessionLayout.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.window)
        XCTAssertEqual(decoded.tree, old.tree)

        var current = old
        current.window = HeldWindowFrame(CGRect(x: 1, y: 2, width: 3, height: 4), activatedAt: 5)
        XCTAssertEqual(try JSONDecoder().decode(HeldSessionLayout.self, from: JSONEncoder().encode(current)), current)
    }

    // MARK: 跟踪与还原

    func test_tracker_restores_once_after_attaching_then_reports_user_moves() async throws {
        let screen = laptop
        let tracker = HeldWindowTracker(screens: { [screen] })
        var reported: [HeldWindowFrame] = []
        tracker.onChange = { reported.append($0) }
        let window = window()
        tracker.attach(window)
        XCTAssertEqual(reported.last?.rect, window.frame)

        // 上次的位置伸出了屏幕右边：夹回来。
        tracker.restore(HeldWindowFrame(CGRect(x: 1000, y: 100, width: 1000, height: 700), activatedAt: 7))
        let expected = CGRect(x: 512, y: 100, width: 1000, height: 700)
        let restored = await wait { window.frame == expected }
        XCTAssertTrue(restored, "实际 \(window.frame)")
        XCTAssertEqual(reported.last, HeldWindowFrame(expected, activatedAt: 7))

        // 只还原一次：之后再来的不动用户摆好的窗口。
        window.setFrame(CGRect(x: 10, y: 10, width: 900, height: 600), display: false)
        tracker.restore(HeldWindowFrame(CGRect(x: 300, y: 300, width: 700, height: 500), activatedAt: 8))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(window.frame, CGRect(x: 10, y: 10, width: 900, height: 600))
        XCTAssertEqual(reported.last?.rect, window.frame)
    }

    func test_local_shell_window_frame_comes_back_after_restart() async throws {
        let windowID = UUID()
        let model = LocalShellWindowModel(startShell: { _ in })
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: windowID, windowKind: TerminalWindowKind.terminal))
        model.addTab()
        model.addTab()
        let before = window(savedOnMainScreen)
        model.windowTracker.attach(before)
        let written = await wait { model.panes.allSatisfy { $0.attributes?.layout?.window?.rect == before.frame } }
        XCTAssertTrue(written, "窗口位置没写进每个会话")
        let stored = try model.panes.map { pane in
            let data = try JSONEncoder().encode(try XCTUnwrap(pane.attributes))
            return (id: pane.id, attributes: try JSONDecoder().decode(LocalShellSessionAttributes.self, from: data))
        }
        let saved = before.frame
        model.disposeAll()

        // 重启：新窗口按默认大小打开，接回后回到原来的位置。
        let restored = LocalShellWindowModel(startShell: { _ in })
        let after = window()
        restored.windowTracker.attach(after)
        LocalShellRestorer.adopt(stored, windowID: windowID, into: restored)
        let back = await wait { after.frame == saved }
        XCTAssertTrue(back, "实际 \(after.frame)，应为 \(saved)")
        restored.disposeAll()
    }

    func test_ssh_terminal_window_frame_comes_back_after_restart() async throws {
        let windowID = UUID(), server = UUID()
        let model = WorkspaceModel()
        model.attachSessionRegistry(registry, windowID: windowID, windowKind: TerminalWindowKind.terminal)
        model.openServer(profileID: server, title: "a")
        model.openServer(profileID: server, title: "b")
        let before = window(savedOnMainScreen)
        model.windowTracker.attach(before)
        let panes = model.terminalGroups.allTabs.map(\.payload)
        let written = await wait { panes.allSatisfy { $0.heldAttributes()?.layout?.window?.rect == before.frame } }
        XCTAssertTrue(written, "窗口位置没写进每条会话")
        let sessions = try panes.map { pane -> SSHSessionRestorer.Session in
            let data = try JSONEncoder().encode(try XCTUnwrap(pane.heldAttributes()))
            let attributes = try JSONDecoder().decode(SSHSessionAttributes.self, from: data)
            return SSHSessionRestorer.Session(id: pane.id, serverID: attributes.serverID, title: attributes.title,
                                              order: attributes.order, layout: attributes.layout)
        }
        let saved = before.frame
        model.dispose()

        let restored = WorkspaceModel()
        let after = window()
        restored.windowTracker.attach(after)
        restored.adoptHeldSessions(sessions)
        let back = await wait { after.frame == saved }
        XCTAssertTrue(back, "实际 \(after.frame)，应为 \(saved)")
        restored.dispose()
    }

    /// 工作区快照已经放好标签的窗口（系统恢复的工作区窗口）不按 holder 里的位置去摆。
    func test_window_that_already_has_tabs_is_not_moved() async throws {
        let server = UUID()
        let model = WorkspaceModel()
        model.openServer(profileID: server, title: "from snapshot")
        let window = window(CGRect(x: 50, y: 60, width: 900, height: 600))
        model.windowTracker.attach(window)
        var layout = HeldSessionLayout(revision: 1, tree: UPaneGroupsSnapshot(
            root: .leaf(groupIndex: 0), groups: [.init(tabs: [UUID()], activeIndex: 0)], activeGroupIndex: 0))
        layout.window = HeldWindowFrame(savedOnMainScreen, activatedAt: 1)
        model.adoptHeldSessions([SSHSessionRestorer.Session(id: UUID(), serverID: server, title: "held", order: 1, layout: layout)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(window.frame, CGRect(x: 50, y: 60, width: 900, height: 600))
        model.dispose()
    }
}
