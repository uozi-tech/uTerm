import SwiftData
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 设备「经 Mac 打开主机」：设备发 `openHost` → Mac 的 `hostOpener` 开出会话 → 设备拿到会话 id 照常接入。
/// SSH 连接在 Mac 上，设备只是看着它。
///
/// 真实的开启器要开窗口、连真主机，这里换成假的：登记一个假后端驱动的会话（和终端窗口登记到注册表的形状一样）。
/// `RemoteHostOpener.live` 里不依赖窗口的那几步（开关、主机在不在、仅 SFTP、窗口没准备好、等不到会话）单独测。
@MainActor
final class RemoteOpenHostTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// 起服务端 + 配对好的设备客户端。`features` 传 nil 用默认能力（含 open-host）。
    private func pairedClient(registry: TerminalSessionRegistry, features: [String]? = nil,
                              opener: RemoteHostOpener) async throws -> (RemoteHostServer, RemoteMacClient) {
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      localFeatures: features ?? RemoteConstants.localFeatures)
        server.hostOpener = opener
        server.start()
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        _ = await waitUntil { !server.pairingRequests.isEmpty }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        return (server, client)
    }

    // MARK: - 协议

    func test_device_opens_a_host_on_the_mac_then_attaches_and_types() async throws {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let sshBackend = MockBackend()
        let serverID = UUID()
        var requested: [UUID] = []
        let opener = RemoteHostOpener { id in
            requested.append(id)
            await session.connect(using: sshBackend)
            let sessionID = UUID()
            registry.register(TerminalSessionEntry(id: sessionID, serverID: id, serverName: "prod-web",
                                                   windowKind: TerminalWindowKind.terminal, title: "prod-web",
                                                   connectedAt: Date()), session: session)
            return .success(sessionID)
        }
        let (server, client) = try await pairedClient(registry: registry, opener: opener)
        defer { server.stop(); session.dispose() }
        XCTAssertTrue(client.supportsOpenHost)

        let sessionID = try await client.openHost(serverID: serverID)
        XCTAssertEqual(requested, [serverID])
        // 会话列表里能看到它，挂在那台主机名下。
        let listed = await waitUntil { client.sessions.contains { $0.id == sessionID } }
        XCTAssertTrue(listed)
        XCTAssertEqual(client.sessions.first { $0.id == sessionID }?.serverID, serverID)

        // 之后就是普通的接入：输入经 Mac 到主机，输出回到设备。
        let backend = RemoteTerminalBackend(client: client, sessionID: sessionID)
        await backend.resize(cols: 60, rows: 20)
        try await backend.connect()
        let phone = MirrorPhone(cols: 60, rows: 20)
        phone.start(backend.outputItems)
        defer { phone.stop() }
        await backend.write(Data("uptime\r".utf8))
        let wrote = await waitUntil { await sshBackend.writtenData.contains(Data("uptime\r".utf8)) }
        XCTAssertTrue(wrote)
        await sshBackend.emitOutput(Data("hello-from-host\r\n".utf8))
        let echoed = await waitUntil { phone.shadow.recentLines(5).lines.contains("hello-from-host") }
        XCTAssertTrue(echoed, "设备上的画面：\(phone.shadow.recentLines(5).lines)")
    }

    func test_opener_failure_reaches_the_device_without_dropping_the_connection() async throws {
        let registry = TerminalSessionRegistry()
        let opener = RemoteHostOpener { _ in .failure(.init(message: "这台 Mac 上没有这台主机")) }
        let (server, client) = try await pairedClient(registry: registry, opener: opener)
        defer { server.stop() }

        do {
            _ = try await client.openHost(serverID: UUID())
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, "这台 Mac 上没有这台主机")
        }
        XCTAssertEqual(client.state, .connected, "被拒不断开连接")
    }

    func test_old_mac_without_the_feature_is_refused_on_the_device() async throws {
        let registry = TerminalSessionRegistry()
        var opened = false
        let opener = RemoteHostOpener { _ in
            opened = true
            return .failure(.init(message: "不该走到这里"))
        }
        // 老版本 Mac：握手不带 open-host。它收到 `openHost` 会当未知消息断开，所以设备端必须先挡住。
        let (server, client) = try await pairedClient(registry: registry, features: [RemoteFeature.localShell], opener: opener)
        defer { server.stop() }

        XCTAssertFalse(client.supportsOpenHost)
        do {
            _ = try await client.openHost(serverID: UUID())
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("版本太旧"), error.localizedDescription)
        }
        XCTAssertFalse(opened)
        XCTAssertEqual(client.state, .connected)
    }

    func test_messages_round_trip() throws {
        let request = RemoteOpenHostRequest(requestID: UUID(), serverID: UUID())
        let message = try RemoteMessage(decoding: RemoteMessage(.openHost, payload: RemoteJSON.encode(request)).encoded())
        XCTAssertEqual(message.kind, .openHost)
        XCTAssertEqual(try RemoteJSON.decode(RemoteOpenHostRequest.self, from: message.payload), request)
        // 编号写进了协议，不能动。
        XCTAssertEqual(RemoteMessage.Kind.openHost.rawValue, 48)
        XCTAssertEqual(RemoteMessage.Kind.hostOpened.rawValue, 49)
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.openHost))
    }

    // MARK: - Mac 上的开启器

    private func makeSettings(openHost: Bool) throws -> RemoteControlSettings {
        let suite = "uTerm.tests.remote-open-host.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = RemoteControlSettings(defaults: defaults)
        settings.isOpenHostEnabled = openHost
        return settings
    }

    private func makeContainer(_ profiles: ServerProfile...) throws -> ModelContainer {
        let container = try ModelContainer(
            for: ServerProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        profiles.forEach { container.mainContext.insert($0) }
        try container.mainContext.save()
        return container
    }

    private func profile(name: String, sftpOnly: Bool = false) -> ServerProfile {
        let profile = ServerProfile()
        profile.name = name
        profile.host = "\(name).example.test"
        profile.sftpOnly = sftpOnly
        return profile
    }

    private func message(_ result: Result<UUID, RemoteHostOpener.Failure>) -> String? {
        if case .failure(let failure) = result { return failure.message }
        return nil
    }

    /// 默认关：没在 Mac 上打开开关，设备开不了，窗口也不会开。
    func test_live_opener_refuses_while_the_setting_is_off() async throws {
        let host = profile(name: "web")
        let registry = TerminalSessionRegistry()
        var windows = 0
        registry.openTerminalWindow = { _ in
            windows += 1
            return UUID()
        }
        let settings = try makeSettings(openHost: false)
        XCTAssertFalse(try makeSettings(openHost: false).isOpenHostEnabled)
        let opener = RemoteHostOpener.live(settings: settings, registry: registry, container: try makeContainer(host))
        let result = await opener.open(host.id)
        XCTAssertTrue(message(result)?.contains("允许打开已保存的主机") == true, "\(result)")
        XCTAssertEqual(windows, 0)
    }

    func test_live_opener_refuses_unknown_and_sftp_only_hosts() async throws {
        let files = profile(name: "files", sftpOnly: true)
        let registry = TerminalSessionRegistry()
        var windows = 0
        registry.openTerminalWindow = { _ in
            windows += 1
            return UUID()
        }
        let settings = try makeSettings(openHost: true)
        let opener = RemoteHostOpener.live(settings: settings, registry: registry, container: try makeContainer(files))
        let unknown = await opener.open(UUID())
        XCTAssertTrue(message(unknown)?.contains("没有这台主机") == true, "\(unknown)")
        let sftpOnly = await opener.open(files.id)
        XCTAssertTrue(message(sftpOnly)?.contains("仅 SFTP") == true, "\(sftpOnly)")
        XCTAssertEqual(windows, 0)
    }

    /// 开窗口，等那个窗口里的会话登记上来，回它的 id。
    func test_live_opener_opens_a_window_and_returns_its_session() async throws {
        let host = profile(name: "web")
        let registry = TerminalSessionRegistry()
        let windowID = UUID(), sessionID = UUID()
        var requested: [UUID] = []
        registry.openTerminalWindow = { serverID in
            requested.append(serverID)
            // 窗口建好、SSH 连上之后会话才登记。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                registry.register(TerminalSessionEntry(id: sessionID, serverID: serverID, serverName: "web",
                                                       windowID: windowID, windowKind: TerminalWindowKind.terminal,
                                                       title: "web", connectedAt: Date()))
            }
            return windowID
        }
        let settings = try makeSettings(openHost: true)
        let opener = RemoteHostOpener.live(settings: settings, registry: registry, container: try makeContainer(host))
        let result = await opener.open(host.id)
        XCTAssertEqual(try result.get(), sessionID)
        XCTAssertEqual(requested, [host.id])
    }

    func test_live_opener_reports_when_the_app_cannot_open_windows_yet() async throws {
        let host = profile(name: "web")
        let registry = TerminalSessionRegistry()
        let settings = try makeSettings(openHost: true)
        let opener = RemoteHostOpener.live(settings: settings, registry: registry, container: try makeContainer(host))
        let result = await opener.open(host.id)
        XCTAssertTrue(message(result)?.contains("还没准备好") == true, "\(result)")
    }
}
