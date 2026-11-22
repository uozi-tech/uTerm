import CryptoKit
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
        func startApp(restoration: (@MainActor () async -> Void)? = nil, restoresEagerly: Bool = true,
                      appBuild: String = "agent-test", endpoint: NSXPCListenerEndpoint? = nil,
                      restartAgent: (@MainActor () -> Void)? = nil,
                      helloTimeout: Duration = RemoteHostAgent.helloTimeout) {
            let endpoint = endpoint ?? listener.endpoint
            let bridge = RemoteHostAgentBridge(
                server: appServer, registry: registry, settings: settings, restoration: restoration,
                transport: .init(makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) }, serverRequirement: nil,
                                 restartAgent: restartAgent, helloTimeout: helloTimeout),
                restoresEagerly: restoresEagerly, appBuild: appBuild)
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

    /// 设备上亲手排过 Mac 的标签：请求经远控进程转给 App，App 的窗口照着排（`TerminalSessionRegistry.arrangeTabs`）。
    func test_device_arrangement_reaches_the_app_windows_through_the_agent() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        let other = UUID()
        rig.registry.register(TerminalSessionEntry(id: other, serverID: UUID(), serverName: "测试主机",
                                                   windowKind: TerminalWindowKind.workspace, title: "zsh",
                                                   connectedAt: Date()))
        var arranged: [[UUID]] = []
        rig.registry.setArranger(forWindow: UUID()) { arranged.append($0) }
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
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(client.supportsArrangeSessions, "远控进程也声明了这项能力")

        client.arrangeSessionsOnMac([other, rig.sessionID])
        let delivered = await waitUntil { arranged == [[other, rig.sessionID]] }
        XCTAssertTrue(delivered, "排序请求经远控进程交到 App 的窗口：\(arranged)")
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

    // MARK: - 换包（Sparkle 更新）

    /// 2.1.5 实测（2026-11-15）：Sparkle 换包后旧远控进程留着服务，新 App 按签名核对它失败（-67065），
    /// 一直重连；tccd 也不认它的屏幕录制授权，手机开屏幕报「用户拒绝」。新 App 连上时版本对不上，旧进程就该退出。
    func test_agent_exits_when_app_returns_as_a_different_build() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        rig.startApp()
        let connected = await waitUntil { rig.agentServer?.port != nil && rig.bridge?.isConnected == true }
        XCTAssertTrue(connected)
        rig.bridge?.depart(.update)
        rig.bridge?.simulateAppTermination()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(rig.service.isShutDown, "App 更新期间照常服务")

        rig.startApp(appBuild: "agent-test-next")
        let stopped = await waitUntil(5) { rig.service.isShutDown }
        XCTAssertTrue(stopped, "新版 App 连上时旧远控进程退出，让 launchd 换成包里的新版本")
        XCTAssertEqual(rig.agentServer?.status, .stopped)
        XCTAssertEqual(rig.bridge?.isConnected, false, "退出的旧进程不算连上")
    }

    /// 已经卡住的旧远控进程（2.1.5 及以前不会自己退出）：连得上、回话全被拒收。App 连续几次等不到握手回话，
    /// 就请 launchd 换掉它；只换一次。
    func test_app_restarts_agent_that_never_answers_hello() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        let silent = NSXPCListener.anonymous()
        let rejecting = RejectingListener()
        silent.delegate = rejecting
        silent.resume()
        defer { silent.invalidate() }
        var restarts = 0
        rig.startApp(endpoint: silent.endpoint, restartAgent: { restarts += 1 })
        let restarted = await waitUntil(6) { restarts > 0 }
        XCTAssertTrue(restarted, "连续 \(RemoteHostAgent.unansweredHelloLimit) 次不回话就换掉远控进程")
        XCTAssertGreaterThanOrEqual(rejecting.count, RemoteHostAgent.unansweredHelloLimit)
        let attempts = rejecting.count
        let retried = await waitUntil(6) { rejecting.count > attempts }
        XCTAssertTrue(retried, "换完照常重连")
        XCTAssertEqual(restarts, 1, "这次启动里只换一次")
        XCTAssertEqual(rig.bridge?.isConnected, false)
    }

    /// launchd 拉不起远控进程（任务挂在已删掉的开发构建上、启动约束和签名对不上）：连接不断也不回话，一直排队。
    /// 握手超时要把它算成不回话，攒够了照样注销再注册，不能永远停在「正在连接」。
    func test_app_restarts_agent_whose_hello_hangs() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        let hanging = NSXPCListener.anonymous()
        let accepting = HangingAgentListener()
        hanging.delegate = accepting
        hanging.resume()
        defer { hanging.invalidate() }
        var restarts = 0
        rig.startApp(endpoint: hanging.endpoint, restartAgent: { restarts += 1 }, helloTimeout: .milliseconds(300))
        let restarted = await waitUntil(8) { restarts > 0 }
        XCTAssertTrue(restarted, "握手超时 \(RemoteHostAgent.unansweredHelloLimit) 次也要换掉远控进程")
        XCTAssertGreaterThanOrEqual(accepting.hellos, RemoteHostAgent.unansweredHelloLimit)
        XCTAssertEqual(rig.bridge?.isConnected, false)
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

    /// 担保在远控进程里处理：信任表和担保记录经 `persistSecret` 写回 App，App 比对出新记录发通知；
    /// 新设备随后连远控进程不弹审批；App 设置里关掉担保，远控进程跟着拒绝。
    func test_vouch_handled_by_the_agent_is_written_back_and_notified_in_the_app() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        var notified: [RemotePeerVouch] = []
        rig.appServer.onDeviceVouched = { notified.append($0) }
        rig.startApp()
        let listening = await waitUntil { rig.agentServer?.port != nil && rig.appServer.status == .listening }
        XCTAssertTrue(listening)
        let port = try XCTUnwrap(rig.agentServer?.port)
        func client(_ id: UUID, _ name: String, _ identity: RemoteIdentityStore) -> RemoteMacClient {
            let client = RemoteMacClient(macName: "测试 Mac",
                                         endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                         identity: identity)
            client.localDeviceOverride = (id, name)
            return client
        }
        let phone = client(UUID(), "iPhone", RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await phone.connect() }
        let asked = await waitUntil { !rig.appServer.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        rig.appServer.approvePairing(try XCTUnwrap(rig.appServer.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(phone.state, .connected)

        let padID = UUID()
        let padIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let pad = RemoteGroupDevice(id: padID, name: "iPad", model: nil, platform: "mobile",
                                    publicKey: try padIdentity.localIdentity().publicKey.rawRepresentation,
                                    signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, updatedAt: Date())
        let result = try await phone.vouch(for: pad)
        XCTAssertEqual(result.kind, .added, "设置默认允许担保：\(result.reason ?? "")")
        let written = await waitUntil { rig.appServer.peerVouches[padID] != nil && rig.appServer.trustedPeers.count == 2 }
        XCTAssertTrue(written, "信任表与担保记录应写回 App")
        XCTAssertEqual(notified.map(\.deviceID), [padID], "App 侧发一次通知")

        let padClient = client(padID, "iPad", padIdentity)
        let padConnecting = Task { await padClient.connect() }
        await padConnecting.value
        XCTAssertEqual(padClient.state, .connected)
        XCTAssertTrue(rig.appServer.pairingRequests.isEmpty, "被担保的设备不弹审批")

        rig.settings.isDeviceVouchingEnabled = false
        rig.bridge?.settingsChanged()
        // 设置要经 XPC 交过去，期间担保还可能成功：每次换一台新设备问，直到被拒。
        let refused = await waitUntil {
            let other = RemoteGroupDevice(id: UUID(), name: "Mac", model: nil, platform: "mac",
                                          publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                          signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                                          updatedAt: Date())
            guard let result = try? await phone.vouch(for: other) else { return false }
            return result.kind == .notAllowed
        }
        XCTAssertTrue(refused, "App 里关掉担保，远控进程跟着拒绝")
        phone.disconnect()
        padClient.disconnect()
    }

    /// 设备组（App 里算的）让远控进程把组员记成主控端、撤掉被移除的：经 XPC 新加的两个操作转过去，
    /// 远控进程的信任表与担保记录写回 App；记下的设备不弹审批，撤掉的断开且不拉黑。同组撤销（消息 52）在远控进程里
    /// 执行，同样不拉黑。
    func test_device_group_controllers_travel_to_the_agent_and_back() async throws {
        let rig = await Rig(grace: .seconds(30))
        defer { rig.tearDown() }
        var notified: [RemotePeerVouch] = []
        rig.appServer.onDeviceVouched = { notified.append($0) }
        rig.startApp()
        let listening = await waitUntil { rig.agentServer?.port != nil && rig.appServer.status == .listening }
        XCTAssertTrue(listening)
        let port = try XCTUnwrap(rig.agentServer?.port)

        let padID = UUID()
        let padIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let padKey = try padIdentity.localIdentity().publicKey.rawRepresentation
        let request = RemoteVouchRequest(requestID: UUID(), deviceID: padID, name: "iPad", model: nil, platform: "mobile",
                                         publicKey: padKey)
        let added = await rig.appServer.groupAddController(request)
        XCTAssertEqual(added?.kind, .added, added?.reason ?? "转不过去")
        let written = await waitUntil { rig.appServer.peerVouches[padID] != nil && rig.appServer.identity.peer(id: padID) != nil }
        XCTAssertTrue(written, "远控进程写回 App")
        XCTAssertTrue(rig.appServer.peerVouches[padID]?.isFromDeviceGroup(hostID: rig.appServer.localID) ?? false)
        XCTAssertEqual(notified.map(\.deviceID), [padID])
        XCTAssertEqual(rig.appServer.groupControllerPeers().first { $0.id == padID }?.isFromGroup, true)

        let pad = RemoteMacClient(macName: "测试 Mac",
                                  endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                  identity: padIdentity)
        pad.localDeviceOverride = (padID, "iPad")
        let connecting = Task { await pad.connect() }
        await connecting.value
        XCTAssertEqual(pad.state, .connected)
        XCTAssertTrue(rig.appServer.pairingRequests.isEmpty, "设备组记下的不弹审批")

        // iPad 经消息 50 担保了一台谁都不知道的设备 Z。
        let zID = UUID()
        let zKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let z = RemoteGroupDevice(id: zID, name: "Z", model: nil, platform: "mobile", publicKey: zKey,
                                  signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, updatedAt: Date())
        let zAdded = try await pad.vouch(for: z)
        XCTAssertEqual(zAdded.kind, .added)
        _ = await waitUntil { rig.appServer.identity.peer(id: zID) != nil }

        let dropped = await rig.appServer.groupDropController(RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: padID,
                                                                                         publicKey: padKey))
        XCTAssertEqual(dropped?.kind, .revoked)
        let gone = await waitUntil {
            rig.appServer.identity.peer(id: padID) == nil && rig.appServer.identity.peer(id: zID) == nil
                && pad.state != .connected
        }
        XCTAssertTrue(gone, "撤掉（连同它担保的 Z）、断开，写回 App")
        XCTAssertNil(rig.agentServer?.identity.peer(id: zID), "远控进程里也撤了")
        XCTAssertFalse(rig.appServer.identity.isBlocked(zID))
        XCTAssertFalse(rig.appServer.identity.isBlocked(padID))
        XCTAssertFalse(rig.agentServer?.identity.isBlocked(padID) ?? true, "远控进程里也没拉黑")
        let again = await rig.appServer.groupAddController(request)
        XCTAssertEqual(again?.kind, .added)
        pad.disconnect()
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

/// 拒绝每个连接的监听器：App 那头的连接失效、等不到回话（像核不过签名的旧远控进程）。
private final class RejectingListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    var count: Int { lock.withLock { total } }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.withLock { total += 1 }
        return false
    }
}

/// 接下连接、收下握手却永远不回（launchd 一直排着拉不起进程时 App 看到的样子）。
private final class HangingAgentListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let agent = HangingAgent()
    var hellos: Int { agent.hellos }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RemoteHostAgentXPC.self)
        connection.exportedObject = agent
        connection.resume()
        return true
    }
}

private final class HangingAgent: NSObject, RemoteHostAgentXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [@Sendable (Data) -> Void] = []
    var hellos: Int { lock.withLock { held.count } }

    func hello(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) { lock.withLock { held.append(reply) } }
    func configure(_ payload: Data) {}
    func updateSessions(_ payload: Data) {}
    func terminalAttached(_ attachment: String, error: String?) {}
    func terminalChunk(_ attachment: String, kind: Int, data: Data) {}
    func terminalEnded(_ attachment: String, reason: String) {}
    func command(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {}
    func depart(_ reason: String, reply: @escaping @Sendable () -> Void) { reply() }
}

@MainActor
private final class AgentPermissionBox {
    var current = RemoteHostAgentPermissions(screenCapture: true, postEvents: false)
    var requests = 0
}
