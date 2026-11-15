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
        // 手机的「粘贴到 Mac」等全部交给链路才返回，一路报发送进度，最后一次是 100%。
        let big = RemoteDesktopPaste.png(Data(repeating: 9, count: 150_000))
        let reports = PasteReports()
        try await PasteProgressReporter.$sink.withValue({ reports.add($0) }) {
            try await session.pasteAndWait(big)
        }
        let sent = reports.all
        XCTAssertEqual(sent.map(\.overall), sent.map(\.overall).sorted(), "发送进度不能往回走")
        XCTAssertEqual(sent.last?.phase, .sending)
        XCTAssertEqual(sent.last?.fraction, 1)
        XCTAssertGreaterThan(sent.count, 1, "分块发送应逐块报进度")
        let pastedBig = await waitUntil { mac.injector.allPastes.last == big }
        XCTAssertTrue(pastedBig)
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

    // MARK: - 退到后台

    /// 老 Mac（不认得 `desktopPause`）：App 退到后台（切走 / 锁屏）时流还在走：帧照收照确认——Mac 不会因为在途满了
    /// 停发、也不会因为丢帧降码率——但不解码、不渲染。回前台后从关键帧接上，不往屏幕上送参考已断的 P 帧。
    /// 手机不能把暂停消息发给它（老 Mac 会当未知消息断开整条连接），关键帧要靠手机自己要。
    func test_backgrounded_phone_acks_without_decoding_and_resumes_from_a_keyframe() async throws {
        let (server, mac, client) = try await makeRig(features: RemoteConstants.localFeatures.filter { $0 != RemoteFeature.desktopPause })
        defer { server.stop() }
        XCTAssertFalse(client.supportsDesktopPause)
        let (session, screen) = makeSession(client)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let first = await waitUntil { !screen.frames.isEmpty }
        XCTAssertTrue(first, "开流后应收到第一帧")
        let source = try XCTUnwrap(mac.latestSource)

        session.setBackgrounded(true)
        // 暂停之前已经进了解码队列的帧可能还会显示出来：等它们走完再记起点。
        try? await Task.sleep(for: .milliseconds(200))
        let shownBefore = screen.frames.count
        let skippedBefore = session.receiver.stats.snapshot().skippedFrames
        // 在途上限最多 8 帧：跳过的帧远多于它，说明确认一直在回、Mac 一直在编。
        let streamed = await waitUntil(8) {
            _ = source.emit()
            try? await Task.sleep(for: .milliseconds(30))
            return session.receiver.stats.snapshot().skippedFrames - skippedBefore >= 16
        }
        XCTAssertTrue(streamed, "后台时 Mac 应照常收到确认并继续发帧")
        XCTAssertEqual(screen.frames.count, shownBefore, "后台时不解码、不渲染")
        XCTAssertEqual(session.state, .streaming, "暂停不影响连接")

        // 不另调 `requestKeyframe`：回前台时会话自己要关键帧。
        session.setBackgrounded(false)
        var latest = 0
        let resumed = await waitUntil(5) {
            latest = source.emit()
            try? await Task.sleep(for: .milliseconds(30))
            return screen.frames.dropFirst(shownBefore).contains { !$0.sidecar && self.matches($0, seed: latest) }
        }
        XCTAssertTrue(resumed, "回前台后画面应恢复")
        let firstMain = try XCTUnwrap(screen.frames.dropFirst(shownBefore).first { !$0.sidecar })
        XCTAssertTrue(firstMain.keyframe, "回前台后主流第一张必须是关键帧")
    }

    /// 新 Mac：手机退到后台就请 Mac 停止推流——采集照旧，但一帧不发、光标也不发，连接、码率都不动；回前台 Mac 立刻
    /// 补一个关键帧（屏幕静止也补，只补一个），之后照常推流。
    func test_backgrounded_phone_pauses_the_mac_and_resumes_from_one_keyframe() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        XCTAssertTrue(client.supportsDesktopPause, "新版 Mac 握手时报 desktop-pause 能力")
        let (session, screen) = makeSession(client)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let first = await waitUntil { !screen.frames.isEmpty }
        XCTAssertTrue(first, "开流后应收到第一帧")
        let source = try XCTUnwrap(mac.latestSource)
        let stats = try XCTUnwrap(server.desktopStats)

        session.setBackgrounded(true)
        // 暂停消息到达之前已经编好、在路上的帧让它走完再记起点。
        try? await Task.sleep(for: .milliseconds(200))
        let paused = stats.snapshot()
        let cursorBefore = screen.lastCursor
        mac.moveCursor(to: CGPoint(x: 756, y: 491))
        for _ in 0..<30 {
            _ = source.emit()
            try? await Task.sleep(for: .milliseconds(30))
        }
        let during = stats.snapshot()
        XCTAssertEqual(during.sent, paused.sent, "暂停期间 Mac 一帧都不发")
        XCTAssertGreaterThanOrEqual(during.captured - paused.captured, 20, "采集照旧（恢复时要有最新画面可编）")
        XCTAssertEqual(screen.lastCursor, cursorBefore, "暂停期间光标也不发")
        XCTAssertEqual(during.bitrateHistory, paused.bitrateHistory, "暂停不动码率")
        XCTAssertEqual(session.state, .streaming, "暂停不影响桌面流")
        XCTAssertEqual(client.state, .connected, "暂停不影响连接")
        XCTAssertNotNil(server.desktopViewer, "Mac 上仍显示有人在看")

        // 回前台：屏幕此刻是静止的，Mac 也要立刻补一个关键帧，画面就是暂停期间最后那张。
        let shownBefore = screen.frames.count
        let stillSeed = try XCTUnwrap(source.emitted.last)
        session.setBackgrounded(false)
        let resumed = await waitUntil {
            screen.frames.dropFirst(shownBefore).contains { !$0.sidecar && self.matches($0, seed: stillSeed) }
        }
        XCTAssertTrue(resumed, "回前台后应立刻收到当前画面")
        let firstMain = try XCTUnwrap(screen.frames.dropFirst(shownBefore).first { !$0.sidecar })
        XCTAssertTrue(firstMain.keyframe, "回前台后主流第一张必须是关键帧")
        let cursorBack = await waitUntil {
            guard let c = screen.lastCursor else { return false }
            return abs(c.x - 0.5) < 1e-3 && abs(c.y - 0.5) < 1e-3
        }
        XCTAssertTrue(cursorBack, "恢复后补发当前光标：\(String(describing: screen.lastCursor))")

        // 之后照常推流（P 帧）；恢复只补了一个关键帧（「恢复」本身就是关键帧请求，手机不再另要）。
        for _ in 0..<3 {
            let seed = source.emit()
            let arrived = await waitUntil { screen.frames.contains { !$0.sidecar && self.matches($0, seed: seed) } }
            XCTAssertTrue(arrived, "恢复后帧 \(seed) 没到")
        }
        let afterResume = screen.frames.dropFirst(shownBefore).filter { !$0.sidecar }
        XCTAssertEqual(afterResume.filter(\.keyframe).count, 1, "恢复只补一个关键帧：\(afterResume.map(\.keyframe))")
        XCTAssertEqual(stats.snapshot().keyframes - during.keyframes, 1)
    }

    /// 在后台里重连上（回前台前最后那几秒常见）：新流在 Mac 那边从不暂停起步，手机开好后再请它暂停一次。
    func test_stream_reopened_while_backgrounded_is_paused_again() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, screen) = makeSession(client)
        defer { session.stop() }
        await session.start()
        let first = await waitUntil { !screen.frames.isEmpty }
        XCTAssertTrue(first, "开流后应收到第一帧")

        session.setBackgrounded(true)
        client.disconnect()
        let back = await waitUntil(10) { session.state == .streaming && mac.sources.count == 2 }
        XCTAssertTrue(back, "应自动重连：\(session.state)")
        // 新流的第一帧（关键帧）可能赶在暂停消息之前发出：等它走完。
        try? await Task.sleep(for: .milliseconds(300))
        let source = try XCTUnwrap(mac.latestSource)
        let stats = try XCTUnwrap(server.desktopStats)
        let paused = stats.snapshot()
        for _ in 0..<20 {
            _ = source.emit()
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(stats.snapshot().sent, paused.sent, "后台里重开的流也要暂停")

        let shownBefore = screen.frames.count
        session.setBackgrounded(false)
        let latest = try XCTUnwrap(source.emitted.last)
        let resumed = await waitUntil {
            screen.frames.dropFirst(shownBefore).contains { !$0.sidecar && self.matches($0, seed: latest) }
        }
        XCTAssertTrue(resumed, "回前台后画面应恢复")
        XCTAssertTrue(try XCTUnwrap(screen.frames.dropFirst(shownBefore).first { !$0.sidecar }).keyframe)
    }

    /// 暂停只属于那一条流：同一连接上重新开流、或断开重连，Mac 都从不暂停起步，不会卡在暂停里。
    func test_pause_does_not_carry_over_to_a_new_stream_or_connection() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        client.disconnect()
        let (link, inbox, channel) = try await rawPhone(server)
        var acknowledged = 0
        func ackAll() {
            let frames = inbox.of(.desktopFrame)
            for message in frames.dropFirst(acknowledged) {
                guard let frame = try? RemoteDesktopFrame(decoding: message.payload) else { continue }
                link.send(RemoteMessage(.desktopAck, channel: message.channel, payload: RemoteDesktopAck(
                    sequence: frame.sequence, captureNanos: frame.captureNanos, decodeMicros: 1000).encoded()))
            }
            acknowledged = frames.count
        }
        ackAll()
        link.send(RemoteMessage(.desktopPause, channel: channel,
                                payload: RemoteJSON.encode(RemoteDesktopPauseRequest(paused: true))))
        try? await Task.sleep(for: .milliseconds(150))
        let pausedCount = inbox.of(.desktopFrame).count
        let firstSource = try XCTUnwrap(mac.latestSource)
        for _ in 0..<15 {
            _ = firstSource.emit()
            ackAll()
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(inbox.of(.desktopFrame).count, pausedCount, "暂停后不再发帧")

        // 同一连接上重新开流：新流照常推。
        link.send(RemoteMessage(.desktopStart, payload: RemoteJSON.encode(
            RemoteDesktopStartRequest(requestID: UUID(), maxWidth: 1280, maxHeight: 800, codec: .hevc))))
        let restarted = await waitUntil { inbox.of(.desktopStarted).count == 2 }
        XCTAssertTrue(restarted)
        let newChannel = try XCTUnwrap(inbox.of(.desktopStarted).last).channel
        XCTAssertNotEqual(newChannel, channel)
        let secondSource = try XCTUnwrap(mac.latestSource)
        let flowing = await waitUntil {
            _ = secondSource.emit()
            ackAll()
            try? await Task.sleep(for: .milliseconds(30))
            return inbox.of(.desktopFrame).filter { $0.channel == newChannel }.count >= 3
        }
        XCTAssertTrue(flowing, "重新开的流不该沿用暂停")
        link.close()

        // 断开重连：新连接上的流同样照常推（`rawPhone` 要等到第一帧才返回）。
        let (link2, inbox2, channel2) = try await rawPhone(server)
        defer { link2.close() }
        var acknowledged2 = 0
        let thirdSource = try XCTUnwrap(mac.latestSource)
        let flowingAgain = await waitUntil {
            _ = thirdSource.emit()
            let frames = inbox2.of(.desktopFrame)
            for message in frames.dropFirst(acknowledged2) {
                guard let frame = try? RemoteDesktopFrame(decoding: message.payload) else { continue }
                link2.send(RemoteMessage(.desktopAck, channel: channel2, payload: RemoteDesktopAck(
                    sequence: frame.sequence, captureNanos: frame.captureNanos, decodeMicros: 1000).encoded()))
            }
            acknowledged2 = frames.count
            try? await Task.sleep(for: .milliseconds(30))
            return frames.count >= 3
        }
        XCTAssertTrue(flowingAgain, "重连后的流不该沿用暂停")
    }

    // MARK: - 精修用来源给的高画质版本

    /// 采集要再缩一截时运动帧用快缩法，精修要换成来源从原始采集用 Lanczos 重缩的那张：手机收到的精修帧是
    /// 来源给的画面，不是运动帧那张。少了这一步，精修就和运动帧一样软。
    func test_refine_uses_the_sources_high_quality_image() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, screen) = makeSession(client)
        defer { session.stop() }
        await session.start()
        let source = try XCTUnwrap(mac.latestSource)
        source.refinedSeed = 4242
        let shown = await waitUntil { !screen.frames.isEmpty }
        XCTAssertTrue(shown)
        let seed = source.emit()
        let moved = await waitUntil { screen.frames.contains { !$0.refine && self.matches($0, seed: seed) } }
        XCTAssertTrue(moved, "运动帧照常是采集的那张")
        let refined = await waitUntil(3) { screen.frames.contains(where: \.refine) }
        let bitrates = server.desktopStats?.snapshot().bitrateHistory ?? []
        let floor = RemoteRateController.config(width: 1856, height: 1206).minBitrate
        if let bitrate = bitrates.last, bitrate <= floor { return }  // 码率压到下限时按设计不精修，见上面的用例。
        XCTAssertTrue(refined, "画面静止后应有一帧精修（码率变化 \(bitrates)）")
        XCTAssertGreaterThan(source.refinedRequests, 0)
        let refine = try XCTUnwrap(screen.frames.last(where: \.refine))
        XCTAssertTrue(matches(refine, seed: 4242), "精修的是来源给的高画质那张")
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

    // MARK: - 画面往返读数

    /// 新手机开流时要了读数：画面在走时 Mac 每 2 s 报一次往返，手机拿来显示「延迟」。
    func test_latency_readings_reach_a_phone_that_asked_for_them() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, screen) = makeSession(client)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let source = try XCTUnwrap(mac.latestSource)
        let reported = await waitUntil(6) {
            _ = source.emit()
            try? await Task.sleep(for: .milliseconds(50))
            return session.latency != nil
        }
        XCTAssertTrue(reported, "画面在走 6 s 内应收到往返读数（已收 \(screen.frames.count) 帧）")
        let latency = try XCTUnwrap(session.latency)
        XCTAssertGreaterThan(latency.p50Millis, 0)
        XCTAssertGreaterThanOrEqual(latency.p95Millis, latency.p50Millis)
    }

    /// 开屏时间线把第一帧之前的各段补全：收到首个视频帧、首帧解码完（2026-11-08 MBP 等了 5.9 s 才见到 mini 的
    /// 第一帧，而 mini 170 ms 就发出了；中间缺日志，看不出卡在哪一段）。
    func test_open_timeline_records_first_frame_arrival_and_decode() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let (session, screen) = makeSession(client)
        defer { session.stop() }
        _ = mac
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let shown = await waitUntil(6) { !screen.frames.isEmpty }
        XCTAssertTrue(shown)
        let finished = await waitUntil(3) { RemoteConnectTraceLog.standard.load().first?.kind == .desktop }
        XCTAssertTrue(finished)
        let record = try XCTUnwrap(RemoteConnectTraceLog.standard.load().first)
        XCTAssertTrue(record.ok)
        XCTAssertTrue(record.events.contains { $0.contains("收到首个视频帧（关键帧") }, "\(record.events)")
        XCTAssertTrue(record.events.contains { $0.contains("首帧解码完（关键帧") }, "\(record.events)")
    }

    /// 老手机不认 `desktopLatency`（解析会当成坏消息断开），开流请求里没要就一条也不能发。
    func test_old_phone_never_gets_latency_readings() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        client.disconnect()
        let (link, inbox, channel) = try await rawPhone(server)
        defer { link.close() }
        let source = try XCTUnwrap(mac.latestSource)
        var acknowledged = 0
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            _ = source.emit()
            let frames = (try? inbox.of(.desktopFrame).map { try RemoteDesktopFrame(decoding: $0.payload) }) ?? []
            for frame in frames.dropFirst(acknowledged) {
                link.send(RemoteMessage(.desktopAck, channel: channel, payload: RemoteDesktopAck(
                    sequence: frame.sequence, captureNanos: frame.captureNanos, decodeMicros: 1000).encoded()))
            }
            acknowledged = frames.count
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(acknowledged, 10, "要有足够的帧走完 2 s 的记录周期")
        XCTAssertTrue(inbox.of(.desktopLatency).isEmpty, "没要读数的手机不能收到 desktopLatency")
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
                                                        staticKey: phone.publicKey.rawRepresentation,
                                                        // 只带密钥确认（Mac 硬要求），其余能力都不报：模拟最老的手机。
                                                        features: [RemoteFeature.keyConfirmation]),
                                     staticKey: phone, ephemeralKey: ephemeral)
        link.send(RemoteMessage(.keyConfirm))
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
                                    identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
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

/// 收进度上报（在链路队列上调）。
private final class PasteReports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PasteProgress] = []
    func add(_ item: PasteProgress) { lock.withLock { items.append(item) } }
    var all: [PasteProgress] { lock.withLock { items } }
}
