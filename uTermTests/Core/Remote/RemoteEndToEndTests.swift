import XCTest
@preconcurrency import Network
@testable import uTerm

/// 端到端：真实的手机侧客户端（`RemoteMacClient` + `RemoteTerminalBackend`，与 uTermMobile 用的
/// 同一份代码）经 127.0.0.1 连真实的 `RemoteHostServer`。手机端是一台影子终端 + 输出泵（`MirrorPhone`），
/// 只吃后端吐出来的 `outputItems`（整屏快照 + 之后的原样字节），和 `MobileTerminalController` 一样。
@MainActor
final class RemoteEndToEndTests: XCTestCase {

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

    /// Mac 已经吃完 `fedBytes` 字节，并且两边读到的画面一致。
    private func same(_ mac: ShadowTerminal, _ phone: MirrorPhone, fedBytes: Int = 0) -> Bool {
        mac.totalFedBytes >= fedBytes && mac.mirrorDifferences(from: phone.shadow).isEmpty
    }

    func test_phone_client_pairs_attaches_mirrors_resizes_reconnects_and_sees_session_end() async throws {
        // Mac 端：一条由假后端驱动的会话，登记在注册表里；服务端只在 127.0.0.1 监听。
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let macBackend = MockBackend()
        await session.connect(using: macBackend)
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh",
                                               connectedAt: Date()), session: session)
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.start()
        defer { server.stop(); session.dispose() }
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let mac = session.shadow

        // 手机端：首次连接要配对。
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        // Mac 先登记配对请求、再把「等待审批」发给手机，两件事之间隔着一次网络往返：两边都到了才往下。
        let asked = await waitUntil {
            guard !server.pairingRequests.isEmpty, case .awaitingApproval = client.state else { return false }
            return true
        }
        XCTAssertTrue(asked)
        guard case .awaitingApproval(let phoneCode) = client.state else {
            return XCTFail("手机端应在等待审批，实际 \(client.state)")
        }
        XCTAssertEqual(phoneCode, server.pairingRequests.first?.code, "两端核对码一致")
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        let listed = await waitUntil { client.sessions.map(\.id) == [sessionID] }
        XCTAssertTrue(listed)

        // 接入：手机 64×20，手机端终端只吃后端的输出流。
        let backend = RemoteTerminalBackend(client: client, sessionID: sessionID)
        let phone = MirrorPhone(cols: 64, rows: 20)
        await backend.resize(cols: 64, rows: 20)
        try await backend.connect()
        phone.start(backend.outputItems)
        defer { phone.stop() }
        XCTAssertEqual(mac.size.cols, 64)
        XCTAssertEqual(mac.size.rows, 20)
        let mixed = try TerminalCorpus.bytes("mixed")
        await emit(mixed, to: macBackend)
        var fedBytes = mixed.count
        let mirrored = await waitUntil { self.same(mac, phone, fedBytes: fedBytes) }
        XCTAssertTrue(mirrored, "接入后画面不一致：\(mac.mirrorDifferences(from: phone.shadow))")
        XCTAssertGreaterThanOrEqual(phone.snapshots, 1, "接入后先到一张整屏快照")
        XCTAssertGreaterThan(phone.outputBytes, 0, "之后是原样字节")
        XCTAssertEqual(phone.pump.currentStats.rejectedSnapshots, 0)

        // 输入。
        await backend.write(Data("pwd\r".utf8))
        let wrote = await waitUntil { await macBackend.writtenData.contains(Data("pwd\r".utf8)) }
        XCTAssertTrue(wrote)

        // 手机改尺寸（转屏 / 键盘）：手机端终端先按新尺寸重排，Mac 调整后重发快照对齐。
        let snapshotsBeforeResize = phone.snapshots
        phone.resize(cols: 50, rows: 18)
        await backend.resize(cols: 50, rows: 18)
        let resized = await waitUntil {
            mac.size.cols == 50 && mac.size.rows == 18 && phone.snapshots > snapshotsBeforeResize && self.same(mac, phone)
        }
        XCTAssertTrue(resized, "改尺寸后不一致：\(mac.mirrorDifferences(from: phone.shadow))")

        // 断线：后端自己重连、重新接入，快照到了画面重新对齐；之后的输出照常同步。
        client.disconnect()
        let dropped = await waitUntil { session.remoteController == nil }
        XCTAssertTrue(dropped, "断线后 Mac 应交还尺寸")
        let reattached = await waitUntil(10) { session.remoteController != nil }
        XCTAssertTrue(reattached, "后端应自动重连并重新接入")
        XCTAssertEqual(mac.size.cols, 50, "重新接入后还是手机的尺寸")
        let shell = try TerminalCorpus.bytes("shell")
        await emit(shell, to: macBackend)
        fedBytes += shell.count
        let resynced = await waitUntil { self.same(mac, phone, fedBytes: fedBytes) }
        XCTAssertTrue(resynced, "重连后不一致：\(mac.mirrorDifferences(from: phone.shadow))")
        XCTAssertEqual(phone.pump.currentStats.rejectedSnapshots, 0)

        // Mac 上的会话结束：手机端收到退出，而不是无限重连。
        var exitIterator = backend.exitStream.makeAsyncIterator()
        registry.unregister(id: sessionID)
        let exited: Void? = await exitIterator.next()
        XCTAssertNotNil(exited, "会话结束应让后端退出")
    }

    /// 接管整台 Mac：同一条连接上同时接入全部终端，每个都钉成手机的尺寸，画面互不串台。
    func test_phone_attaches_every_terminal_at_once_over_one_connection() async throws {
        let registry = TerminalSessionRegistry()
        var sessions: [(id: UUID, session: TerminalSession, backend: MockBackend)] = []
        for index in 0..<4 {
            let session = TerminalSession()
            let backend = MockBackend()
            await session.connect(using: backend)
            let id = UUID()
            registry.register(TerminalSessionEntry(id: id, serverID: UUID(), serverName: "主机\(index)",
                                                   windowKind: TerminalWindowKind.workspace, title: "zsh\(index)",
                                                   connectedAt: Date()), session: session)
            sessions.append((id, session, backend))
        }
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.start()
        defer {
            server.stop()
            for entry in sessions { entry.session.dispose() }
        }
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { !server.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        let listed = await waitUntil { client.sessions.count == sessions.count }
        XCTAssertTrue(listed)
        XCTAssertEqual(client.listedSessionIDs?.count, sessions.count)

        // 同时发起接入，和工作区一次开出全部标签一样。
        let backends = sessions.map { RemoteTerminalBackend(client: client, sessionID: $0.id) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for backend in backends {
                group.addTask {
                    await backend.resize(cols: 64, rows: 20)
                    try await backend.connect()
                }
            }
            try await group.waitForAll()
        }
        var phones: [MirrorPhone] = []
        for backend in backends {
            let phone = MirrorPhone(cols: 64, rows: 20)
            phone.start(backend.outputItems)
            phones.append(phone)
        }
        defer { phones.forEach { $0.stop() } }

        for entry in sessions {
            let mac = entry.session.shadow
            XCTAssertEqual(mac.size.cols, 64)
            XCTAssertEqual(mac.size.rows, 20)
            XCTAssertNotNil(entry.session.remoteController, "每个终端都被接管")
        }
        var texts: [Data] = []
        for (index, entry) in sessions.enumerated() {
            let text = Data("这是第 \(index) 个终端\r\n".utf8)
            texts.append(text)
            await entry.backend.emitOutput(text)
        }
        for (index, entry) in sessions.enumerated() {
            let mac = entry.session.shadow
            let mirrored = await waitUntil { self.same(mac, phones[index], fedBytes: texts[index].count) }
            XCTAssertTrue(mirrored, "第 \(index) 个终端画面不一致：\(mac.mirrorDifferences(from: phones[index].shadow))")
            XCTAssertEqual(phones[index].shadow.recentLines(1).lines, ["这是第 \(index) 个终端"], "画面不串台")
        }
        for backend in backends { await backend.close() }
        let released = await waitUntil { sessions.allSatisfy { $0.session.remoteController == nil } }
        XCTAssertTrue(released, "全部断开后 Mac 上的终端都恢复")

        // 断开后列表是「不知道」，不是「Mac 上没有终端」：手机据此判断终端有没有被关。
        client.disconnect()
        let forgotten = await waitUntil { client.listedSessionIDs == nil }
        XCTAssertTrue(forgotten)
        XCTAssertTrue(client.canAutoReconnect, "只是断线，可以自动连回去")
    }

    func test_refused_pairing_is_not_retried_automatically() async throws {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.start()
        defer { server.stop() }
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { !server.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        XCTAssertFalse(client.canAutoReconnect, "等审批时不重连")

        server.rejectPairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value

        XCTAssertTrue(client.pairingRefused)
        XCTAssertFalse(client.canAutoReconnect, "被拒之后再连只会再弹一次审批")
    }
}
