import CoreGraphics
import CoreVideo
import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远程桌面端到端（回环）：合成采集源 → 真实的 `RemoteHostServer` / `RemoteDesktopStreamer` / 低延迟硬编 →
/// 127.0.0.1 上的加密链路 → 真实的手机侧 `RemoteMacClient` + `RemoteDesktopSession`（与 uTermMobile 同一份代码）→ 硬解。
/// 只有采集与注入换成了夹具（测试进程没有屏幕录制 / 辅助功能授权）。
@MainActor
final class RemoteDesktopEndToEndTests: XCTestCase {

    /// 手机端收到并解好的帧（解码队列上写，测试读）。
    private final class Screen: @unchecked Sendable {
        struct Shown {
            let sequence: UInt32
            /// 主流的关键帧（旁路精修帧虽然也是关键帧，不算在这里）。
            let keyframe: Bool
            let refine: Bool
            let sidecar: Bool
            let blocks: [Double]
            let width: Int
            let height: Int
        }
        private let lock = NSLock()
        private var shown: [Shown] = []
        private var cursors: [RemoteDesktopCursor] = []

        func add(_ image: CVPixelBuffer, _ frame: RemoteDesktopFrame) {
            let sidecar = frame.flags.contains(.sidecar)
            let item = Shown(sequence: frame.sequence, keyframe: frame.isKeyframe && !sidecar,
                             refine: frame.flags.contains(.refine), sidecar: sidecar,
                             blocks: RemoteDesktopFixture.blockLuma(image),
                             width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
            lock.lock(); shown.append(item); lock.unlock()
        }

        func add(_ cursor: RemoteDesktopCursor) { lock.lock(); cursors.append(cursor); lock.unlock() }

        var frames: [Shown] { lock.lock(); defer { lock.unlock() }; return shown }
        var lastCursor: RemoteDesktopCursor? { lock.lock(); defer { lock.unlock() }; return cursors.last }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return true
    }

    private func matches(_ shown: Screen.Shown, seed: Int) -> Bool {
        (0..<16).allSatisfy { abs(shown.blocks[$0] - Double(RemoteDesktopFixture.lumaValue(block: $0, seed: seed))) < 6 }
    }

    /// 服务端（不广播，只在 127.0.0.1 监听）+ 已预先互信的手机客户端（已连上）。
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

    private func makeSession(_ client: RemoteMacClient, codec: RemoteVideoCodec = .hevc) -> (RemoteDesktopSession, Screen) {
        // 手机横屏 2622×1206 → Mac 3024×1964 的主屏按高度受限，视频 1856×1206。
        let session = RemoteDesktopSession(client: client, maxWidth: 1206, maxHeight: 2622, codec: codec)
        let screen = Screen()
        session.receiver.setHandlers(onImage: { image, frame in screen.add(image, frame) },
                                     onCursor: { screen.add($0) })
        return (session, screen)
    }

    // MARK: - 主流程

    func test_stream_decode_input_cursor_refine_keyframe_reconnect_and_mac_side_end() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        XCTAssertTrue(client.supportsDesktop, "新版 Mac 握手时报 desktop 能力")
        let (session, screen) = makeSession(client)
        defer { session.stop() }

        // 1. Mac 上没开远程桌面：被拒，但连接不断（终端远控照常可用）。
        mac.enabled = false
        await session.start()
        guard case .failed(let message) = session.state else { return XCTFail("应被拒：\(session.state)") }
        XCTAssertTrue(message.contains("没有打开远程桌面"), message)
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(mac.sources.isEmpty, "被拒时不该开采集")

