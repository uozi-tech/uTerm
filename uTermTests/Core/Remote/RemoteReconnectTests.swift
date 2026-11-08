import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 手机端与 Mac 之间的链路故障。`RemoteEndToEndTests` 只覆盖「主动断开后立刻能连回」，
/// 这里覆盖现实里更常见的情况：Mac 睡着、Wi-Fi 断了，要过一阵才连得上。
@MainActor
final class RemoteReconnectTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Mac 端一条会话 + 服务端 + 故障代理 + 已配对的手机客户端。
    private struct Fixture {
        let registry: TerminalSessionRegistry
        let session: TerminalSession
        let server: RemoteHostServer
        let proxy: RemoteFaultProxy
        let client: RemoteMacClient
        let sessionID: UUID
    }

    /// 测试用的短时限：判死要在几秒内发生。
    private let fastHeartbeat = RemoteHeartbeat(pingInterval: 0.15, replyLimit: 0.6, probeReplyLimit: 0.3,
                                                peerSilenceLimit: 0.6)

    private func makeFixture(heartbeat: RemoteHeartbeat = .standard) async throws -> Fixture {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        await session.connect(using: MockBackend())
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh",
                                               connectedAt: Date()), session: session)
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      peerSilenceLimit: heartbeat.peerSilenceLimit)
        server.start()
        _ = await waitUntil { server.port != nil }
        let proxy = try RemoteFaultProxy(targetPort: try XCTUnwrap(server.port))
        _ = await waitUntil { proxy.port != nil }
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1",
                                                         port: NWEndpoint.Port(rawValue: try XCTUnwrap(proxy.port))!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                     heartbeat: heartbeat)
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { !server.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        return Fixture(registry: registry, session: session, server: server, proxy: proxy, client: client,
                       sessionID: sessionID)
    }

    /// Mac 暂时连不上时，已经打开的远控标签要一直重试，连得上之后自动接回；不能重连失败一次就结束。
    func test_terminal_keeps_retrying_while_mac_is_unreachable_then_reattaches() async throws {
        let fixture = try await makeFixture()
        defer {
            fixture.server.stop()
            fixture.proxy.stop()
            fixture.session.dispose()
        }
        let backend = RemoteTerminalBackend(client: fixture.client, sessionID: fixture.sessionID)
        await backend.resize(cols: 64, rows: 20)
        try await backend.connect()
        let drain = Task { for await _ in backend.outputStream {} }
        defer { drain.cancel() }

        var ended = false
        let exitWatch = Task { @MainActor in
            for await _ in backend.exitStream { ended = true }
        }
        defer { exitWatch.cancel() }

        // Mac 不可达：至少让手机端失败重试两次（退避 0.5 s、1 s）。
        fixture.proxy.setMode(.refusing)
        let before = fixture.proxy.accepted
        let retried = await waitUntil(8) { fixture.proxy.accepted >= before + 2 }
        XCTAssertTrue(retried, "Mac 不可达时手机端应持续重试")
        XCTAssertFalse(ended, "连不上不等于会话结束，标签不能被关掉")

        // Mac 回来：自动接回。
        fixture.proxy.setMode(.forwarding)
        let reattached = await waitUntil(10) { fixture.session.remoteController != nil }
        XCTAssertTrue(reattached, "Mac 恢复后应自动重新接入")
        XCTAssertFalse(ended)
    }

    /// 真正的拒绝（配对被撤销等）不重试，也不被当成网络问题吞掉。
    func test_permanent_protocol_errors_are_not_treated_as_unreachable() {
        XCTAssertTrue(RemoteProtocolError.pairingRejected.isPermanent)
        XCTAssertTrue(RemoteProtocolError.peerIdentityChanged.isPermanent)
        XCTAssertTrue(RemoteProtocolError.versionMismatch(9).isPermanent)
        XCTAssertFalse(RemoteProtocolError.closed.isPermanent)
        XCTAssertFalse(RemoteProtocolError.timeout.isPermanent)
    }

    /// 链路假死（TCP 还连着、字节过不去）：两端都要自己发现。手机重连，Mac 交还终端尺寸。
    func test_stalled_link_is_detected_by_both_ends_and_recovers() async throws {
        let fixture = try await makeFixture(heartbeat: fastHeartbeat)
        defer {
            fixture.server.stop()
            fixture.proxy.stop()
            fixture.session.dispose()
        }
        let backend = RemoteTerminalBackend(client: fixture.client, sessionID: fixture.sessionID)
        await backend.resize(cols: 64, rows: 20)
        try await backend.connect()
        let drain = Task { for await _ in backend.outputStream {} }
        defer { drain.cancel() }
        XCTAssertNotNil(fixture.session.remoteController)

        // 空闲但健康的链路不能被误判：超过判死时限后仍然连着。
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(fixture.client.state, .connected, "心跳应让空闲链路保持存活")
        XCTAssertNotNil(fixture.session.remoteController)

        let before = fixture.proxy.accepted
        fixture.proxy.setMode(.stalled)
        let macNoticed = await waitUntil(5) { fixture.session.remoteController == nil }
        XCTAssertTrue(macNoticed, "Mac 应断开无声的手机并交还尺寸")
        let phoneNoticed = await waitUntil(5) { fixture.proxy.accepted > before }
        XCTAssertTrue(phoneNoticed, "手机应判定链路已死并发起重连")

        fixture.proxy.setMode(.forwarding)
        let back = await waitUntil(15) { fixture.session.remoteController != nil }
        XCTAssertTrue(back, "链路恢复后应自动接回")
    }

    /// 连上就有往返读数：心跳第一拍就 ping，不等链路安静满 `pingInterval`。
    /// 「我的 Mac」详情在已连接时显示往返；以前只在安静时 ping，开着屏幕、终端在刷就一直是「—」。
    func test_round_trip_is_measured_right_after_connecting() async throws {
        // 安静 6 秒才 ping：修之前最早第 6 秒才有读数；心跳一拍 2 秒，修之后第一拍就有。
        let heartbeat = RemoteHeartbeat(pingInterval: 6, replyLimit: 600, probeReplyLimit: 5, peerSilenceLimit: 600)
        let fixture = try await makeFixture(heartbeat: heartbeat)
        defer {
            fixture.server.stop()
            fixture.proxy.stop()
            fixture.session.dispose()
        }
        XCTAssertNil(fixture.client.roundTripMillis)
        let measured = await waitUntil(4.5) { fixture.client.roundTripMillis != nil }
        XCTAssertTrue(measured, "连上后第一拍心跳就应 ping 一次、拿到往返")
    }

    /// 网络一变就问一声：链路已经走不通时不用等完整的判死时限。
    func test_network_change_probe_detects_dead_link_quickly_and_wakes_backoff() async throws {
        let slowPing = RemoteHeartbeat(pingInterval: 60, replyLimit: 600, probeReplyLimit: 0.3, peerSilenceLimit: 600)
        let fixture = try await makeFixture(heartbeat: slowPing)
        defer {
            fixture.server.stop()
            fixture.proxy.stop()
            fixture.session.dispose()
        }
        let before = fixture.proxy.accepted
        fixture.proxy.setMode(.stalled)
        fixture.client.networkChanged(isSatisfied: true)
        let dead = await waitUntil(3) { fixture.client.state != .connected }
        XCTAssertTrue(dead, "探测没回音应判定链路已死")
        XCTAssertEqual(fixture.proxy.accepted, before)

        // 没网：立刻断开。
        fixture.proxy.setMode(.forwarding)
        await fixture.client.connect()
        XCTAssertEqual(fixture.client.state, .connected)
        fixture.client.networkChanged(isSatisfied: false)
        let closed = await waitUntil(2) { fixture.client.state != .connected }
        XCTAssertTrue(closed, "没网时应立刻断开")
    }

    /// 老手机不发心跳，空闲时一个字节都没有：Mac 不能把它当成死链路断开。
    func test_mac_does_not_cut_old_phone_without_heartbeat() async throws {
        let registry = TerminalSessionRegistry()
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false, peerSilenceLimit: 0.3)
        server.start()
        defer { server.stop() }
        _ = await waitUntil { server.port != nil }
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let staticKey = try identity.localIdentity()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let port = try XCTUnwrap(server.port)
        let link = RemoteLink(connection: NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                                       using: RemoteLink.parameters()))
        link.setHandlers(onMessage: { _ in }, onClose: { _ in })
        defer { link.close() }
        let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: UUID(), deviceName: "老手机",
                                ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                staticKey: staticKey.publicKey.rawRepresentation,
                                features: [RemoteFeature.keyConfirmation])
        _ = try await link.establish(role: .initiator, hello: hello, staticKey: staticKey, ephemeralKey: ephemeral)
        // 不报心跳，但密钥确认是 Mac 的硬要求（不能由对方的声明跳过）。
        link.send(RemoteMessage(.keyConfirm))
        let asked = await waitUntil { !server.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        let connected = await waitUntil { server.connectedDevices.contains("老手机") }
        XCTAssertTrue(connected)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(server.connectedDevices.contains("老手机"), "老手机空闲时不该被断开")
    }

    func test_retry_gate_wakes_early_and_reports_it() async {
        let gate = RemoteRetryGate()
        let waiting = Task { await gate.wait(.seconds(30)) }
        try? await Task.sleep(for: .milliseconds(150))
        gate.kick()
        let woke = await waiting.value
        XCTAssertTrue(woke)
        let timedOut = await gate.wait(.milliseconds(50))
        XCTAssertFalse(timedOut)
    }

    func test_sleep_policy_counts_use_not_connection() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let minute: TimeInterval = 60
        XCTAssertFalse(RemoteSleepPolicy.holdsAwake(now: start, lastInput: nil, lastOutput: start), "没输入过，只有输出不算")
        XCTAssertTrue(RemoteSleepPolicy.holdsAwake(now: start + 4 * minute, lastInput: start, lastOutput: nil))
        XCTAssertFalse(RemoteSleepPolicy.holdsAwake(now: start + 6 * minute, lastInput: start, lastOutput: nil))
        // 敲下去的构建还在输出：一直保持到输出停后 5 分钟。
        XCTAssertTrue(RemoteSleepPolicy.holdsAwake(now: start + 22 * minute, lastInput: start, lastOutput: start + 20 * minute))
        XCTAssertFalse(RemoteSleepPolicy.holdsAwake(now: start + 26 * minute, lastInput: start, lastOutput: start + 20 * minute))
        // 输入后超过 30 分钟的输出（无人理会的 htop）不再算。
        XCTAssertFalse(RemoteSleepPolicy.holdsAwake(now: start + 41 * minute, lastInput: start, lastOutput: start + 40 * minute))
    }

    /// 开着屏幕时（`expectSteadyTraffic`）链路静默断开：用正式的心跳参数，5 秒内发现（之后由桌面会话 / 标签重连），
    /// 不等平时的 20 秒判死。没有网络变化通知（NAT 映射过期、中间设备掐流）。
    func test_silent_break_is_detected_within_five_seconds_while_the_screen_is_open() async throws {
        let fixture = try await makeFixture()
        defer {
            fixture.server.stop()
            fixture.proxy.stop()
            fixture.session.dispose()
        }
        let sink = RemoteChannelSink(onOutput: { _ in }, onClosed: { _, _ in })
        let attachment = try await fixture.client.attach(sessionID: fixture.sessionID,
                                                         size: RemoteGridSize(cols: 80, rows: 24), sink: sink)
        attachment.link.expectSteadyTraffic(true)
        try await Task.sleep(for: .seconds(1))

        let before = fixture.proxy.accepted
        fixture.proxy.setMode(.stalled)
        let start = Date()
        let noticed = await waitUntil(8) { fixture.client.state != .connected }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(noticed)
        XCTAssertLessThan(elapsed, 5, "开着屏幕时静默断开应在 5 秒内发现（用了 \(elapsed) 秒）")
        XCTAssertEqual(fixture.proxy.accepted, before, "判死靠自己的探测，不是重连撞出来的")
    }

    /// 同样开着屏幕，但链路健康、只是没有画面在变：靠 ping 的回音保持，不能误判。
    func test_quiet_but_healthy_link_is_kept_while_the_screen_is_open() async throws {
        let fixture = try await makeFixture()
        defer {
            fixture.server.stop()
            fixture.proxy.stop()
            fixture.session.dispose()
        }
        let sink = RemoteChannelSink(onOutput: { _ in }, onClosed: { _, _ in })
        let attachment = try await fixture.client.attach(sessionID: fixture.sessionID,
                                                         size: RemoteGridSize(cols: 80, rows: 24), sink: sink)
        attachment.link.expectSteadyTraffic(true)
        try await Task.sleep(for: .seconds(6))
        XCTAssertEqual(fixture.client.state, .connected)
    }

}
