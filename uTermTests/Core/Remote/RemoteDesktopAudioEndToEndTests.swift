import CryptoKit
@preconcurrency import Network
import XCTest
@testable import uTerm

/// 远程桌面声音端到端（回环，调研 §16）：合成声源 → 真实的 `RemoteHostConnection` / `RemoteAudioStreamer` / Opus 编码 →
/// 127.0.0.1 上的加密链路（`link-flow`）→ 真实的手机侧 `RemoteDesktopSession` / `RemoteAudioReceiver` / 抖动缓冲。
/// 只有声源与扬声器换成了夹具（测试进程不能真采系统声音、也不该真出声）。
@MainActor
final class RemoteDesktopAudioEndToEndTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func makeRig(features: [String] = RemoteConstants.localFeatures)
        async throws -> (RemoteHostServer, FakeDesktopMac, RemoteMacClient) {
        let mac = FakeDesktopMac()
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      localFeatures: features, desktopEnvironment: mac.environment())
        server.start()
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready, "服务端没起来：\(server.status)")
        let phoneIdentity = RemoteIdentityStore(storage: RemoteMemoryStorage())
        try server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "测试 iPhone",
                                    publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!),
                                     identity: phoneIdentity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        return (server, mac, client)
    }

    private func makeSession(_ client: RemoteMacClient) -> (RemoteDesktopSession, SilentAudioOutput) {
        let output = SilentAudioOutput()
        let session = RemoteDesktopSession(client: client, maxWidth: 1206, maxHeight: 2622, audioOutput: output)
        return (session, output)
    }

    /// 声音的峰值。
    private func peak(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

    func test_audio_plays_goes_quiet_on_silence_and_stops_when_turned_off() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        XCTAssertTrue(client.supportsDesktopAudio, "新版 Mac 握手时报 desktop-audio 能力")
        let (session, output) = makeSession(client)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        XCTAssertTrue(mac.audioSources.isEmpty, "没开扬声器不采声音")

        // 1. 打开：Mac 开一条声音流，先发格式，声音包接着到；手机解出来的是有声的。
        session.setAudio(true)
        XCTAssertTrue(output.isPlaying)
        let playing = await waitUntil { session.audioState == .playing }
        XCTAssertTrue(playing, "应收到格式：\(session.audioState)")
        let arrived = await waitUntil { session.audioReceiver.snapshot().received >= 20 }
        XCTAssertTrue(arrived, "20 包声音没到：\(session.audioReceiver.snapshot())")
        XCTAssertEqual(session.audioReceiver.snapshot().codec, .opus)
        XCTAssertEqual(server.desktopViewer?.hasAudio, true, "Mac 的指示条要显示在传声音")
        let pull = try XCTUnwrap(output.pull)
        var heard: Float = 0
        for _ in 0..<60 {
            heard = max(heard, peak(pull(480)))
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(heard, 0.3, "放出来的应是 0.5 幅度的正弦")

        // 2. 静音：停发声音包，只每秒报一次静音。
        let source = try XCTUnwrap(mac.latestAudioSource)
        source.setSilent(true)
        try await Task.sleep(for: .milliseconds(400))
        let before = session.audioReceiver.snapshot().received
        try await Task.sleep(for: .milliseconds(1_200))
        let during = session.audioReceiver.snapshot().received - before
        XCTAssertLessThanOrEqual(during, 2, "静音期间几乎不发声音包，实际 \(during)")
        source.setSilent(false)
        let resumed = await waitUntil { session.audioReceiver.snapshot().received >= before + 10 }
        XCTAssertTrue(resumed, "有声了要立刻接着发")

        // 3. 关掉：Mac 停采集，指示条去掉扬声器，画面不受影响。
        session.setAudio(false)
        XCTAssertFalse(output.isPlaying)
        XCTAssertEqual(session.audioState, .off)
        let stopped = await waitUntil { source.stopped && server.desktopViewer?.hasAudio == false }
        XCTAssertTrue(stopped)
        XCTAssertEqual(session.state, .streaming)
    }

    func test_mac_side_switch_off_refuses_and_turning_it_off_midway_stops_audio() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, output) = makeSession(client)
        defer { session.stop() }
        await session.start()

        // Mac 上没开「允许传输声音」：手机按钮复位，提示原因，不开采集。
        mac.audioEnabled = false
        session.setAudio(true)
        let refused = await waitUntil { if case .unavailable = session.audioState { return true }; return false }
        XCTAssertTrue(refused)
        guard case .unavailable(let message) = session.audioState else { return XCTFail() }
        XCTAssertTrue(message.contains("允许传输声音"), message)
        XCTAssertFalse(output.isPlaying)
        XCTAssertTrue(mac.audioSources.isEmpty)

        // 打开后再在 Mac 上关：声音停，手机提示，桌面流照常。
        mac.audioEnabled = true
        session.setAudio(true)
        let playing = await waitUntil { session.audioState == .playing }
        XCTAssertTrue(playing)
        server.endDesktopAudio(reason: "Mac 上关闭了「允许传输声音」")
        let ended = await waitUntil { if case .unavailable = session.audioState { return true }; return false }
        XCTAssertTrue(ended, "\(session.audioState)")
        XCTAssertFalse(output.isPlaying)
        XCTAssertTrue(try XCTUnwrap(mac.latestAudioSource).stopped)
        XCTAssertEqual(session.state, .streaming)
    }

    /// 结束桌面流时声音一起停。
    func test_stopping_desktop_stops_audio_capture() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, _) = makeSession(client)
        await session.start()
        session.setAudio(true)
        let playing = await waitUntil { session.audioState == .playing }
        XCTAssertTrue(playing)
        session.stop()
        let stopped = await waitUntil { mac.latestAudioSource?.stopped == true }
        XCTAssertTrue(stopped, "停流后 Mac 不该还在采声音")
    }

    /// 老 Mac 不报 `desktop-audio`：手机不显示也不发声音开关（老 Mac 收到不认识的消息会断开整条连接）。
    func test_old_mac_without_audio_feature_gets_no_audio_messages() async throws {
        let features = RemoteConstants.localFeatures.filter { $0 != RemoteFeature.desktopAudio }
        let (server, mac, client) = try await makeRig(features: features)
        defer { server.stop() }
        XCTAssertFalse(client.supportsDesktopAudio)
        let (session, output) = makeSession(client)
        defer { session.stop() }
        await session.start()
        XCTAssertFalse(session.supportsAudio)
        session.setAudio(true)
        XCTAssertFalse(output.isPlaying)
        XCTAssertEqual(session.audioState, .off)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(mac.audioSources.isEmpty)
    }
}