        // 2. 打开：开流成功，第一帧是关键帧，内容逐块一致。
        mac.enabled = true
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let info = try XCTUnwrap(session.info)
        XCTAssertEqual(info.streamWidth, 1856)
        XCTAssertEqual(info.streamHeight, 1206)
        XCTAssertEqual(info.displayWidth, 1512)
        XCTAssertTrue(info.canControl)
        XCTAssertEqual(server.desktopViewer?.deviceName, LANSyncCoordinator.localDeviceName())
        let first = await waitUntil { !screen.frames.isEmpty }
        XCTAssertTrue(first, "开流后应收到第一帧")
        let firstFrame = try XCTUnwrap(screen.frames.first)
        XCTAssertTrue(firstFrame.keyframe)
        XCTAssertEqual(firstFrame.width, 1856)
        XCTAssertEqual(firstFrame.height, 1206)
        XCTAssertTrue(matches(firstFrame, seed: 1), "\(firstFrame.blocks)")

        // 3. 画面变化逐帧送达，都是 P 帧。
        let source = try XCTUnwrap(mac.latestSource)
        for _ in 0..<5 {
            let seed = source.emit()
            let arrived = await waitUntil { screen.frames.contains { self.matches($0, seed: seed) } }
            XCTAssertTrue(arrived, "帧 \(seed) 没到")
        }
        XCTAssertEqual(screen.frames.filter(\.keyframe).count, 1, "追上时不强制关键帧：只有开流那一帧")
        // 这之后画面不再变：最后这张第一次显示出来起，是同一段静止（前面几步之间若隔了 300 ms 以上，
        // 各自也会精修）。按显示的那一帧定起点，不按此刻的帧数：机器忙时精修可能早于这一行就到了。
        let stillSeed = try XCTUnwrap(source.emitted.last)
        let stillFrom = try XCTUnwrap(screen.frames.firstIndex { !$0.refine && matches($0, seed: stillSeed) }) + 1

