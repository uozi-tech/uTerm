import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远控进程（`RemoteHostAgentService`）与 App 侧的桥（`RemoteHostAgentBridge`）经真实的 XPC 连接（同一进程里的
/// 匿名监听器）配合：手机连的是远控进程里的服务端，终端字节来自 App 的会话。重点是 App 走掉、再回来时，
/// 手机那条远控连接不断、终端画面续上。
@MainActor
final class RemoteHostAgentTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func emit(_ bytes: Data, to backend: MockBackend) async {
        for start in stride(from: 0, to: bytes.count, by: 433) {
            await backend.emitOutput(bytes.subdata(in: start..<min(bytes.count, start + 433)))
        }
    }

    private func same(_ mac: ShadowTerminal, _ phone: MirrorPhone, fedBytes: Int = 0) -> Bool {
        mac.totalFedBytes >= fedBytes && mac.mirrorDifferences(from: phone.shadow).isEmpty
    }

    /// 一套「App + 远控进程」：App 侧有注册表里的一个会话、一个 `RemoteHostServer`（只镜像状态）和桥；
    /// 远控进程侧是服务与它建起来的服务端。
    @MainActor
    private final class Rig {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let macBackend = MockBackend()
        let sessionID = UUID()
        let appServer: RemoteHostServer
        let settings: RemoteControlSettings
        let service: RemoteHostAgentService
        let listener = NSXPCListener.anonymous()
        var bridge: RemoteHostAgentBridge?
        var terminated = false
        /// 远控进程「本进程」的授权与申请记录（替代真的 CGPreflight / CGRequest）。
        let permissions = AgentPermissionBox()
        private let suites: [String]

        init(grace: Duration) async {
            let suite = "uterm.tests.agent.\(UUID().uuidString)"
            let appSuite = "uterm.tests.agent-app.\(UUID().uuidString)"
            suites = [suite, appSuite]
            let appDefaults = UserDefaults(suiteName: appSuite)!
            settings = RemoteControlSettings(defaults: appDefaults)
            settings.isEnabled = true
            appServer = RemoteHostServer(registry: registry,
                                         identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                         localName: "测试 Mac", localID: UUID(), advertises: false,
                                         relayRevocations: RemoteRelayRevocations(defaults: appDefaults))
            var environment = RemoteHostAgentService.Environment(
                settingsDefaults: UserDefaults(suiteName: suite)!,
                makeDesktopEnvironment: { _ in .disabled },
                makeFileAccess: { _ in .unavailable },
                attachPanels: { _ in },
                clientRequirement: nil,
                terminate: {})
            environment.advertises = false
            environment.defaultGrace = grace
            environment.updateGrace = grace
            environment.requestTimeout = .seconds(3)
            environment.build = "agent-test"
            let permissions = self.permissions
            environment.desktopPermissions = { permissions.current }
            environment.requestPostEvents = { permissions.requests += 1 }
            service = RemoteHostAgentService(environment: environment)
            listener.delegate = service
            listener.resume()
            await session.connect(using: macBackend)
            registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                                   windowKind: TerminalWindowKind.workspace, title: "zsh",
                                                   connectedAt: Date()), session: session)
        }

        /// 起一个 App 侧的桥（App 启动 / 重启）。
        func startApp(restoration: (@MainActor () async -> Void)? = nil, restoresEagerly: Bool = true) {
            let endpoint = listener.endpoint
            let bridge = RemoteHostAgentBridge(
                server: appServer, registry: registry, settings: settings, restoration: restoration,
                transport: .init(makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) }, serverRequirement: nil),
                restoresEagerly: restoresEagerly, appBuild: "agent-test")
            self.bridge = bridge
            bridge.start()
            bridge.settingsChanged()
        }

        var agentServer: RemoteHostServer? { service.server }

        func tearDown() {
            bridge?.simulateAppTermination()
            service.shutdown(reason: "测试结束")
            listener.invalidate()
            session.dispose()
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        }
    }

    func test_app_leaving_and_returning_keeps_phone_link_and_resumes_terminal() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        rig.startApp()
        let listening = await waitUntil { rig.agentServer?.port != nil && rig.appServer.status == .listening }
        XCTAssertTrue(listening, "远控进程应按 App 交来的设置开始监听，App 侧照着显示")
        let port = try XCTUnwrap(rig.agentServer?.port)
        XCTAssertEqual(rig.appServer.port, port, "App 侧镜像端口")

        // 手机首次连接：审批框的请求出现在 App 侧（镜像），在 App 侧点允许，经远控进程放行。
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { !rig.appServer.pairingRequests.isEmpty }
        XCTAssertTrue(asked, "配对请求应镜像到 App 侧")
        rig.appServer.approvePairing(try XCTUnwrap(rig.appServer.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        let trusted = await waitUntil { rig.appServer.trustedPeers.count == 1 }
        XCTAssertTrue(trusted, "新配对的设备应写回 App 的身份存储")
        let connected = await waitUntil { rig.appServer.connectedDevices.count == 1 }
        XCTAssertTrue(connected, "已连接的设备应镜像到 App 侧")
        let listed = await waitUntil { client.sessions.map(\.id) == [rig.sessionID] }
        XCTAssertTrue(listed, "会话目录经 App → 远控进程 → 手机")

        // 接入：字节从 App 的会话经 XPC 到远控进程，再上链路。
        let backend = RemoteTerminalBackend(client: client, sessionID: rig.sessionID)
        let phone = MirrorPhone(cols: 64, rows: 20)
        await backend.resize(cols: 64, rows: 20)
        try await backend.connect()
        phone.start(backend.outputItems)
        defer { phone.stop() }
        let mac = rig.session.shadow
        XCTAssertEqual(mac.size.cols, 64)
        let mixed = try TerminalCorpus.bytes("mixed")
        await emit(mixed, to: rig.macBackend)
        var fedBytes = mixed.count
        let mirrored = await waitUntil { self.same(mac, phone, fedBytes: fedBytes) }
        XCTAssertTrue(mirrored, "接入后画面不一致：\(mac.mirrorDifferences(from: phone.shadow))")
        await backend.write(Data("pwd\r".utf8))
        let wrote = await waitUntil { await rig.macBackend.writtenData.contains(Data("pwd\r".utf8)) }
        XCTAssertTrue(wrote, "手机的输入经远控进程回到 App 的会话")

        // App 走了（被结束、更新）：手机的连接不断，期间的输出没有送到手机。
        rig.bridge?.simulateAppTermination()
        let shell = try TerminalCorpus.bytes("shell")
        await emit(shell, to: rig.macBackend)
        fedBytes += shell.count
        let dropped = await waitUntil(1.5) { client.state != .connected }
        XCTAssertFalse(dropped, "App 不在时手机的远控连接应保持")
        XCTAssertEqual(rig.agentServer?.connectedPeerIDs.count, 1)

        // App 回来：远控进程按同一个会话重新接入，第一段是新快照，画面续上；之后的输出照常同步。
        let snapshotsBefore = phone.snapshots
        rig.startApp()
        let resumed = await waitUntil(10) { phone.snapshots > snapshotsBefore && self.same(mac, phone, fedBytes: fedBytes) }
        XCTAssertTrue(resumed, "App 回来后画面应续上：\(mac.mirrorDifferences(from: phone.shadow))")
        XCTAssertEqual(client.state, .connected, "整个过程手机没有重连")
        let more = Data("\r\nafter-return\r\n".utf8)
        await emit(more, to: rig.macBackend)
        fedBytes += more.count
        let synced = await waitUntil { self.same(mac, phone, fedBytes: fedBytes) }
        XCTAssertTrue(synced, "回来之后的输出照常同步")
        XCTAssertEqual(phone.pump.currentStats.rejectedSnapshots, 0)
        client.disconnect()
    }

    /// 2.1.1 实测（17:17）：`kill -9` 之后被命令行在后台唤起的 App 先连上远控进程，那时它还没把终端接回来
    /// （后台唤起不开窗口、不接回），报了一份空的「已接回」列表，远控进程据此把手机上的终端关掉了。现在后台唤起的 App
    /// 等远控进程来要再接回，接回之前远控进程照旧用上一份列表，接回之后画面续上。
    func test_background_app_restores_on_request_and_phone_terminal_resumes() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        rig.startApp()
        let listening = await waitUntil { rig.agentServer?.port != nil }
        XCTAssertTrue(listening)
        let port = try XCTUnwrap(rig.agentServer?.port)
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { !rig.appServer.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        rig.appServer.approvePairing(try XCTUnwrap(rig.appServer.pairingRequests.first?.id))
        await connecting.value
        defer { client.disconnect() }
        let listed = await waitUntil { client.sessions.map(\.id) == [rig.sessionID] }
        XCTAssertTrue(listed)
        let backend = RemoteTerminalBackend(client: client, sessionID: rig.sessionID)
        let phone = MirrorPhone(cols: 64, rows: 20)
        await backend.resize(cols: 64, rows: 20)
        try await backend.connect()
        phone.start(backend.outputItems)
        defer { phone.stop() }
        let mac = rig.session.shadow
        let mixed = try TerminalCorpus.bytes("mixed")
        await emit(mixed, to: rig.macBackend)
        let mirrored = await waitUntil { mac.mirrorDifferences(from: phone.shadow).isEmpty && mac.totalFedBytes >= mixed.count }
        XCTAssertTrue(mirrored)
        let exitStream = backend.exitStream
        let ended = Task { () -> Bool in
            for await _ in exitStream { return true }
            return false
        }

        // App 被结束；新的 App 在后台起来，注册表里还没有这个会话（还没接回）。
        rig.bridge?.simulateAppTermination()
        let entry = try XCTUnwrap(rig.registry.entries.first { $0.id == rig.sessionID })
        rig.registry.unregister(id: rig.sessionID)
        let shell = try TerminalCorpus.bytes("shell")
        await emit(shell, to: rig.macBackend)
        let requested = Recorder()
        let release = AsyncGate()
        let registry = rig.registry, session = rig.session
        rig.startApp(restoration: {
            requested.append("restore")
            await release.wait()
            registry.register(entry, session: session)
        }, restoresEagerly: false)

        let asksToRestore = await waitUntil(5) { !requested.items.isEmpty }
        XCTAssertTrue(asksToRestore, "有暂停着的接入：远控进程应请后台唤起的 App 把终端接回来")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(client.sessions.map(\.id), [rig.sessionID], "接回之前远控进程照旧用上一份列表，不报会话没了")
        XCTAssertEqual(client.state, .connected)

        let snapshotsBefore = phone.snapshots
        release.open()
        let resumed = await waitUntil(10) {
            phone.snapshots > snapshotsBefore && mac.mirrorDifferences(from: phone.shadow).isEmpty
                && mac.totalFedBytes >= mixed.count + shell.count
        }
        XCTAssertTrue(resumed, "接回之后画面续上：\(mac.mirrorDifferences(from: phone.shadow))")
        ended.cancel()
        XCTAssertEqual(client.state, .connected, "手机的终端没有结束")
        let didEnd = await ended.value
        XCTAssertFalse(didEnd, "手机的终端没有结束")
    }

    func test_service_stops_after_grace_when_app_does_not_return() async throws {
        let rig = await Rig(grace: .seconds(1))
        defer { rig.tearDown() }
        rig.startApp()
        let listening = await waitUntil { rig.agentServer?.port != nil }
        XCTAssertTrue(listening)
        rig.bridge?.simulateAppTermination()
        XCTAssertFalse(rig.service.isShutDown, "宽限期内照常服务")
        let stopped = await waitUntil(5) { rig.service.isShutDown }
        XCTAssertTrue(stopped, "App 没回来，宽限期到就停止服务")
        XCTAssertEqual(rig.agentServer?.status, .stopped)
    }

    func test_quit_departure_stops_service_immediately() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        rig.startApp()
        let listening = await waitUntil { rig.agentServer?.port != nil && rig.bridge?.isConnected == true }
        XCTAssertTrue(listening)
        rig.bridge?.depart(.quit)
        rig.bridge?.simulateAppTermination()
        let stopped = await waitUntil(5) { rig.service.isShutDown }
        XCTAssertTrue(stopped, "用户退出 uTerm 时远控随之结束")
    }

    func test_turning_remote_off_shuts_the_agent_down() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        rig.startApp()
        let listening = await waitUntil { rig.agentServer?.port != nil && rig.bridge?.isConnected == true }
        XCTAssertTrue(listening)
        rig.settings.isEnabled = false
        rig.bridge?.settingsChanged()
        let stopped = await waitUntil(3) { rig.service.isShutDown }
        XCTAssertTrue(stopped, "关掉远控时远控进程停服务并退出，不常驻")
        let quiet = await waitUntil(1) { rig.bridge?.isConnected == true }
        XCTAssertFalse(quiet, "远控关着时 App 不再去连远控进程")
    }

    // MARK: - 被控端授权

    /// 远控进程在服务时，「辅助功能」以它报的为准（tccd 按它自己的身份判，uTerm 的授权替不了），申请也由它发起。
    func test_permissions_come_from_the_agent_and_post_event_request_goes_to_it() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        rig.permissions.current = RemoteHostAgentPermissions(screenCapture: true, postEvents: false)
        rig.startApp()
        let connected = await waitUntil { rig.bridge?.isConnected == true }
        XCTAssertTrue(connected)
        let bridge = try XCTUnwrap(rig.bridge)
        let localGranted = RemoteHostAgentPermissions(screenCapture: true, postEvents: true)

        let before = await RemoteHostPermissionSource.current(agent: bridge, local: { localGranted })
        XCTAssertEqual(before, RemoteHostAgentPermissions(screenCapture: true, postEvents: false),
                       "App 自己有辅助功能也不算：注入在远控进程里做")

        var localRequests = 0
        await RemoteHostPermissionSource.requestPostEvents(agent: bridge, local: { localRequests += 1 })
        XCTAssertEqual(rig.permissions.requests, 1, "由远控进程申请，系统设置里登记的是「uTerm 远程控制」")
        XCTAssertEqual(localRequests, 0)

        rig.permissions.current.postEvents = true
        let after = await RemoteHostPermissionSource.current(agent: bridge, local: { localGranted })
        XCTAssertTrue(after.postEvents)
    }

    /// 远控进程刚起、App 还没握手（服务端没建）时，授权查询也照答。
    func test_agent_answers_permissions_before_hello() async {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        rig.permissions.current = RemoteHostAgentPermissions(screenCapture: false, postEvents: true)
        let reply = await rig.service.perform(.desktopPermissions)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.data.flatMap { RemoteHostAgentJSON.decode(RemoteHostAgentPermissions.self, from: $0) },
                       rig.permissions.current)
    }

    func test_chunk_kind_round_trips_and_feed_splits_without_losing_snapshot_flags() {
        let chunks: [RemoteTerminalChunk] = [.output(Data([1, 2])), .snapshot(Data([3]), isFirst: true, isLast: false),
                                             .snapshot(Data([4]), isFirst: false, isLast: false),
                                             .snapshot(Data([5]), isFirst: false, isLast: true),
                                             .snapshot(Data([6]), isFirst: true, isLast: true)]
        for chunk in chunks {
            let kind = RemoteHostTerminalChunkKind(chunk)
            let data: Data = switch chunk { case .output(let d), .snapshot(let d, _, _): d }
            XCTAssertEqual(kind.chunk(data), chunk)
        }
        let granted = Counter()
        let feed = ForwardedFeed(onReadable: {})
        feed.grant = { bytes in granted.add(bytes) }
        feed.append(.snapshot(Data(repeating: 7, count: 10), isFirst: true, isLast: true))
        XCTAssertEqual(feed.take(maxBytes: 4), .snapshot(Data(repeating: 7, count: 4), isFirst: true, isLast: false))
        XCTAssertEqual(feed.take(maxBytes: 4), .snapshot(Data(repeating: 7, count: 4), isFirst: false, isLast: false))
        XCTAssertEqual(feed.take(maxBytes: 4), .snapshot(Data(repeating: 7, count: 2), isFirst: false, isLast: true))
        XCTAssertNil(feed.take(maxBytes: 4))
        XCTAssertEqual(granted.value, 10, "取走多少就还多少信用")
    }

    func test_mirrored_secret_storage_keeps_unflushed_writes_over_app_snapshot() throws {
        let storage = RemoteMirroredSecretStorage(values: ["trustedPeers": Data([1])])
        let saved = Recorder()
        storage.onSave = { account, _ in saved.append(account) }
        try storage.save(Data([2]), account: "trustedPeers")
        storage.replaceAll(["trustedPeers": Data([1]), "identity": Data([9])], keeping: ["trustedPeers"])
        XCTAssertEqual(try storage.load("trustedPeers"), Data([2]), "App 还没落盘的写入以远控进程为准")
        XCTAssertEqual(try storage.load("identity"), Data([9]))
        XCTAssertEqual(saved.items, ["trustedPeers"])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ n: Int) { lock.withLock { total += n } }
    var value: Int { lock.withLock { total } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ s: String) { lock.withLock { list.append(s) } }
    var items: [String] { lock.withLock { list } }
}

/// 测试里手动放行的闸门。
@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

@MainActor
private final class AgentPermissionBox {
    var current = RemoteHostAgentPermissions(screenCapture: true, postEvents: false)
    var requests = 0
}
