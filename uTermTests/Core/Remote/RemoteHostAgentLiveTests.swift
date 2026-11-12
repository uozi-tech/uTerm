import XCTest
@preconcurrency import Network
@testable import uTerm

/// 真实的远控进程：launchd 里的 `uTermRemoteHost.app`（带沙盒）经 mach 服务 `com.uozi.uTerm.RemoteHost` 连过来，两头都核
/// 代码签名；文件请求走远控进程包内嵌的 `uTermShellAgent.xpc`。默认跳过，由 `scripts/remote-host-live-test.sh` 先把刚编好的
/// 远控进程登记成 launchd 任务（不经 SMAppService、不碰已装的 uTerm），再带 `TEST_RUNNER_UTERM_REMOTE_HOST_LIVE=1` 跑。
@MainActor
final class RemoteHostAgentLiveTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func test_real_agent_serves_phone_terminal_and_files_across_app_restart() async throws {
        guard ProcessInfo.processInfo.environment["UTERM_REMOTE_HOST_LIVE"] == "1" else {
            throw XCTSkip("要先由 scripts/remote-host-live-test.sh 登记远控进程")
        }
        let suite = "uterm.tests.agent-live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = RemoteControlSettings(defaults: defaults)
        settings.isEnabled = true
        settings.isLocalShellEnabled = true
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let macBackend = MockBackend()
        await session.connect(using: macBackend)
        defer { session.dispose() }
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh",
                                               connectedAt: Date()), session: session)
        let appServer = RemoteHostServer(registry: registry,
                                         identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                         localName: "uTerm 远控进程实测", localID: UUID(), advertises: false,
                                         relayRevocations: RemoteRelayRevocations(defaults: defaults),
                                         relayRegistrationBlock: .testHost)
        // 和正式版一样连 launchd 的 mach 服务、核远控进程的签名；不查 SMAppService（任务是脚本登记的）。
        var transport = RemoteHostAgentBridge.production
        transport.checksRegistration = false
        func makeBridge() -> RemoteHostAgentBridge {
            let bridge = RemoteHostAgentBridge(server: appServer, registry: registry, settings: settings, restoration: nil,
                                               transport: transport)
            bridge.start()
            return bridge
        }
        var bridge = makeBridge()
        defer { bridge.post(.shutdown) }

        let listening = await waitUntil(15) { appServer.status == .listening && appServer.port != nil }
        XCTAssertTrue(listening, "远控进程应被 launchd 拉起、按交来的设置开始监听：\(appServer.status)")
        let port = try XCTUnwrap(appServer.port)

        let client = RemoteMacClient(macName: "uTerm 远控进程实测",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        let asked = await waitUntil(10) { !appServer.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        appServer.approvePairing(try XCTUnwrap(appServer.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        defer { client.disconnect() }

        // 文件：远控进程自己带沙盒读不到主目录，靠它包内的无沙盒 XPC 服务列出来。
        let (listing, _) = try await client.performFile(RemoteFileRequest(op: .list, path: RemoteLocalShellOpener.realHome))
        XCTAssertFalse(listing.entries?.isEmpty ?? true, "应列出主目录（经远控进程内嵌的文件服务）")

        // 终端：字节经 XPC 从 App 到远控进程再上链路。
        let listed = await waitUntil { client.sessions.map(\.id) == [sessionID] }
        XCTAssertTrue(listed)
        let backend = RemoteTerminalBackend(client: client, sessionID: sessionID)
        let phone = MirrorPhone(cols: 64, rows: 20)
        await backend.resize(cols: 64, rows: 20)
        try await backend.connect()
        phone.start(backend.outputItems)
        defer { phone.stop() }
        let mac = session.shadow
        let mixed = try TerminalCorpus.bytes("mixed")
        await macBackend.emitOutput(mixed)
        let mirrored = await waitUntil(10) { mac.mirrorDifferences(from: phone.shadow).isEmpty && mac.totalFedBytes >= mixed.count }
        XCTAssertTrue(mirrored, "\(mac.mirrorDifferences(from: phone.shadow))")

        // App 走了又回来：手机的连接不断，画面续上。
        bridge.simulateAppTermination()
        let shell = try TerminalCorpus.bytes("shell")
        await macBackend.emitOutput(shell)
        let dropped = await waitUntil(2) { client.state != .connected }
        XCTAssertFalse(dropped, "App 不在时远控连接应保持")
        bridge = makeBridge()
        let resumed = await waitUntil(15) {
            mac.mirrorDifferences(from: phone.shadow).isEmpty && mac.totalFedBytes >= mixed.count + shell.count
        }
        XCTAssertTrue(resumed, "App 回来后画面应续上：\(mac.mirrorDifferences(from: phone.shadow))")
        XCTAssertEqual(client.state, .connected)
    }
}