        // 4. 输入在 Mac 的连接队列上直接交给注入器，顺序与取值不变。
        let inputs: [RemoteDesktopInput] = [
            .move(x: 0.25, y: 0.5),
            .button(.left, down: true, clickCount: 1, x: 0.25, y: 0.5, modifiers: []),
            .move(x: 0.3, y: 0.55),
            .button(.left, down: false, clickCount: 1, x: 0.3, y: 0.55, modifiers: []),
            .scroll(dx: 0, dy: -40, phase: .changed),
            .key(code: 0x08, down: true, modifiers: [.command]),
            .key(code: 0x08, down: false, modifiers: [.command]),
            .text("你好"),
        ]
        for input in inputs { session.send(input) }
        let injected = await waitUntil { mac.injector.all.count == inputs.count }
        XCTAssertTrue(injected)
        XCTAssertEqual(mac.injector.all, inputs)
        // 粘贴：图片与文字原样到达 Mac 的落点（生产里写剪贴板再按 ⌘V）。
        XCTAssertTrue(session.canPaste)
        // 大图走分块。后面的小内容不能抢到前面去。
        let pastes: [RemoteDesktopPaste] = [.png(Data(repeating: 7, count: 200_000)), .text("剪贴板里的字"),
                                            .jpeg(Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) }))]
        for content in pastes { session.paste(content) }
        let pasted = await waitUntil { mac.injector.allPastes.count == pastes.count }
        XCTAssertTrue(pasted)
        XCTAssertEqual(mac.injector.allPastes, pastes)
        let controlling = await waitUntil { server.desktopViewer?.isControlling == true }
        XCTAssertTrue(controlling, "收到输入后 Mac 上的指示改成「正在控制」")

        // 5. 光标：Mac 上的位置按显示器归一化发过来。
        mac.moveCursor(to: CGPoint(x: 378, y: 245.5))
        let cursor = await waitUntil {
            guard let c = screen.lastCursor else { return false }
            return abs(c.x - 0.25) < 1e-4 && abs(c.y - 0.25) < 1e-4 && c.visible
        }
        XCTAssertTrue(cursor, "\(String(describing: screen.lastCursor))")

        // 6. 静止 300 ms 后精修一次（只一次）：新手机走旁路——另一个会话编的关键帧，画面就是当前这张。
        //    例外：拥塞控制已把码率压到下限时按设计不发旁路精修（链路真的很差）。机器忙到「采集 → 手机解码完」
        //    连续超过拥塞阈值时测试里也会这样，那就核对「没精修」。
        let refined = await waitUntil(2) { screen.frames.dropFirst(stillFrom).contains(where: \.refine) }
        try? await Task.sleep(for: .milliseconds(600))
        let refines = screen.frames.dropFirst(stillFrom).filter(\.refine)
        let bitrates = server.desktopStats?.snapshot().bitrateHistory ?? []
        let floor = RemoteRateController.config(width: 1856, height: 1206).minBitrate
        if let bitrate = bitrates.last, bitrate <= floor {
            XCTAssertTrue(refines.isEmpty, "码率已降到 \(bitrate)（\(bitrates)），不该精修")
        } else {
            XCTAssertTrue(refined, "画面静止后应有一帧精修（码率变化 \(bitrates)）")
            XCTAssertEqual(refines.count, 1, "同一段静止只精修一次")
            XCTAssertTrue(refines.allSatisfy(\.sidecar), "声明了 sidecarRefine 的手机收到的是旁路精修帧")
            XCTAssertTrue(refines.allSatisfy { matches($0, seed: stillSeed) }, "精修的是当前画面")
        }

        // 7. 手机要关键帧（回前台 / 解码出错）：静止画面也会补一个关键帧。
        session.requestKeyframe()
        let keyed = await waitUntil { screen.frames.filter(\.keyframe).count == 2 }
        XCTAssertTrue(keyed, "请求后应补一个关键帧")

        // 8. 断线：会话自己重连、重新开流，Mac 重新采集，第一帧关键帧画面接上。
        let before = screen.frames.count
        client.disconnect()
        let dropped = await waitUntil {
            if case .reconnecting = session.state { return true }
            return false
        }
        XCTAssertTrue(dropped, "断线后应进入重连：\(session.state)")
        let back = await waitUntil(10) { session.state == .streaming && screen.frames.count > before }
        XCTAssertTrue(back, "应自动重连并恢复画面：\(session.state)")
        XCTAssertEqual(mac.sources.count, 2, "重连 = 新的一路采集")
        XCTAssertTrue(mac.sources[0].stopped, "旧连接断开时旧采集要停")
        XCTAssertTrue(screen.frames[before].keyframe, "重连后的第一帧是关键帧")

        // 9. 在 Mac 上断开：手机收到「已结束」而不是去重连；Mac 停采集、撤指示。
        server.endDesktop(reason: "已在 Mac 上断开")
        let ended = await waitUntil { session.state == .ended("已在 Mac 上断开") }
        XCTAssertTrue(ended, "\(session.state)")
        XCTAssertNil(server.desktopViewer)
        let stopped = await waitUntil { mac.sources[1].stopped }
        XCTAssertTrue(stopped)
        XCTAssertEqual(client.state, .connected, "结束桌面流不断开整条连接")
    }

    // MARK: - 老手机

    func test_phone_without_sidecar_support_gets_refine_inside_the_main_stream() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        client.disconnect()
        // 原始链路的开流请求不带 `sidecarRefine`，就是升级前的手机：旁路帧它不会分开解，不能发给它。
        let (link, inbox, channel) = try await rawPhone(server)
        defer { link.close() }
        XCTAssertNotNil(mac.latestSource)
        var acknowledged = 0
        let refined = await waitUntil(3) {
            let frames = (try? inbox.of(.desktopFrame).map { try RemoteDesktopFrame(decoding: $0.payload) }) ?? []
            for frame in frames.dropFirst(acknowledged) {
                link.send(RemoteMessage(.desktopAck, channel: channel, payload: RemoteDesktopAck(
                    sequence: frame.sequence, captureNanos: frame.captureNanos, decodeMicros: 1000).encoded()))
            }
            acknowledged = frames.count
            return frames.contains { $0.flags.contains(.refine) }
        }
        XCTAssertTrue(refined, "静止后应有一帧精修")
        let frames = try inbox.of(.desktopFrame).map { try RemoteDesktopFrame(decoding: $0.payload) }
        XCTAssertFalse(frames.contains { $0.flags.contains(.sidecar) }, "老手机不收旁路帧")
        let refine = try XCTUnwrap(frames.first { $0.flags.contains(.refine) })
        XCTAssertFalse(refine.isKeyframe, "老手机的精修仍是主流里的 P 帧")
        // 整条流用同一个解码器从头解到精修帧，解得出来（参考链没断）。
        let decoder = RemoteVideoDecoder()
        for frame in frames { _ = try decoder.decode(frame) }
    }

    // MARK: - 背压（真实服务端 + 不回确认的原始客户端）

    func test_streamer_stops_at_two_unacknowledged_frames_and_sends_latest_after_ack() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        client.disconnect()
        // 用原始链路扮演一个「解码很慢」的手机：收帧但不回确认。
        let (link, inbox, channel) = try await rawPhone(server)
        defer { link.close() }
        let source = try XCTUnwrap(mac.latestSource)

        // 不回确认，连续来 10 帧新画面：只有前 2 帧被编码发出，其余在编码前丢掉（只留最新一张）。
        var lastSeed = 0
        for _ in 0..<10 {
            lastSeed = source.emit()
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(inbox.of(.desktopFrame).count, 2, "在途 2 帧未确认时不再编码")
        let stats = try XCTUnwrap(server.desktopStats).snapshot()
        XCTAssertGreaterThanOrEqual(stats.congestionDrops, 8)

        // 确认第一帧：立刻编出「最新」的那张（而不是被丢的中间某张）。
        let frames = try inbox.of(.desktopFrame).map { try RemoteDesktopFrame(decoding: $0.payload) }
        link.send(RemoteMessage(.desktopAck, channel: channel, payload: RemoteDesktopAck(
            sequence: frames[0].sequence, captureNanos: frames[0].captureNanos, decodeMicros: 1000).encoded()))
        let resumed = await waitUntil { inbox.of(.desktopFrame).count == 3 }
        XCTAssertTrue(resumed, "确认回来就编留着的那帧")
        let all = try inbox.of(.desktopFrame).map { try RemoteDesktopFrame(decoding: $0.payload) }
        let decoder = RemoteVideoDecoder()
        var last: CVPixelBuffer?
        for frame in all { last = try decoder.decode(frame) }
        XCTAssertFalse(all[2].isKeyframe, "追上时不强制关键帧（TCP 不丢已编码帧）")
        let blocks = RemoteDesktopFixture.blockLuma(try XCTUnwrap(last))
        for block in 0..<16 {
            XCTAssertEqual(blocks[block], Double(RemoteDesktopFixture.lumaValue(block: block, seed: lastSeed)), accuracy: 6)
        }
        // 伪造 / 重复的确认不影响计数。
        link.send(RemoteMessage(.desktopAck, channel: channel, payload: RemoteDesktopAck(
            sequence: frames[0].sequence, captureNanos: 0, decodeMicros: 0).encoded()))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(inbox.of(.desktopFrame).count, 3)
    }

    /// 一个直接用 `RemoteLink` 说话的「手机」（已被 Mac 信任），开好一路桌面流，返回桌面通道。
    private func rawPhone(_ server: RemoteHostServer) async throws -> (RemoteLink, MessageInbox, UInt32) {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let id = UUID()
        try server.trust(RemotePeer(id: id, name: "原始手机", publicKey: phone.publicKey.rawRepresentation, pairedAt: Date()))
        let inbox = MessageInbox()
        let link = RemoteLink(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!,
                                                       using: RemoteLink.parameters()))
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        _ = try await link.establish(role: .initiator,
                                     hello: RemoteHello(version: 1, deviceID: id, deviceName: "原始手机",
                                                        ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                                        staticKey: phone.publicKey.rawRepresentation),
                                     staticKey: phone, ephemeralKey: ephemeral)
        let paired = await waitUntil { inbox.of(.pairing).count == 1 }
        XCTAssertTrue(paired)
        link.send(RemoteMessage(.desktopStart, payload: RemoteJSON.encode(
            RemoteDesktopStartRequest(requestID: UUID(), maxWidth: 1280, maxHeight: 800, codec: .hevc))))
        let started = await waitUntil { inbox.first(.desktopStarted) != nil && inbox.of(.desktopFrame).count == 1 }
        XCTAssertTrue(started)
        return (link, inbox, try XCTUnwrap(inbox.first(.desktopStarted)).channel)
    }

    // MARK: - 兼容与门禁

    func test_stopping_the_stream_releases_buttons_on_the_mac() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, _) = makeSession(client)
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        session.send(.button(.left, down: true, clickCount: 1, x: 0.5, y: 0.5, modifiers: []))
        let pressed = await waitUntil { mac.injector.all.count == 1 }
        XCTAssertTrue(pressed)
        XCTAssertEqual(mac.injector.releaseCount, 0)

        session.stop()

        let released = await waitUntil { mac.injector.releaseCount == 1 }
        XCTAssertTrue(released, "手机走了发不来抬起事件，Mac 要自己松开")
    }

    func test_old_mac_without_desktop_feature_is_reported_without_breaking_the_connection() async throws {
        let (server, mac, client) = try await makeRig(features: [])
        defer { server.stop() }
        XCTAssertFalse(client.supportsDesktop)
        let (session, _) = makeSession(client)
        await session.start()
        XCTAssertEqual(session.state, .unsupported)
        XCTAssertTrue(mac.sources.isEmpty)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.state, .connected, "不该把桌面消息发给不认识它的 Mac（会断开整条连接）")
    }

    func test_screen_permission_rejection_and_view_only_mode() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, screen) = makeSession(client)
        defer { session.stop() }
        mac.screenAuthorized = false
        await session.start()
        guard case .failed(let message) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertTrue(message.contains("屏幕录制"), message)

        mac.screenAuthorized = true
        mac.canControl = false
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(session.info?.canControl, false)
        XCTAssertNotNil(session.info?.controlNote)
        let shown = await waitUntil { !screen.frames.isEmpty }
        XCTAssertTrue(shown, "只能看也照样出画面")
        session.send(.move(x: 0.5, y: 0.5))
        XCTAssertFalse(session.canPaste, "只能看时不给粘贴")
        session.paste(.text("x"))
        session.stop()
        // 越过手机端的门禁直接发输入：Mac 没建注入器，同样落空。
        let (link, _, channel) = try await rawPhone(server)
        defer { link.close() }
        XCTAssertEqual(server.desktopViewer?.canControl, false)
        link.send(RemoteMessage(.desktopInput, channel: channel, payload: RemoteDesktopInput.move(x: 0, y: 0).encoded()))
        link.send(RemoteMessage(.desktopInput, channel: channel &+ 100, payload: RemoteDesktopInput.text("x").encoded()))
        link.send(RemoteMessage(.desktopPaste, channel: channel, payload: RemoteDesktopPaste.text("x").encoded()))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(mac.injector.all.isEmpty)
        XCTAssertTrue(mac.injector.allPastes.isEmpty, "只能看时越过门禁硬发粘贴，Mac 也不写剪贴板")
    }

    func test_second_device_takes_over_the_desktop() async throws {
        // 夹具 Mac 要活到用例结束：环境闭包只弱引用它（丢给 `_` 会立刻释放，Mac 就成了「没开远程桌面」）。
        let (server, mac, client) = try await makeRig()
        defer { server.stop(); withExtendedLifetime(mac) {} }
        let (first, _) = makeSession(client)
        defer { first.stop() }
        await first.start()
        XCTAssertEqual(first.state, .streaming)

        // 第二台设备（另一份身份）：首次要在 Mac 上审批。
        let other = RemoteMacClient(macName: "测试 Mac",
                                    endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!),
                                    identity: RemoteIdentityStore(storage: RemoteMemoryStorage()))
        let connecting = Task { await other.connect() }
        let asked = await waitUntil { !server.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        let (second, _) = makeSession(other)
        defer { second.stop() }
        await second.start()
        XCTAssertEqual(second.state, .streaming)
        let takenOver = await waitUntil {
            if case .ended(let reason) = first.state { return reason.contains("接管") }
            return false
        }
        XCTAssertTrue(takenOver, "\(first.state)")
        other.disconnect()
    }

    // MARK: - 探针（只记录读数，不设断言）

    /// 回环满负荷：每帧都变的高细节画面以 60 fps 连续 3 s，读编码耗时、「采集 → 手机解码完并确认回 Mac」往返、
    /// 解码耗时、实发帧率与码率；再静止 1 s，读静止期的发送量（应只有一帧精修）。
    func test_probe_loopback_stream_readings() async throws {
        for codec in RemoteVideoCodec.allCases {
            try await probe(codec: codec)
        }
    }

    private func probe(codec: RemoteVideoCodec) async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.detail = true
        let (session, screen) = makeSession(client, codec: codec)
        defer { session.stop() }
        let attachStart = Date()
        await session.start()
        _ = await waitUntil { !screen.frames.isEmpty }
        let firstFrameMs = Date().timeIntervalSince(attachStart) * 1000
        let source = try XCTUnwrap(mac.latestSource)
        source.prepareCycle(count: 12)
        let streamStats = try XCTUnwrap(server.desktopStats)
        let begin = streamStats.snapshot()
        source.run(fps: 60)
        try? await Task.sleep(for: .seconds(3))
        source.pause()
        let busy = streamStats.snapshot()
        try? await Task.sleep(for: .seconds(1))
        let idle = streamStats.snapshot()

        let sent = busy.sent - begin.sent
        let bytes = busy.bytes - begin.bytes
        let encode = busy.encodeNanos.suffix(sent).map { Double($0) / 1e6 }
        let roundTrip = busy.roundTripNanos.suffix(sent).map { Double($0) / 1e6 }
        let decode = busy.decodeMicros.suffix(sent).map { Double($0) / 1000 }
        let p = RemoteDesktopFixture.percentile
        print(String(format: "[桌面探针] %@ 1856×1206 回环 60fps×3s：首帧 %.1f ms；实发 %.1f fps（采集 %d，拥塞丢 %d，码控丢 %d）；"
                     + "编码 p50 %.2f / p95 %.2f ms；采集→手机解码完→确认回 Mac p50 %.2f / p95 %.2f ms；"
                     + "解码 p50 %.2f / p95 %.2f ms；%.2f Mbps，平均 %.1f KB/帧；码率档 %@",
                     codec.rawValue, firstFrameMs, Double(sent) / 3, busy.captured - begin.captured,
                     busy.congestionDrops - begin.congestionDrops, busy.encoderDrops - begin.encoderDrops,
                     p(encode, 0.5), p(encode, 0.95), p(roundTrip, 0.5), p(roundTrip, 0.95), p(decode, 0.5), p(decode, 0.95),
                     Double(bytes) * 8 / 3 / 1e6, Double(bytes) / Double(max(1, sent)) / 1024,
                     busy.bitrateHistory.map { String(format: "%.1f", Double($0) / 1e6) }.joined(separator: "→")))
        print(String(format: "[桌面探针] %@ 静止 1 s：发出 %d 帧（精修 %d，码控丢 %d），%d 字节",
                     codec.rawValue, idle.sent - busy.sent, idle.refines - busy.refines, idle.encoderDrops - busy.encoderDrops,
                     idle.bytes - busy.bytes))
    }
}

/// 原始链路客户端收到的消息。
private final class MessageInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [RemoteMessage] = []
    func add(_ m: RemoteMessage) { lock.lock(); messages.append(m); lock.unlock() }
    var all: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    func first(_ kind: RemoteMessage.Kind) -> RemoteMessage? { all.first { $0.kind == kind } }
    func of(_ kind: RemoteMessage.Kind) -> [RemoteMessage] { all.filter { $0.kind == kind } }
}
