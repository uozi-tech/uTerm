import UPaneGroups
import UPaneTree
import XCTest
@testable import uTerm

/// 重启后接回的会话要回到原来的位置：标签顺序、分组、分屏方向与比例、前台标签。
///
/// 不起真 shell / 真 SSH：布局写进每个窗格要交给 holder 的归属，这里取那份归属走一遍 JSON（holder 里存的就是它），
/// 交给全新的窗口模型接回，比两边的布局。
@MainActor
final class HeldSessionLayoutRestoreTests: XCTestCase {
    private let registry = TerminalSessionRegistry()

    // MARK: 本机终端

    private func localModel(windowID: UUID) -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { _ in })
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: windowID,
                                              windowKind: TerminalWindowKind.terminal))
        return model
    }

    private func localTree(_ model: LocalShellWindowModel) -> UPaneGroupsSnapshot<UUID> {
        model.groups.snapshot { $0.id }
    }

    /// 等布局写进每个窗格（写入有一小段攒批），返回各窗格存进 holder 的归属，已经过一遍 JSON。
    private func storedLocalAttributes(_ model: LocalShellWindowModel,
                                       file: StaticString = #filePath, line: UInt = #line) async throws
        -> [(id: UUID, attributes: LocalShellSessionAttributes)] {
        let expected = localTree(model)
        let written = await wait { model.panes.allSatisfy { $0.attributes?.layout?.tree == expected } }
        XCTAssertTrue(written, "布局没写进每个会话", file: file, line: line)
        return try model.panes.map { pane in
            let data = try JSONEncoder().encode(try XCTUnwrap(pane.attributes))
            return (pane.id, try JSONDecoder().decode(LocalShellSessionAttributes.self, from: data))
        }
    }

    func test_local_shell_reordered_and_split_tabs_come_back_in_place() async throws {
        let windowID = UUID()
        let model = localModel(windowID: windowID)
        let a = model.addTab(), b = model.addTab(), c = model.addTab(), d = model.addTab()
        model.groups.reorderTab(c, before: a)
        let group = try XCTUnwrap(model.groups.locateTab(b)?.groupID)
        model.groups.moveTab(b, toGroup: group, zone: .trailing)
        let right = try XCTUnwrap(model.groups.locateTab(b)?.groupID)
        model.groups.moveTabToEnd(d, ofGroup: right)
        guard case .split(let split) = model.groups.root else { return XCTFail("没分出屏") }
        model.groups.setFraction(0.3, splitID: split.id)
        model.reveal(c)
        let titles = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.id, $0.defaultTitle) })
        let expected = localTree(model)
        XCTAssertEqual(expected.groups.map(\.tabs), [[c, a], [b, d]])

        let stored = try await storedLocalAttributes(model)
        model.disposeAll()

        let restored = localModel(windowID: windowID)
        LocalShellRestorer.adopt(stored.shuffled(), windowID: windowID, into: restored)
        XCTAssertEqual(localTree(restored), expected)
        XCTAssertEqual(restored.active?.id, c)
        // 序号只管默认标题，不跟着位置变。
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: restored.panes.map { ($0.id, $0.defaultTitle) }), titles)
        restored.disposeAll()
    }

    func test_local_shell_closed_tab_leaves_the_stored_layout() async throws {
        let windowID = UUID()
        let model = localModel(windowID: windowID)
        let a = model.addTab(), b = model.addTab(), c = model.addTab()
        model.groups.reorderTab(c, before: a)
        model.close(a)
        let stored = try await storedLocalAttributes(model)
        XCTAssertEqual(stored.first?.attributes.layout?.tree.groups.map(\.tabs), [[c, b]])
        model.disposeAll()

        let restored = localModel(windowID: windowID)
        LocalShellRestorer.adopt(stored, windowID: windowID, into: restored)
        XCTAssertEqual(restored.panes.map(\.id), [c, b])
        restored.disposeAll()
    }

    /// 各会话的副本新旧不一时取最新的；最新那份里没有的活会话接在后面。
    func test_local_shell_newest_layout_wins_and_unlisted_sessions_are_appended() throws {
        let windowID = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        func layout(_ revision: Double, _ groups: [[UUID]]) -> HeldSessionLayout {
            let root: UPaneGroupsSnapshot<UUID>.Node = groups.count == 1 ? .leaf(groupIndex: 0)
                : .split(direction: .vertical, fraction: 0.5, first: .leaf(groupIndex: 0), second: .leaf(groupIndex: 1))
            return HeldSessionLayout(revision: revision, tree: UPaneGroupsSnapshot(
                root: root, groups: groups.map { .init(tabs: $0, activeIndex: 0) }, activeGroupIndex: 0))
        }
        let stale = layout(1, [[a, b]])
        let newest = layout(2, [[b], [a]])
        let restored = localModel(windowID: windowID)
        LocalShellRestorer.adopt([
            (a, LocalShellSessionAttributes(windowID: windowID, ordinal: 1, layout: stale)),
            (b, LocalShellSessionAttributes(windowID: windowID, ordinal: 2, layout: newest)),
            (c, LocalShellSessionAttributes(windowID: windowID, ordinal: 3, layout: nil)),
            (UUID(), LocalShellSessionAttributes(windowID: UUID(), ordinal: 4, layout: newest)),
        ], windowID: windowID, into: restored)
        let tree = localTree(restored)
        XCTAssertEqual(tree.groups.count, 2)
        XCTAssertEqual(Set(tree.groups.flatMap(\.tabs)), [a, b, c])
        XCTAssertEqual(tree.groups.first?.tabs.first, b)
        XCTAssertTrue(tree.groups.contains { $0.tabs.prefix(1) == [a] })
        // 补在后面的 c 不抢前台：前台仍是布局里活动组的前台标签。
        XCTAssertEqual(restored.active?.id, b)
        restored.disposeAll()
    }

    /// 布局是别的版本写的、解不开：当没有布局，归属其余部分照用（会话不能因此被扔进新窗口）。
    func test_unreadable_layout_does_not_lose_the_rest_of_the_attributes() throws {
        let windowID = UUID(), server = UUID()
        let local = #"{"windowID":"\#(windowID.uuidString)","ordinal":3,"layout":{"revision":"x","tree":7}}"#
        let decodedLocal = try JSONDecoder().decode(LocalShellSessionAttributes.self, from: Data(local.utf8))
        XCTAssertEqual(decodedLocal.windowID, windowID)
        XCTAssertEqual(decodedLocal.ordinal, 3)
        XCTAssertNil(decodedLocal.layout)

        let ssh = #"{"windowID":"\#(windowID.uuidString)","serverID":"\#(server.uuidString)","order":2,"layout":[1]}"#
        let decodedSSH = try JSONDecoder().decode(SSHSessionAttributes.self, from: Data(ssh.utf8))
        XCTAssertEqual(decodedSSH.serverID, server)
        XCTAssertEqual(decodedSSH.order, 2)
        XCTAssertNil(decodedSSH.layout)
    }

    /// 旧版写的归属没有布局：照旧按序号排成一组。新版写的旧版也解得开（这里用只认旧字段的类型代替旧版）。
    func test_local_shell_old_attributes_without_layout_still_restore_by_ordinal() throws {
        let windowID = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        func old(_ ordinal: Int) throws -> LocalShellSessionAttributes {
            let json = #"{"windowID":"\#(windowID.uuidString)","ordinal":\#(ordinal)}"#
            return try JSONDecoder().decode(LocalShellSessionAttributes.self, from: Data(json.utf8))
        }
        let restored = localModel(windowID: windowID)
        LocalShellRestorer.adopt([(c, try old(3)), (a, try old(1)), (b, try old(2))], windowID: windowID, into: restored)
        XCTAssertEqual(restored.groups.groupCount, 1)
        XCTAssertEqual(restored.panes.map(\.id), [a, b, c])
        restored.disposeAll()

        struct OldAttributes: Decodable { var windowID: UUID; var ordinal: Int }
        let new = LocalShellSessionAttributes(windowID: windowID, ordinal: 2, layout: HeldSessionLayout(
            revision: 1, tree: .init(root: .leaf(groupIndex: 0), groups: [.init(tabs: [a], activeIndex: 0)],
                                     activeGroupIndex: 0)))
        let decoded = try JSONDecoder().decode(OldAttributes.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(decoded.ordinal, 2)
    }

    // MARK: SSH 终端

    private func sshTree(_ model: WorkspaceModel) -> UPaneGroupsSnapshot<UUID> {
        model.terminalGroups.snapshot { $0.payload.fileBuffer == nil ? $0.payload.id : nil }
    }

    func test_ssh_terminal_window_reordered_and_split_tabs_come_back_in_place() async throws {
        let windowID = UUID(), server = UUID()
        let model = WorkspaceModel()
        model.attachSessionRegistry(registry, windowID: windowID, windowKind: TerminalWindowKind.terminal)
        // `openServer` 返回标签 id；布局里记的是会话 id（窗格 id）。
        let a = model.openServer(profileID: server, title: "a")
        let b = model.openServer(profileID: server, title: "b")
        let c = model.openServer(profileID: server, title: "c")
        model.terminalGroups.reorderTab(c, before: a)
        let group = try XCTUnwrap(model.terminalGroups.locateTab(b)?.groupID)
        model.terminalGroups.moveTab(b, toGroup: group, zone: .bottom)
        let session = { (tab: UUID) in model.terminalGroups.tab(tab)?.payload.id }
        let expected = sshTree(model)
        XCTAssertEqual(expected.groups.map(\.tabs), [[session(c), session(a)].compactMap { $0 }, [session(b)].compactMap { $0 }])
        XCTAssertEqual(expected.root, .split(direction: .vertical, fraction: 0.5, first: .leaf(groupIndex: 0),
                                             second: .leaf(groupIndex: 1)))

        let panes = model.terminalGroups.allTabs.map(\.payload)
        let written = await wait { panes.allSatisfy { $0.heldAttributes()?.layout?.tree == expected } }
        XCTAssertTrue(written, "布局没写进每条会话")
        // 恢复器交来的顺序是打开先后（旧的 order），布局要把它纠正过来。
        let sessions = try panes.map { pane -> SSHSessionRestorer.Session in
            let data = try JSONEncoder().encode(try XCTUnwrap(pane.heldAttributes()))
            let attributes = try JSONDecoder().decode(SSHSessionAttributes.self, from: data)
            return SSHSessionRestorer.Session(id: pane.id, serverID: attributes.serverID, title: attributes.title,
                                              order: attributes.order, layout: attributes.layout)
        }.sorted { $0.order < $1.order }
        model.dispose()

        let restored = WorkspaceModel()
        restored.adoptHeldSessions(sessions)
        XCTAssertEqual(sshTree(restored), expected)
        restored.dispose()
    }

    /// 退出 App 时攒批里的布局要同步写出去（之后连接就断了，异步任务不一定来得及跑）。
    func test_quit_flushes_pending_layout_synchronously() async throws {
        let windowID = UUID(), server = UUID()
        let workspace = WorkspaceModel()
        workspace.attachSessionRegistry(registry, windowID: windowID, windowKind: TerminalWindowKind.terminal)
        let first = workspace.openServer(profileID: server, title: "a")
        let second = workspace.openServer(profileID: server, title: "b")
        let local = localModel(windowID: UUID())
        let x = local.addTab(), y = local.addTab()
        let panes = workspace.terminalGroups.allTabs.map(\.payload)
        let settled = await wait {
            panes.allSatisfy { $0.heldAttributes()?.layout != nil } && local.panes.allSatisfy { $0.attributes?.layout != nil }
        }
        XCTAssertTrue(settled)

        workspace.terminalGroups.reorderTab(second, before: first)
        local.groups.reorderTab(y, before: x)
        HeldLayoutWriters.flushPending()   // 同步：不让出主线程。
        let sshTree = sshTree(workspace)
        XCTAssertTrue(panes.allSatisfy { $0.heldAttributes()?.layout?.tree == sshTree }, "SSH 窗格还是旧布局")
        XCTAssertTrue(local.panes.allSatisfy { $0.attributes?.layout?.tree.groups.first?.tabs == [y, x] }, "本机终端还是旧布局")
        workspace.dispose()
        local.disposeAll()
    }

    /// 退出途中窗口跟着关：关窗口时把攒着的那份先写掉；平时关窗口（会话随之结束）不写。
    func test_stopping_the_writer_flushes_only_when_asked() async throws {
        let groups = UPaneGroupsModel<Int>()
        let a = UUID(), b = UUID()
        groups.openTab({ UPaneTab(id: a, payload: 1) }, in: nil)
        groups.openTab({ UPaneTab(id: b, payload: 2) }, in: nil)
        var written: [[UUID]] = []
        func makeWriter() -> HeldLayoutWriter<Int> {
            HeldLayoutWriter(groups: groups, delay: .seconds(10), id: \.id) { written.append($0.tree.groups[0].tabs) }
        }

        let closing = makeWriter()
        groups.reorderTab(b, before: a)
        try await Task.sleep(for: .milliseconds(50))   // 让变化先进攒批。
        closing.stop()
        XCTAssertEqual(written, [])

        let quitting = makeWriter()
        groups.reorderTab(a, before: b)
        try await Task.sleep(for: .milliseconds(50))
        quitting.stop(flushingPending: true)
        XCTAssertEqual(written, [[a, b]])
        HeldLayoutWriters.flushPending()   // 停掉的不再写。
        XCTAssertEqual(written, [[a, b]])
    }

    func test_ssh_old_attributes_without_layout_decode_and_keep_open_order() throws {
        let windowID = UUID(), server = UUID()
        let json = #"{"windowID":"\#(windowID.uuidString)","serverID":"\#(server.uuidString)","title":"t","order":5}"#
        let attributes = try JSONDecoder().decode(SSHSessionAttributes.self, from: Data(json.utf8))
        XCTAssertNil(attributes.layout)
        XCTAssertEqual(attributes.order, 5)

        let first = UUID(), second = UUID()
        let model = WorkspaceModel()
        model.adoptHeldSessions([
            SSHSessionRestorer.Session(id: first, serverID: server, title: "1", order: 1),
            SSHSessionRestorer.Session(id: second, serverID: server, title: "2", order: 2),
        ])
        XCTAssertEqual(model.terminalGroups.groupCount, 1)
        XCTAssertEqual(model.terminalGroups.allTabs.map(\.payload.id), [first, second])
        model.dispose()
    }

    private func wait(timeout: TimeInterval = 3, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
