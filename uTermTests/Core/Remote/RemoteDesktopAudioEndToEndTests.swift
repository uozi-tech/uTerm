import AppKit
import CryptoKit
@preconcurrency import Network
import SwiftUI
import XCTest
@testable import uTerm

/// 远程桌面声音端到端（回环，调研 §17）：合成声源 → 真实的 `RemoteHostConnection` / `RemoteAudioStreamer` / Opus 编码 →
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
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      localFeatures: features, desktopEnvironment: mac.environment())
        server.start()
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready, "服务端没起来：\(server.status)")
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
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

    /// 开了马上关：两条消息先后到 Mac，开声音那次要等一拍才开采集，关先执行。关必须作废那次开，
    /// 不然 Mac 一直采集、发送，手机却已经不放了。
    func test_turning_audio_on_then_off_immediately_leaves_mac_quiet() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, _) = makeSession(client)
        defer { session.stop() }
        await session.start()
        for _ in 0..<5 {
            session.setAudio(true)
            session.setAudio(false)
        }
        XCTAssertEqual(session.audioState, .off)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(mac.audioSources.allSatisfy(\.stopped), "开关交错后 Mac 不该还有在采集的声音")
        XCTAssertNotEqual(server.desktopViewer?.hasAudio, true, "Mac 的指示条不该还显示在传声音")
        XCTAssertEqual(session.audioReceiver.snapshot().received, 0)
    }

    /// 手机上的声音打不开（如通话中）：不要叫 Mac 开声音。
    func test_phone_playback_failure_does_not_ask_mac_for_audio() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, output) = makeSession(client)
        defer { session.stop() }
        await session.start()
        output.startError = NSError(domain: "测试", code: 1)
        session.setAudio(true)
        guard case .unavailable = session.audioState else { return XCTFail("\(session.audioState)") }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(mac.audioSources.allSatisfy(\.stopped), "手机放不了，Mac 不该在采集")
        XCTAssertNotEqual(server.desktopViewer?.hasAudio, true)
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

    // MARK: - 工具栏扬声器按钮（手机与 Mac 主控端共用 `toggleAudio` / `restoreAudioIfWanted`）

    private func scratchDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "RemoteDesktopAudioToggle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    /// 点按钮：叫 Mac 开 / 关声音，并按这台 Mac 记住选择。
    func test_toolbar_toggle_turns_mac_audio_on_and_off_and_remembers_the_choice() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let macID = try XCTUnwrap(client.macDeviceID)
        let (session, output) = makeSession(client)
        defer { session.stop() }
        await session.start()
        XCTAssertFalse(session.isAudioOn)
        XCTAssertNil(session.audioStatsText)

        session.toggleAudio(defaults: defaults)
        XCTAssertTrue(session.isAudioOn)
        XCTAssertTrue(output.isPlaying)
        let capturing = await waitUntil { mac.latestAudioSource?.started == true && session.audioState == .playing }
        XCTAssertTrue(capturing, "Mac 应开始采集并回格式：\(session.audioState)")
        XCTAssertTrue(RemoteDesktopAudioPreference.wantsAudio(mac: macID, defaults: defaults))
        XCTAssertNotNil(session.audioStatsText)

        session.toggleAudio(defaults: defaults)
        XCTAssertFalse(session.isAudioOn)
        XCTAssertFalse(output.isPlaying)
        let source = try XCTUnwrap(mac.latestAudioSource)
        let stopped = await waitUntil { source.stopped }
        XCTAssertTrue(stopped, "关掉后 Mac 停采集")
        XCTAssertFalse(RemoteDesktopAudioPreference.wantsAudio(mac: macID, defaults: defaults))
        XCTAssertEqual(session.state, .streaming)
    }

    /// 上次看这台 Mac 时开着声音：开流后自动打开；没开过就不动。
    func test_restore_reopens_audio_only_when_remembered_for_this_mac() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let (session, _) = makeSession(client)
        defer { session.stop() }
        await session.start()

        session.restoreAudioIfWanted(defaults: defaults)
        XCTAssertEqual(session.audioState, .off, "没记过就不开")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(mac.audioSources.isEmpty)

        RemoteDesktopAudioPreference.setWantsAudio(true, mac: try XCTUnwrap(client.macDeviceID), defaults: defaults)
        session.restoreAudioIfWanted(defaults: defaults)
        let playing = await waitUntil { session.audioState == .playing && mac.latestAudioSource?.started == true }
        XCTAssertTrue(playing, "\(session.audioState)")
    }

    /// 那台 Mac 不支持声音：按钮不显示；就算被调到也不发消息、不记选择。
    func test_toolbar_toggle_is_inert_without_audio_capability() async throws {
        let features = RemoteConstants.localFeatures.filter { $0 != RemoteFeature.desktopAudio }
        let (server, mac, client) = try await makeRig(features: features)
        defer { server.stop() }
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let (session, output) = makeSession(client)
        defer { session.stop() }
        await session.start()
        XCTAssertFalse(session.supportsAudio, "工具栏据此隐藏扬声器按钮")

        session.toggleAudio(defaults: defaults)
        XCTAssertFalse(session.isAudioOn)
        XCTAssertFalse(output.isPlaying)
        XCTAssertFalse(RemoteDesktopAudioPreference.wantsAudio(mac: try XCTUnwrap(client.macDeviceID), defaults: defaults))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(mac.audioSources.isEmpty)
    }

    /// Mac 主控端工具栏截图（开声音前后、老 Mac 无按钮）。设置 `UTERM_REMOTE_SHOTS` 才跑，见 `RemoteMacControllerSnapshotTests`。
    func test_render_mac_desktop_toolbar_audio_states() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_REMOTE_SHOTS"] ?? env["TEST_RUNNER_UTERM_REMOTE_SHOTS"], !raw.isEmpty else {
            throw XCTSkip("设置 UTERM_REMOTE_SHOTS=<目录> 才拍工具栏截图")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }

        func shoot(_ name: String, _ model: RemoteDesktopWindowModel) async throws {
            let size = NSSize(width: 900, height: 160)
            let host = NSHostingView(rootView: RemoteDesktopContent(model: model)
                .background(Color.black).environment(\.colorScheme, .dark).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                          contentView: host, placement: .offScreen)
            defer { window.orderOut(nil) }
            window.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("\(name).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(name).png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, _) = makeSession(client)
        defer { session.stop() }
        let model = RemoteDesktopWindowModel(client: client, session: session)
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        try await shoot("desktop-toolbar-audio-off", model)
        session.toggleAudio(defaults: defaults)
        let playing = await waitUntil { session.audioState == .playing }
        XCTAssertTrue(playing, "\(session.audioState)")
        try await shoot("desktop-toolbar-audio-on", model)

        let old = RemoteConstants.localFeatures.filter { $0 != RemoteFeature.desktopAudio }
        let (oldServer, oldMac, oldClient) = try await makeRig(features: old)
        defer { oldServer.stop() }
        let (oldSession, _) = makeSession(oldClient)
        defer { oldSession.stop() }
        await oldSession.start()
        XCTAssertEqual(oldSession.state, .streaming)
        try await shoot("desktop-toolbar-old-mac", RemoteDesktopWindowModel(client: oldClient, session: oldSession))
        // 假 Mac 在服务端只是弱引用，测试期间要留着，不然远程桌面会被当成没打开。
        withExtendedLifetime((mac, oldMac)) {}
        print("[remote-shots] dir=\(dir.path)")
    }
}
