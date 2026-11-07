import XCTest
@preconcurrency import Network
@testable import uTerm

/// Mac 当主控端：整台接管另一台 Mac 的终端、跟着它增减。窗口模型连真实的 `RemoteHostServer`（127.0.0.1），
/// 标签的接入（`RemoteTerminalPane.start`）换成记录，只看模型怎么摆标签。
@MainActor
final class RemoteMacControllerTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: - 对账

    func test_follower_opens_new_closes_gone_and_waits_for_terminals_opened_before_the_list() {
        let a = UUID(), b = UUID(), fresh = UUID()
        var follower = RemoteSessionFollower(takingOver: [a, b])
        var step = follower.update([a])
        XCTAssertEqual(step.gone, [], "b 还没在列表里出现过：不能当它关了")
        XCTAssertEqual(step.fresh, [], "a 已经开着")
        step = follower.update([a, b, fresh])
        XCTAssertEqual(step.fresh, [fresh], "b 第一次出现不再开一个")
        step = follower.update([b, fresh])
        XCTAssertEqual(step.gone, [a])
        step = follower.update([b, fresh, a])
        XCTAssertEqual(step.fresh, [a], "关掉后回来的算新的")
    }

    func test_mac_controller_never_replaces_its_own_relay() {
        let mine = RemoteRelayConfig(name: "我的", host: "a.example", port: 47310, relayID: "A", key: "k1")
        let theirs = RemoteRelayConfig(name: "别人的", host: "b.example", port: 47310, relayID: "B", key: "k2")
        XCTAssertEqual(RemoteRelayPlacement.place(theirs, current: nil, adoptsAsDefault: false), .perHost,
                       "Mac 的默认中继也是它自己被控时注册的那台，去控制别人不能换掉")
        XCTAssertEqual(RemoteRelayPlacement.place(mine, current: mine, adoptsAsDefault: false), .keep)
    }

    // MARK: - 窗口模型

    private struct Rig {
        let registry: TerminalSessionRegistry
        let server: RemoteHostServer
        let client: RemoteMacClient
        var sessions: [UUID: TerminalSession]
    }

    private func register(_ id: UUID, in registry: TerminalSessionRegistry) async -> TerminalSession {
        let session = TerminalSession()
        await session.connect(using: MockBackend())
        registry.register(TerminalSessionEntry(id: id, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh",
                                               connectedAt: Date()), session: session)
        return session
    }

    private func makeRig(sessionIDs: [UUID]) async throws -> Rig {
        let registry = TerminalSessionRegistry()
        var sessions: [UUID: TerminalSession] = [:]
        for id in sessionIDs { sessions[id] = await register(id, in: registry) }
        let hostIdentity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let controller = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try hostIdentity.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "这台 Mac",
                                          publicKey: try controller.localIdentity().publicKey.rawRepresentation,
                                          pairedAt: Date()))
        let server = RemoteHostServer(registry: registry, identity: hostIdentity, localName: "远程 Mac", localID: UUID(),
                                      advertises: false)
        server.start()
        addTeardownBlock { @MainActor in
            server.stop()
            for session in sessions.values { session.dispose() }
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

    func test_window_takes_over_every_terminal_and_follows_the_remote_list() async throws {
        let a = UUID(), b = UUID()
        var rig = try await makeRig(sessionIDs: [a, b])
        defer { rig.client.disconnect() }
        var started: [UUID] = []
        let model = RemoteMacWindowModel(client: rig.client) { started.append($0.id) }

        model.takeOver()
        XCTAssertEqual(Set(model.panes.map(\.id)), [a, b])
        XCTAssertEqual(Set(started), [a, b])
        model.takeOver()
        XCTAssertEqual(model.panes.count, 2, "重连后再调不重复开")

        // 那台 Mac 上新开一个终端：后台加标签，不抢前台。
        let front = model.active?.id
        let c = UUID()
        rig.sessions[c] = await register(c, in: rig.registry)
        let opened = await waitUntil {
            model.follow(rig.client.listedSessionIDs)
            return model.panes.contains { $0.id == c }
        }
        XCTAssertTrue(opened)
        XCTAssertEqual(model.active?.id, front)

        // 那台 Mac 上关掉一个：标签跟着摘。
        rig.registry.unregister(id: a)
        let closed = await waitUntil {
            model.follow(rig.client.listedSessionIDs)
            return !model.panes.contains { $0.id == a }
        }
        XCTAssertTrue(closed)

        // 本机关掉的标签不会因为列表还有它而再开回来。
        XCTAssertTrue(model.close(b))
        model.follow(rig.client.listedSessionIDs)
        XCTAssertFalse(model.panes.contains { $0.id == b })
        XCTAssertNotNil(rig.client.sessions.first { $0.id == b }, "只断开接入，那台 Mac 上的终端还在")
        model.disposeAll()
    }

    func test_opening_a_terminal_that_is_already_open_brings_it_forward() async throws {
        let a = UUID(), b = UUID()
        let rig = try await makeRig(sessionIDs: [a, b])
        defer { rig.client.disconnect() }
        let model = RemoteMacWindowModel(client: rig.client) { _ in }
        model.takeOver()
        model.open(b, activate: true)
        XCTAssertEqual(model.panes.count, 2)
        XCTAssertEqual(model.active?.id, b)
        model.disposeAll()
    }
}
