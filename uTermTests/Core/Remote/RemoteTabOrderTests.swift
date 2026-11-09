import XCTest
@preconcurrency import Network
import UPaneGroups
@testable import uTerm

/// 远控的标签顺序：Mac 按窗口布局排会话列表（`order` 字段），接入的设备跟着排、不打断正看着的标签。
@MainActor
final class RemoteTabOrderTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func groups(_ ids: [UUID]) -> UPaneGroupsModel<UUID> {
        let model = UPaneGroupsModel<UUID>(policy: UPaneGroupsPolicy())
        for id in ids { model.openTab({ UPaneTab(id: id, payload: id) }) }
        return model
    }

    private func info(_ id: UUID, order: Int?) -> RemoteSessionInfo {
        RemoteSessionInfo(id: id, serverID: UUID(), serverName: "测试主机", title: "zsh",
                          windowKind: TerminalWindowKind.workspace, connectedAt: nil, order: order)
    }

    // MARK: - 布局展开成一列

    func test_single_group_order_is_the_tab_strip_order() {
        let a = UUID(), b = UUID(), c = UUID()
        let model = groups([a, b, c])
        XCTAssertEqual(model.snapshot(\.id).tabOrder, [a, b, c])
        model.reorderTab(c, before: a)
        XCTAssertEqual(model.snapshot(\.id).tabOrder, [c, a, b])
    }

    /// [组0 | (组2 / 组1)]：左边一组，右边上下两组。`groups` 数组的先后不算，按树走。
    func test_split_layout_expands_left_to_right_then_top_to_bottom() {
        typealias Snap = UPaneGroupsSnapshot<String>
        let snap = Snap(
            root: .split(direction: .horizontal, fraction: 0.5,
                         first: .leaf(groupIndex: 0),
                         second: .split(direction: .vertical, fraction: 0.3,
                                        first: .leaf(groupIndex: 2), second: .leaf(groupIndex: 1))),
            groups: [.init(tabs: ["左1", "左2"], activeIndex: 1),
                     .init(tabs: ["右下"], activeIndex: 0),
                     .init(tabs: ["右上1", "右上2"], activeIndex: 0),
                     .init(tabs: ["树里没有"], activeIndex: 0)],
            activeGroupIndex: 1)
        XCTAssertEqual(snap.tabOrder, ["左1", "左2", "右上1", "右上2", "右下"])
    }

    func test_split_on_the_mac_puts_the_new_group_after_its_source() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let model = groups([a, b, c])
        let source = model.groupIDs[0]
        model.moveTab(a, toGroup: source, zone: .trailing)
        XCTAssertEqual(model.snapshot(\.id).tabOrder, [b, c, a], "a 拖到右边成了右边一组")
        let right = try XCTUnwrap(model.locateTab(a)?.groupID)
        model.moveTab(b, toGroup: right, zone: .top)
        XCTAssertEqual(model.snapshot(\.id).tabOrder, [c, b, a], "b 拖到右边那组的上面")
    }

    // MARK: - 多个窗口

    func test_windows_go_in_the_order_they_were_opened_and_unplaced_sessions_last() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), loose = UUID()
        let ordered = TerminalTabOrder.ordered([loose, d, c, b, a], id: { $0 }, windows: [[b, a], [d, c]])
        XCTAssertEqual(ordered, [b, a, d, c, loose])
    }

    func test_registry_orders_entries_by_window_layout() {
        let registry = TerminalSessionRegistry()
        let first = UUID(), second = UUID()
        let a = UUID(), b = UUID(), c = UUID(), loose = UUID()
        for id in [c, loose, a, b] {
            registry.register(TerminalSessionEntry(id: id, serverID: UUID(), serverName: "主机", windowKind: "workspace",
                                                   title: "zsh"))
        }
        XCTAssertEqual(registry.orderedEntries().map(\.id), [c, loose, a, b], "没登记顺序时按登记先后，同旧版")

        let left = groups([b, a])
        let right = groups([c])
        registry.setTabOrder(forWindow: first) { left.snapshot(\.id).tabOrder }
        registry.setTabOrder(forWindow: second) { right.snapshot(\.id).tabOrder }
        XCTAssertEqual(registry.orderedEntries().map(\.id), [b, a, c, loose])

        registry.setTabOrder(forWindow: first) { [a, b] }
        XCTAssertEqual(registry.orderedEntries().map(\.id), [a, b, c, loose], "再登记只换入口，窗口还排第一")

        registry.forgetWindow(first)
        XCTAssertEqual(registry.orderedEntries().map(\.id), [c, loose, a, b])
    }

    // MARK: - 设备侧：只在原来的格子里换

    func test_arrangement_only_moves_this_macs_tabs_within_their_slots() {
        enum Tab: Equatable { case mac(UUID), other(String) }
        let a = UUID(), b = UUID(), c = UUID(), fresh = UUID()
        let strip: [Tab] = [.other("直连"), .mac(a), .mac(fresh), .other("文件"), .mac(b), .mac(c)]
        let arranged = RemoteTabArrangement.arranged(strip, order: [c, a, b]) { tab in
            if case .mac(let id) = tab { id } else { nil }
        }
        XCTAssertEqual(arranged, [.other("直连"), .mac(c), .mac(fresh), .other("文件"), .mac(a), .mac(b)],
                       "直连、文件标签与列表里还没有的远控标签原地不动")
    }

    // MARK: - 兼容

    func test_list_from_an_old_mac_carries_no_order() throws {
        let a = UUID(), b = UUID()
        let json = """
        [{"id":"\(a.uuidString)","serverID":"\(UUID().uuidString)","serverName":"主机","title":"zsh","windowKind":"workspace"},
         {"id":"\(b.uuidString)","serverID":"\(UUID().uuidString)","serverName":"主机","title":"zsh","windowKind":"workspace"}]
        """
        let list = try RemoteJSON.decode([RemoteSessionInfo].self, from: Data(json.utf8))
        XCTAssertNil(list.macTabOrder, "老 Mac 不发排位：设备上的标签保持原样")
        XCTAssertNil([info(a, order: 0), info(b, order: nil)].macTabOrder, "缺一条也不排")
        XCTAssertEqual([info(a, order: 1), info(b, order: 0)].macTabOrder, [b, a])
    }

    /// 老设备的 `RemoteSessionInfo` 没有 `order`：新 Mac 发来的列表照样解得出来。
    func test_old_device_decodes_a_list_with_order() throws {
        struct OldSessionInfo: Codable, Equatable {
            var id: UUID
            var serverID: UUID
            var serverName: String
            var title: String
            var windowKind: String
            var connectedAt: Date?
            var controlledBy: String?
            var tabTitle: String?
        }
        let a = UUID()
        let decoded = try RemoteJSON.decode([OldSessionInfo].self, from: RemoteJSON.encode([info(a, order: 3)]))
        XCTAssertEqual(decoded.map(\.id), [a])
    }

    // MARK: - 端到端：重排后推送

    private struct Rig {
        let registry: TerminalSessionRegistry
        let server: RemoteHostServer
        let client: RemoteMacClient
        let sessions: [TerminalSession]
    }

    private func makeRig(sessionIDs: [UUID], window: UPaneGroupsModel<UUID>?) async throws -> Rig {
        let registry = TerminalSessionRegistry()
        var sessions: [TerminalSession] = []
        for id in sessionIDs {
            let session = TerminalSession()
            await session.connect(using: MockBackend())
            sessions.append(session)
            registry.register(TerminalSessionEntry(id: id, serverID: UUID(), serverName: "测试主机",
                                                   windowKind: TerminalWindowKind.workspace, title: "zsh",
                                                   connectedAt: Date()), session: session)
        }
        if let window {
            registry.setTabOrder(forWindow: UUID()) { window.snapshot(\.id).tabOrder }
        }
        let hostIdentity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let controller = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try hostIdentity.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "这台设备",
                                          publicKey: try controller.localIdentity().publicKey.rawRepresentation,
                                          pairedAt: Date()))
        let server = RemoteHostServer(registry: registry, identity: hostIdentity, localName: "远程 Mac", localID: UUID(),
                                      advertises: false)
        server.start()
        addTeardownBlock { @MainActor in
            server.stop()
            for session in sessions { session.dispose() }
        }
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(server.port)))
        let client = RemoteMacClient(macName: "远程 Mac", endpoint: .hostPort(host: "127.0.0.1", port: port),
                                     identity: controller)
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        _ = await waitUntil { client.listedSessionIDs != nil }
        return Rig(registry: registry, server: server, client: client, sessions: sessions)
    }

    func test_reordering_on_the_mac_pushes_the_new_order() async throws {
        let a = UUID(), b = UUID(), c = UUID()
        let window = groups([b, c, a])
        let rig = try await makeRig(sessionIDs: [a, b, c], window: window)
        defer { rig.client.disconnect() }
        XCTAssertEqual(rig.client.sessions.macTabOrder, [b, c, a], "第一份列表就是 Mac 上的顺序")
        XCTAssertEqual(rig.client.listedSessionIDs, [b, c, a], "列表本身也按它排，老设备接管时照着开")

        window.reorderTab(a, before: b)
        let reordered = await waitUntil { rig.client.sessions.macTabOrder == [a, b, c] }
        XCTAssertTrue(reordered, "重排后推一份新列表")

        let group = window.groupIDs[0]
        window.moveTab(a, toGroup: group, zone: .trailing)
        let split = await waitUntil { rig.client.sessions.macTabOrder == [b, c, a] }
        XCTAssertTrue(split, "拆到右边一组：排到左边那组后面")

        // 新开的标签：跟着列表一起到，排在它在 Mac 上的位置。
        let d = UUID()
        let session = TerminalSession()
        await session.connect(using: MockBackend())
        defer { session.dispose() }
        window.openTab({ UPaneTab(id: d, payload: d) }, in: group)
        rig.registry.register(TerminalSessionEntry(id: d, serverID: UUID(), serverName: "测试主机",
                                                   windowKind: TerminalWindowKind.workspace, title: "zsh",
                                                   connectedAt: Date()), session: session)
        let opened = await waitUntil { rig.client.sessions.macTabOrder == [b, c, d, a] }
        XCTAssertTrue(opened)
    }

    func test_mac_without_window_layouts_keeps_registration_order() async throws {
        let a = UUID(), b = UUID()
        let rig = try await makeRig(sessionIDs: [a, b], window: nil)
        defer { rig.client.disconnect() }
        XCTAssertEqual(rig.client.sessions.macTabOrder, [a, b])
    }

    // MARK: - Mac 控制 Mac

    func test_mac_controller_window_follows_the_order_without_switching_tabs() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let client = RemoteMacClient(macName: "远程 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        client.receiveSessions([info(a, order: 0), info(b, order: 1), info(c, order: 2)])
        let model = RemoteMacWindowModel(client: client) { _ in }
        defer { model.disposeAll() }
        model.takeOver()
        XCTAssertEqual(model.panes.map(\.id), [a, b, c])
        model.open(b, activate: true)

        client.receiveSessions([info(a, order: 2), info(b, order: 0), info(c, order: 1)])
        model.follow(client.listedSessionIDs, order: client.sessions.macTabOrder)
        XCTAssertEqual(model.panes.map(\.id), [b, c, a])
        XCTAssertEqual(model.active?.id, b, "正看着的标签不被切走")

        // 拆出另一组（a 在右边那组，正看着它）之后：两组各排各的，各组的前台和活动组都不变。
        let first = model.groups.groupIDs[0]
        model.groups.moveTab(a, toGroup: first, zone: .trailing)
        XCTAssertEqual(model.active?.id, a)
        let leftFront = model.groups.groups[first]?.activeTab?.id
        client.receiveSessions([info(a, order: 0), info(c, order: 1), info(b, order: 2)])
        model.follow(client.listedSessionIDs, order: client.sessions.macTabOrder)
        XCTAssertEqual(model.groups.groups[first]?.tabs.map(\.id), [c, b])
        XCTAssertEqual(model.groups.groups[first]?.activeTab?.id, leftFront)
        XCTAssertEqual(model.active?.id, a, "活动组还是右边那组")

        // 老 Mac 不发排位：不动。
        client.receiveSessions([info(b, order: nil), info(c, order: nil), info(a, order: nil)])
        model.follow(client.listedSessionIDs, order: client.sessions.macTabOrder)
        XCTAssertEqual(model.groups.groups[first]?.tabs.map(\.id), [c, b])
    }

    /// 同手机：用户在这扇窗口里亲手拖过标签，之后 Mac 推来的顺序不再覆盖；新开、关掉的照常跟。
    func test_mac_controller_window_keeps_tabs_arranged_by_hand() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let client = RemoteMacClient(macName: "远程 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        client.receiveSessions([info(a, order: 0), info(b, order: 1), info(c, order: 2)])
        let model = RemoteMacWindowModel(client: client) { _ in }
        defer { model.disposeAll() }
        model.takeOver()
        XCTAssertFalse(model.isArrangedByHand)

        // 把 c 拖到最前。
        model.groups.reorderTab(c, before: a)
        XCTAssertEqual(model.panes.map(\.id), [c, a, b])

        client.receiveSessions([info(a, order: 0), info(b, order: 1), info(c, order: 2), info(d, order: 3)])
        model.follow(client.listedSessionIDs, order: client.sessions.macTabOrder)
        XCTAssertTrue(model.isArrangedByHand)
        XCTAssertEqual(model.panes.map(\.id).filter { $0 != d }, [c, a, b], "亲手排的顺序不被 Mac 的覆盖")
        XCTAssertTrue(model.panes.contains { $0.id == d }, "新开的照常加标签")

        client.receiveSessions([info(b, order: 0), info(a, order: 1), info(d, order: 2)])
        model.follow(client.listedSessionIDs, order: client.sessions.macTabOrder)
        XCTAssertFalse(model.panes.contains { $0.id == c }, "关掉的照常摘")
        XCTAssertEqual(model.panes.map(\.id).filter { $0 != d }, [a, b])
    }
}
