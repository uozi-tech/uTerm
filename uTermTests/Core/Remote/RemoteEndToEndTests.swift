import XCTest
import SwiftTerm
@preconcurrency import Network
@testable import uTerm

/// 端到端：真实的手机侧客户端（`RemoteMacClient` + `RemoteTerminalBackend`，与 uTermMobile 用的
/// 同一份代码）经 127.0.0.1 连真实的 `RemoteHostServer`。手机端终端只吃后端吐出来的字节，
/// 和 `MobileTerminalController` 一样。
@MainActor
final class RemoteEndToEndTests: XCTestCase {

    private final class SilentDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let phoneDelegate = SilentDelegate()

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func corpus(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "terminal-corpus-\(name)", withExtension: "bin"))
        return [UInt8](try Data(contentsOf: url))
    }

    private func emit(_ bytes: [UInt8], to backend: MockBackend) async {
        for start in stride(from: 0, to: bytes.count, by: 433) {
            await backend.emitOutput(Data(bytes[start..<min(bytes.count, start + 433)]))
        }
    }

    private func same(_ mac: Terminal, _ phone: Terminal) -> Bool {
        mac.snapshotFingerprint().differences(from: phone.snapshotFingerprint()).isEmpty
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
        let mac = session.terminalView.getTerminal()

        // 手机端：首次连接要配对。
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { !server.pairingRequests.isEmpty }
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
        let phone = Terminal(delegate: phoneDelegate, options: TerminalOptions(cols: 64, rows: 20, scrollback: 2000))
        await backend.resize(cols: 64, rows: 20)
        try await backend.connect()
        let pump = Task { @MainActor in
            for await chunk in backend.outputStream { phone.feed(byteArray: [UInt8](chunk)) }
        }
        defer { pump.cancel() }
        XCTAssertEqual(mac.cols, 64)
        XCTAssertEqual(mac.rows, 20)
        await emit(try corpus("mixed"), to: macBackend)
        let mirrored = await waitUntil { self.same(mac, phone) }
        XCTAssertTrue(mirrored, "接入后画面不一致：\(mac.snapshotFingerprint().differences(from: phone.snapshotFingerprint()))")

        // 输入。
        await backend.write(Data("pwd\r".utf8))
        let wrote = await waitUntil { await macBackend.writtenData.contains(Data("pwd\r".utf8)) }
        XCTAssertTrue(wrote)

        // 手机改尺寸（转屏 / 键盘）：手机端终端先按新尺寸重排，Mac 调整后重发快照对齐。
        phone.resize(cols: 50, rows: 18)
        await backend.resize(cols: 50, rows: 18)
        let resized = await waitUntil { mac.cols == 50 && mac.rows == 18 && self.same(mac, phone) }
        XCTAssertTrue(resized, "改尺寸后不一致：\(mac.snapshotFingerprint().differences(from: phone.snapshotFingerprint()))")

        // 断线：后端自己重连、重新接入，快照到了画面重新对齐；之后的输出照常同步。
        client.disconnect()
        let dropped = await waitUntil { session.remoteController == nil }
        XCTAssertTrue(dropped, "断线后 Mac 应交还尺寸")
        let reattached = await waitUntil(10) { session.remoteController != nil }
        XCTAssertTrue(reattached, "后端应自动重连并重新接入")
        await emit(try corpus("shell"), to: macBackend)
        let resynced = await waitUntil { self.same(mac, phone) }
        XCTAssertTrue(resynced, "重连后不一致：\(mac.snapshotFingerprint().differences(from: phone.snapshotFingerprint()))")

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
        var phones: [Terminal] = []
        var pumps: [Task<Void, Never>] = []
        for backend in backends {
            let phone = Terminal(delegate: phoneDelegate, options: TerminalOptions(cols: 64, rows: 20, scrollback: 200))
            phones.append(phone)
            pumps.append(Task { @MainActor in
                for await chunk in backend.outputStream { phone.feed(byteArray: [UInt8](chunk)) }
            })
        }
        defer { pumps.forEach { $0.cancel() } }

        for entry in sessions {
            let mac = entry.session.terminalView.getTerminal()
            XCTAssertEqual(mac.cols, 64)
            XCTAssertEqual(mac.rows, 20)
            XCTAssertNotNil(entry.session.remoteController, "每个终端都被接管")
        }
        for (index, entry) in sessions.enumerated() {
            await entry.backend.emitOutput(Data("这是第 \(index) 个终端\r\n".utf8))
        }
        for (index, entry) in sessions.enumerated() {
            let mac = entry.session.terminalView.getTerminal()
            let mirrored = await waitUntil { self.same(mac, phones[index]) }
            XCTAssertTrue(mirrored, "第 \(index) 个终端画面不一致")
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
