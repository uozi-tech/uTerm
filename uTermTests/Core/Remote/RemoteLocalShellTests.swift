import XCTest
@preconcurrency import Network
@testable import uTerm

/// 手机「新建本机终端」：手机发 `openLocalShell` → Mac 的 `localShellOpener` 开出会话 → 手机拿到会话 id 照常接入。
///
/// 真实的开启器要辅助进程与窗口，这里换成假的：登记一个假后端驱动的会话（与本机终端窗口登记到注册表的形状
/// 一样，`serverID` 是本机哨兵值）。辅助进程本身（forkpty、XPC）要真机授权后验证，不在这里。
@MainActor
final class RemoteLocalShellTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// 起服务端 + 配对好的手机客户端。`features` 传 nil 用默认能力（含 local-shell）。
    private func pairedClient(registry: TerminalSessionRegistry, features: [String]? = nil,
                              opener: RemoteLocalShellOpener) async throws -> (RemoteHostServer, RemoteMacClient) {
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      localFeatures: features ?? RemoteConstants.localFeatures)
        server.localShellOpener = opener
        server.start()
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        _ = await waitUntil { !server.pairingRequests.isEmpty }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        return (server, client)
    }

    func test_phone_opens_local_shell_then_attaches_and_types() async throws {
        let registry = TerminalSessionRegistry()
        let shell = TerminalSession()
        let shellBackend = MockBackend()
        var opened = 0
        let opener = RemoteLocalShellOpener {
            opened += 1
            await shell.connect(using: shellBackend)
            let id = UUID()
            registry.register(TerminalSessionEntry(id: id, serverID: RemoteConstants.localShellServerID,
                                                   serverName: LocalShellIdentity.serverName,
                                                   windowKind: TerminalWindowKind.terminal, title: "zsh",
                                                   connectedAt: Date()), session: shell)
            return .success(id)
        }
        let (server, client) = try await pairedClient(registry: registry, opener: opener)
        defer { server.stop(); shell.dispose() }
        XCTAssertTrue(client.supportsLocalShell)

        let sessionID = try await client.openLocalShell()
        XCTAssertEqual(opened, 1)
        // 会话列表里能看到它，并且认得出是本机。
        let listed = await waitUntil { client.sessions.contains { $0.id == sessionID } }
        XCTAssertTrue(listed)
        XCTAssertEqual(client.sessions.first { $0.id == sessionID }?.serverID, RemoteConstants.localShellServerID)

        // 之后就是普通的接入：输入到达 shell，输出回到手机。
        let backend = RemoteTerminalBackend(client: client, sessionID: sessionID)
        await backend.resize(cols: 60, rows: 20)
        try await backend.connect()
        var output = Data()
        let pump = Task { @MainActor in
            for await chunk in backend.outputStream { output.append(chunk) }
        }
        defer { pump.cancel() }
        await backend.write(Data("ls\r".utf8))
        let wrote = await waitUntil { await shellBackend.writtenData.contains(Data("ls\r".utf8)) }
        XCTAssertTrue(wrote)
        await shellBackend.emitOutput(Data("hello-from-mac\r\n".utf8))
        let echoed = await waitUntil { String(decoding: output, as: UTF8.self).contains("hello-from-mac") }
        XCTAssertTrue(echoed)
        XCTAssertNotNil(shell.remoteController, "接入后 Mac 上的本机终端标出正在被接管")
    }

    func test_opener_failure_reaches_phone_without_dropping_the_connection() async throws {
        let registry = TerminalSessionRegistry()
        let opener = RemoteLocalShellOpener { .failure(.init(message: "Mac 上没有打开「允许打开本机终端」")) }
        let (server, client) = try await pairedClient(registry: registry, opener: opener)
        defer { server.stop() }

        do {
            _ = try await client.openLocalShell()
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Mac 上没有打开「允许打开本机终端」")
        }
        XCTAssertEqual(client.state, .connected, "被拒不断开连接")
    }

    func test_old_mac_without_local_shell_feature_is_refused_on_the_phone() async throws {
        let registry = TerminalSessionRegistry()
        var opened = false
        let opener = RemoteLocalShellOpener {
            opened = true
            return .failure(.init(message: "不该走到这里"))
        }
        // 老版本 Mac：握手不带 local-shell。它收到 `openLocalShell` 会当未知消息断开，所以手机端必须先挡住。
        let (server, client) = try await pairedClient(registry: registry, features: [RemoteFeature.desktop], opener: opener)
        defer { server.stop() }

        XCTAssertFalse(client.supportsLocalShell)
        do {
            _ = try await client.openLocalShell()
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("版本太旧"), error.localizedDescription)
        }
        XCTAssertFalse(opened)
        XCTAssertEqual(client.state, .connected)
    }

    func test_phone_closes_the_session_on_mac_through_the_window_closer() async throws {
        let registry = TerminalSessionRegistry()
        let windowID = UUID(), sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: RemoteConstants.localShellServerID,
                                               serverName: LocalShellIdentity.serverName, windowID: windowID,
                                               windowKind: TerminalWindowKind.terminal, title: "zsh", connectedAt: Date()))
        var closed: [UUID] = []
        registry.setCloser(forWindow: windowID) { id in
            closed.append(id)
            registry.unregister(id: id)
            return true
        }
        let (server, client) = try await pairedClient(registry: registry, opener: .unavailable)
        defer { server.stop() }
        XCTAssertTrue(client.supportsCloseSession)

        client.closeSessionOnMac(UUID())   // 没有这条会话：Mac 上什么也不关，连接照常。
        client.closeSessionOnMac(sessionID)
        let done = await waitUntil { closed == [sessionID] }
        XCTAssertTrue(done, "Mac 上的关闭入口没被调到：\(closed)")
        let gone = await waitUntil { !client.sessions.contains { $0.id == sessionID } }
        XCTAssertTrue(gone, "关闭后会话列表应推来新的一份")
        XCTAssertEqual(client.state, .connected)

        // 窗口没了（forgetWindow）就不再有入口。
        registry.forgetWindow(windowID)
        XCTAssertFalse(registry.requestClose(sessionID: sessionID))
    }

    func test_old_mac_without_close_session_feature_gets_nothing_sent() async throws {
        let registry = TerminalSessionRegistry()
        let (server, client) = try await pairedClient(registry: registry, features: [RemoteFeature.desktop],
                                                      opener: .unavailable)
        defer { server.stop() }
        XCTAssertFalse(client.supportsCloseSession)
        client.closeSessionOnMac(UUID())   // 老 Mac 收到未知消息会断开整条连接，所以手机端根本不发。
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(client.state, .connected)
    }

    func test_message_kinds_and_payloads_keep_their_wire_shape() throws {
        // 线上编号一旦发布就不能改：老版本按编号认消息。
        XCTAssertEqual(RemoteMessage.Kind.openLocalShell.rawValue, 7)
        XCTAssertEqual(RemoteMessage.Kind.localShellOpened.rawValue, 28)
        XCTAssertEqual(RemoteMessage.Kind.closeSession.rawValue, 8)
        XCTAssertEqual(RemoteFeature.closeSession, "close-session")
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.closeSession))
        let close = RemoteCloseSessionRequest(sessionID: UUID())
        XCTAssertEqual(try RemoteJSON.decode(RemoteCloseSessionRequest.self, from: RemoteJSON.encode(close)), close)
        XCTAssertEqual(RemoteFeature.localShell, "local-shell")
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.localShell))
        XCTAssertEqual(RemoteConstants.localShellServerID.uuidString, "00000000-0000-0000-0000-00000000C0DE")

        let request = RemoteOpenLocalShellRequest(requestID: UUID())
        XCTAssertEqual(try RemoteJSON.decode(RemoteOpenLocalShellRequest.self, from: RemoteJSON.encode(request)), request)
        let ok = RemoteOpenLocalShellResult(requestID: UUID(), sessionID: UUID(), error: nil)
        XCTAssertEqual(try RemoteJSON.decode(RemoteOpenLocalShellResult.self, from: RemoteJSON.encode(ok)), ok)
        let failed = RemoteOpenLocalShellResult(requestID: UUID(), sessionID: nil, error: "没开")
        XCTAssertEqual(try RemoteJSON.decode(RemoteOpenLocalShellResult.self, from: RemoteJSON.encode(failed)), failed)
    }
}
