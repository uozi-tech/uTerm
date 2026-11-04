import Darwin
import UPaneGroups
import XCTest
@testable import uTerm

/// 本机终端标签和会话注册表、后端的关系。不起真 shell：`startShell` 接假后端。
@MainActor
final class LocalShellPaneLifecycleTests: XCTestCase {
    private var registry: TerminalSessionRegistry!
    private var backends: [UUID: MockBackend] = [:]
    private var connecting: [Task<Void, Never>] = []
    private var windowID = UUID()

    override func setUp() async throws {
        registry = TerminalSessionRegistry()
        backends = [:]
        connecting = []
    }

    private func makeModel() -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { [unowned self] pane in
            let backend = MockBackend()
            backends[pane.id] = backend
            connecting.append(Task { await pane.session.connect(using: backend) })
        })
        windowID = UUID()
        model.attach(TerminalSessionRegistrar(
            registry: registry, windowID: windowID, windowKind: TerminalWindowKind.terminal,
            customTitle: { [weak model] paneID in model?.groups.tab(paneID)?.payload.defaultTitle }))
        registry.setCloser(forWindow: windowID) { [weak model] in model?.close($0) ?? false }
        return model
    }

    private func connected() async {
        for task in connecting { await task.value }
        connecting = []
    }

    private func registeredIDs() -> Set<UUID> {
        Set(registry.snapshots().compactMap { UUID(uuidString: $0.id) })
    }

    private func focused() -> UUID? {
        registry.snapshots().first(where: \.isKeyWindowFocused).flatMap { UUID(uuidString: $0.id) }
    }

    func testPaneIsRegisteredUnderItsTabIDWithStableName() async throws {
        let model = makeModel()
        let first = model.addTab()
        let second = model.addTab()
        await connected()

        XCTAssertEqual(registeredIDs(), [first, second], "手机按这个 id 找会话")
        let pane = try XCTUnwrap(model.groups.tab(first)?.payload)
        let snapshot = try XCTUnwrap(registry.snapshots().first { UUID(uuidString: $0.id) == first })
        XCTAssertEqual(snapshot.title, pane.defaultTitle)
        XCTAssertEqual(snapshot.serverName, LocalShellIdentity.serverName)
    }

    func testShellTitleStaysOutOfRegistry() async throws {
        let model = makeModel()
        let id = model.addTab()
        await connected()
        let pane = try XCTUnwrap(model.groups.tab(id)?.payload)

        pane.session.terminalView.feed(text: "\u{1b}]0;vim main.swift\u{07}")

        XCTAssertEqual(pane.session.shellTitle, "vim main.swift")
        XCTAssertEqual(registry.snapshots().first?.title, pane.defaultTitle)
    }

    /// 分屏只是换了摆放位置：会话 id、后端、注册记录都不动，手机上那个标签不会断。
    func testMovingATabToAnotherGroupKeepsItsSession() async throws {
        let model = makeModel()
        let first = model.addTab()
        let second = model.addTab()
        await connected()
        let group = try XCTUnwrap(model.groups.activeGroupID)

        model.groups.moveTab(second, toGroup: group, zone: .trailing)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.groups.groupCount, 2)
        XCTAssertEqual(registeredIDs(), [first, second])
        let pane = try XCTUnwrap(model.groups.tab(second)?.payload)
        XCTAssertEqual(pane.session.connectionState, .connected)
        XCTAssertNotNil(pane.session.backend)
    }

    func testPhoneCanCloseAPaneAfterItWasSplitOff() async throws {
        let model = makeModel()
        model.addTab()
        model.splitActiveGroup(direction: .horizontal)
        await connected()
        let splitOff = try XCTUnwrap(model.active?.id)
        let pane = try XCTUnwrap(model.groups.tab(splitOff)?.payload)
        XCTAssertTrue(registeredIDs().contains(splitOff))

        XCTAssertTrue(registry.requestClose(sessionID: splitOff))

        XCTAssertNil(model.groups.tab(splitOff))
        XCTAssertEqual(model.groups.groupCount, 1, "空下来的那一格要收掉")
        XCTAssertNil(pane.session.backend, "shell 的收尾见 testClosingTabEndsTheRealShell")
        XCTAssertFalse(registeredIDs().contains(splitOff))
    }

    func testClosingEveryTabEmptiesTheAreaAndEndsEveryShell() async throws {
        let model = makeModel()
        let first = model.addTab()
        let second = model.addTab()
        await connected()
        let panes = try [first, second].map { try XCTUnwrap(model.groups.tab($0)?.payload) }

        XCTAssertTrue(model.close(first))
        XCTAssertFalse(model.groups.isEmpty)
        XCTAssertTrue(model.close(second))

        XCTAssertTrue(model.groups.isEmpty, "窗口靠这个判断要不要关")
        XCTAssertTrue(panes.allSatisfy { $0.session.backend == nil })
        XCTAssertTrue(registry.snapshots().isEmpty)
    }

    func testDisposeAllEndsShellsInEveryGroup() async throws {
        let model = makeModel()
        let first = model.addTab()
        model.splitActiveGroup(direction: .vertical)
        let second = try XCTUnwrap(model.active?.id)
        await connected()
        let panes = try [first, second].map { try XCTUnwrap(model.groups.tab($0)?.payload) }

        model.disposeAll()

        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.panes.isEmpty)
        XCTAssertTrue(panes.allSatisfy { $0.session.backend == nil })
        XCTAssertTrue(registry.snapshots().isEmpty)
    }

    func testCloseAndRevealRejectUnknownTabs() {
        let model = makeModel()
        model.addTab()
        XCTAssertFalse(model.close(UUID()))
        XCTAssertFalse(model.reveal(UUID()))
        XCTAssertEqual(model.panes.count, 1)
    }

    func testRevealBringsTheTabToFront() {
        let model = makeModel()
        let first = model.addTab()
        let second = model.addTab()
        XCTAssertEqual(model.active?.id, second)

        XCTAssertTrue(model.reveal(first))

        XCTAssertEqual(model.active?.id, first)
    }

    /// 空闲的 shell 直接关；手机远控和通知都不走这条，这里验用户点 ×。
    func testRequestCloseOfIdleShellClosesIt() async throws {
        let model = makeModel()
        let first = model.addTab()
        model.addTab()
        await connected()
        await backends[first]?.setForegroundActivity(.idle)

        model.requestClose(first)
        for _ in 0..<200 where model.groups.tab(first) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(model.groups.tab(first))
        XCTAssertEqual(model.panes.count, 1)
    }

    func testRequestCloseOfUnknownTabDoesNothing() {
        let model = makeModel()
        model.addTab()
        model.requestClose(UUID())
        XCTAssertEqual(model.panes.count, 1)
    }

    func testFocusFollowsTheActiveTabIntoRegistry() async throws {
        let model = makeModel()
        let first = model.addTab()
        let second = model.addTab()
        await connected()
        model.syncFocus()
        registry.setKeyWindow(windowID: windowID, isKey: true)
        XCTAssertEqual(focused(), second)

        XCTAssertTrue(model.reveal(first))
        model.syncFocus()
        XCTAssertEqual(focused(), first)
    }

    // MARK: - ⌘W

    func testCloseShortcutWithOneTabClosesTheWindow() {
        let model = makeModel()
        let only = model.addTab()
        var windowCloses = 0

        model.handleCloseShortcut { windowCloses += 1 }

        XCTAssertEqual(windowCloses, 1)
        XCTAssertNotNil(model.groups.tab(only), "标签由关窗流程收，这里不动")
    }

    func testCloseShortcutWithSeveralTabsClosesOnlyTheActiveOne() async throws {
        let model = makeModel()
        let first = model.addTab()
        let second = model.addTab()
        await connected()
        await backends[second]?.setForegroundActivity(.idle)
        var windowCloses = 0

        model.handleCloseShortcut { windowCloses += 1 }
        for _ in 0..<200 where model.groups.tab(second) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(windowCloses, 0)
        XCTAssertNil(model.groups.tab(second))
        XCTAssertNotNil(model.groups.tab(first))
    }

    func testCloseShortcutOnEmptyGroupCollapsesItAndKeepsTheShells() throws {
        let model = makeModel()
        model.addTab()
        model.addTab()
        model.groups.makeTabForNewGroup = nil
        let group = try XCTUnwrap(model.groups.activeGroupID)
        model.groups.splitGroup(group, direction: .horizontal)
        XCTAssertEqual(model.groups.groupCount, 2)
        XCTAssertNil(model.active, "活动组是新分出来的空组")
        var windowCloses = 0

        model.handleCloseShortcut { windowCloses += 1 }

        XCTAssertEqual(windowCloses, 0)
        XCTAssertEqual(model.groups.groupCount, 1)
        XCTAssertEqual(model.panes.count, 2)
    }

    // MARK: - 标签条

    func testTabShowsDefaultNameUntilShellSetsTitle() throws {
        let model = makeModel()
        let id = model.addTab()
        let pane = try XCTUnwrap(model.groups.tab(id)?.payload)

        var descriptor = LocalShellTerminalArea.descriptor(for: pane)
        XCTAssertEqual(descriptor.title, pane.defaultTitle)
        XCTAssertEqual(descriptor.help, pane.defaultTitle)

        pane.session.terminalView.feed(text: "\u{1b}]0;vim main.swift\u{07}")
        descriptor = LocalShellTerminalArea.descriptor(for: pane)
        XCTAssertEqual(descriptor.title, "vim main.swift")
        XCTAssertEqual(descriptor.help, "vim main.swift")

        pane.session.terminalView.feed(text: "\u{1b}]0;\u{07}")
        XCTAssertEqual(LocalShellTerminalArea.descriptor(for: pane).title, pane.defaultTitle)
    }

    func testLongShellTitleIsClippedInTabButNotInHelp() throws {
        let model = makeModel()
        let id = model.addTab()
        let pane = try XCTUnwrap(model.groups.tab(id)?.payload)
        let long = String(repeating: "很长的标题", count: 30)

        pane.session.terminalView.feed(text: "\u{1b}]0;\(long)\u{07}")

        let descriptor = LocalShellTerminalArea.descriptor(for: pane)
        XCTAssertEqual(descriptor.title, TerminalArea.clippedTabTitle(long))
        XCTAssertNotEqual(descriptor.title, long)
        XCTAssertEqual(descriptor.help, long)
    }

    func testTabUnderRemoteControlSaysSoEvenWithAShellTitle() throws {
        let model = makeModel()
        let id = model.addTab()
        let pane = try XCTUnwrap(model.groups.tab(id)?.payload)
        pane.session.terminalView.feed(text: "\u{1b}]0;vim\u{07}")

        pane.session.remoteController = "iPhone"

        let descriptor = LocalShellTerminalArea.descriptor(for: pane)
        XCTAssertEqual(descriptor.title, "vim")
        XCTAssertEqual(descriptor.help, "正在被手机接管")
    }

    // MARK: - 路由

    func testRouterSkipsReleasedAndUnregisteredWindows() {
        let router = LocalShellWindowRouter.shared
        let released = UUID()
        let unregistered = UUID()
        do {
            let model = makeModel()
            router.register(windowID: released, window: nil, model: model)
        }
        let kept = makeModel()
        router.register(windowID: unregistered, window: nil, model: kept)
        router.unregister(windowID: unregistered)
        defer { router.unregister(windowID: released) }

        var opened: [LocalShellWindowID] = []
        let paneID = router.openShell { opened.append($0) }

        XCTAssertEqual(opened.map(\.firstPaneID), [paneID], "窗口都不在了，要开新窗口")
        XCTAssertTrue(kept.panes.isEmpty)
    }

    // MARK: - 真 shell

    private func isAlive(_ pid: Int32) -> Bool {
        var name = [CChar](repeating: 0, count: 64)
        return proc_name(pid, &name, UInt32(name.count)) > 0
    }

    private func shellPID(of pane: LocalShellPane) async throws -> Int32 {
        let backend = try XCTUnwrap(pane.session.backend as? LocalShellBackend)
        let pid = await backend.pid
        return try XCTUnwrap(pid)
    }

    /// 关标签要结束 shell，否则它连同里面的程序一直活着。`TerminalSession.dispose()` 会丢掉后端，
    /// 之后的 `session.close()` 已经摸不到它：ae4bb124 起就这样漏过一轮，现在靠 `closeForDisposal`。
    func testClosingTabEndsTheRealShell() async throws {
        let model = LocalShellWindowModel()
        defer { model.disposeAll() }
        let id = model.addTab()
        let pane = try XCTUnwrap(model.groups.tab(id)?.payload)
        for _ in 0..<500 where pane.session.connectionState != .connected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pane.session.connectionState, .connected)
        // 单独成函数：这里不能留着后端的引用，它要靠引用归零收尾。
        let pid = try await shellPID(of: pane)
        XCTAssertTrue(isAlive(pid), "探测手段本身得能看到活着的 shell")

        XCTAssertTrue(model.close(id))

        for _ in 0..<500 where isAlive(pid) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(isAlive(pid), "标签关了，shell \(pid) 还活着")
    }
}
