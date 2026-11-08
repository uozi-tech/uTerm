import CryptoKit
import XCTest
@testable import uTerm

/// 开着远程桌面时直连的存活判定：「对端发的任何验过的东西到了」算活着，控制通道另有一只兜底的钟。
///
/// 回归 2026-11-08 弱网矩阵「带宽骤降」：KCP 有一段要重传，按序交付把后面的控制消息全堵住，视频数据报一直在到，
/// 手机 3.6 s 没收到控制字节就把一条慢但活着的路判死，重连又卡 2–6 s。
@MainActor
final class RemoteDirectLivenessTests: XCTestCase {

    /// 包一层数据报路径：按明文的第一个字节（数据报种类）选择性地丢。
    private final class FilteredPath: RemoteDatagramPath, @unchecked Sendable {
        private let inner: RemoteMemoryDatagramPath
        private let lock = NSLock()
        private var dropsControl = false
        private var dropsAll = false
        init(_ inner: RemoteMemoryDatagramPath) { self.inner = inner }

        func set(dropsControl: Bool = false, dropsAll: Bool = false) {
            lock.lock(); self.dropsControl = dropsControl; self.dropsAll = dropsAll; lock.unlock()
        }

        func start(onDatagram: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (Error?) -> Void) {
            inner.start(onDatagram: onDatagram, onFailure: onFailure)
        }

        func send(_ datagram: Data) {
            lock.lock(); let control = dropsControl, all = dropsAll; lock.unlock()
            if all { return }
            if control, datagram.first == RemoteDatagramKind.reliable.rawValue { return }
            inner.send(datagram)
        }

        func close() { inner.close() }
    }

    private struct Rig {
        let server: RemoteHostServer
        let client: RemoteMacClient
        let mac: FakeDesktopMac
        /// Mac 发往手机的方向。
        let toPhone: FilteredPath
        /// 手机发往 Mac 的方向。
        let toMac: FilteredPath
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func makeRig(heartbeat: RemoteHeartbeat = .standard) throws -> Rig {
        let mac = FakeDesktopMac()
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let phoneID = RemoteLocalDevice.id()
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      desktopEnvironment: mac.environment())
        server.internetAccessPolicy = { $0 == phoneID }
        try server.trust(RemotePeer(id: phoneID, name: "测试 iPhone",
                                    publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        let (macMemory, phoneMemory) = RemoteMemoryDatagramPath.pair(impairment: RemoteLinkImpairment(delay: 0.02))
        let toPhone = FilteredPath(macMemory), toMac = FilteredPath(phoneMemory)
        let keys = makeDatagramKeys()
        server.accept(transport: RemoteP2PTransport(path: toPhone, keys: keys.first),
                      origin: .internet(peerID: phoneID, keys: RemoteHandshakeKeys(send: b, receive: a), path: .direct))
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: phoneIdentity, heartbeat: heartbeat)
        let dials = Counter()
        client.updateRoutes(endpoint: nil, internetDialer: { _ in
            // 只给第一次：判死之后的重连不该成功，好让用例看清是不是判死了。
            guard dials.next() == 0 else { throw RemoteProtocolError.closed }
            return RemoteDialedPath(transport: RemoteP2PTransport(path: toMac, keys: keys.second),
                                    handshakeKeys: RemoteHandshakeKeys(send: a, receive: b), path: .direct)
        })
        return Rig(server: server, client: client, mac: mac, toPhone: toPhone, toMac: toMac)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { count += 1; lock.unlock() }; return count }
    }

    /// 连上、开桌面（开着屏幕才用快判据）、让画面一直在变；`audio` 时再开声音（不等确认、一直在到的数据报）。
    private func startStreaming(_ rig: Rig, audio: Bool = false) async throws -> RemoteDesktopSession {
        await rig.client.connect()
        XCTAssertEqual(rig.client.state, .connected)
        XCTAssertEqual(rig.client.path, .direct)
        let output = SilentAudioOutput()
        let session = RemoteDesktopSession(client: rig.client, maxWidth: 640, maxHeight: 400, audioOutput: output)
        session.receiver.setHandlers(onImage: { _, _ in }, onCursor: { _ in })
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let source = try XCTUnwrap(rig.mac.latestSource)
        source.prepareCycle(count: 4)
        source.run(fps: 30)
        if audio {
            session.setAudio(true)
            let playing = await waitUntil(5) { session.audioState == .playing }
            XCTAssertTrue(playing)
        }
        try await Task.sleep(for: .seconds(1.5))
        return session
    }

    /// 控制通道被堵、视频数据报一直在到：不判死。
    func test_blocked_control_channel_with_datagrams_arriving_is_kept() async throws {
        let rig = try makeRig()
        defer { rig.client.disconnect(); rig.server.stop() }
        let session = try await startStreaming(rig)
        defer { session.stop(); rig.mac.latestSource?.pause() }
        rig.toPhone.set(dropsControl: true)
        try await Task.sleep(for: .seconds(8))
        XCTAssertEqual(rig.client.state, .connected, "数据报一直在到：路是活的")
        rig.toPhone.set()
    }

    /// 数据报和控制都停了：仍然几秒内判死（160a7163 的快判据不退化）。
    func test_everything_stopping_is_still_detected_quickly() async throws {
        let rig = try makeRig()
        defer { rig.client.disconnect(); rig.server.stop() }
        let session = try await startStreaming(rig)
        defer { session.stop(); rig.mac.latestSource?.pause() }
        rig.toPhone.set(dropsAll: true)
        let start = Date()
        let noticed = await waitUntil(8) { rig.client.state != .connected }
        XCTAssertTrue(noticed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.5, "真断了照样几秒内发现（拥塞时的 ping 往返不能把等待拉长）")
    }

    /// 单向断（Mac → 手机通、手机 → Mac 断）且开着声音：数据报一直在到，快判据看不出；控制通道的兜底钟
    /// 在 `replyLimit` 内判死。用例里把 `replyLimit` 缩到 4 s。
    func test_one_way_break_with_audio_is_detected_by_the_control_clock() async throws {
        var heartbeat = RemoteHeartbeat.standard
        heartbeat.replyLimit = 4
        let rig = try makeRig(heartbeat: heartbeat)
        defer { rig.client.disconnect(); rig.server.stop() }
        let session = try await startStreaming(rig, audio: true)
        defer { session.stop(); rig.mac.latestSource?.pause() }
        rig.toMac.set(dropsAll: true)
        let start = Date()
        let noticed = await waitUntil(10) { rig.client.state != .connected }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(noticed, "单向断要判死")
        XCTAssertGreaterThan(elapsed, 3, "靠的是控制通道的兜底钟，不是快判据")
        XCTAssertLessThan(elapsed, 6.5)
    }

    /// 单向断，而 Mac 那头一直有控制消息要发（光标在动、换声音档的格式通知……）：Mac 不知道手机听不见回音，
    /// KCP 窗口没满就照送，手机这边控制通道一直有字节到。兜底钟只认 Mac 对我们的回应（pong / linkAck），
    /// 照样在 `replyLimit` 内判死。回归 2026-11-09：断开 3.5 s 后到的一条换档通知把判死从 5.9 s 拖到 7.8 s；
    /// 光标一直在动时就永远判不死。
    func test_one_way_break_is_detected_while_the_mac_keeps_sending_control_messages() async throws {
        var heartbeat = RemoteHeartbeat.standard
        heartbeat.replyLimit = 4
        let rig = try makeRig(heartbeat: heartbeat)
        defer { rig.client.disconnect(); rig.server.stop() }
        let session = try await startStreaming(rig)
        defer { session.stop(); rig.mac.latestSource?.pause() }
        rig.toMac.set(dropsAll: true)
        let start = Date()
        var step = 0
        let noticed = await waitUntil(10) {
            // 每 200 ms 动一下光标：Mac 每次都发一条控制消息。
            if Date().timeIntervalSince(start) * 5 > Double(step) {
                step += 1
                rig.mac.moveCursor(to: CGPoint(x: 100 + step * 7, y: 200 + step * 3))
            }
            return rig.client.state != .connected
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(noticed, "单向断要判死")
        XCTAssertGreaterThan(elapsed, 3, "靠的是兜底钟，不是快判据")
        XCTAssertLessThan(elapsed, 6.5, "光标一直在动也不能把判死往后拖")
    }
}
