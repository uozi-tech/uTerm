import CryptoKit
import XCTest
@testable import uTerm

/// 直连上丢了帧之后，主流能不能恢复。
///
/// 回归 2026-11-08 MBP 看 mini（903）的 4K 屏「卡在刚连上的第一帧」：刚连上丢了一两帧，看的那端进入「等恢复帧」，
/// 普通帧全跳过；Mac 补的恢复帧（LTR 刷新 / 关键帧）在 4K 下很大，编码器预算被链路节奏压在几 Mbps、又按 60 fps
/// 分到每帧，VideoToolbox 把恢复帧整帧丢掉、再要、再丢。屏幕上只剩隔一阵来一张的旁路精修在动。
@MainActor
final class RemoteDesktopRecoveryTests: XCTestCase {
    private final class Shown: @unchecked Sendable {
        private let lock = NSLock()
        private var main: [UInt64] = []
        private var sidecar = 0
        func add(_ frame: RemoteDesktopFrame) {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock(); defer { lock.unlock() }
            if frame.flags.contains(.sidecar) { sidecar += 1 } else { main.append(now) }
        }
        var mainFrames: [UInt64] { lock.lock(); defer { lock.unlock() }; return main }
        var sidecarFrames: Int { lock.lock(); defer { lock.unlock() }; return sidecar }
    }

    private struct Rig {
        let server: RemoteHostServer
        let client: RemoteMacClient
        let mac: FakeDesktopMac
        let macPath: RemoteMemoryDatagramPath
    }

    private func makeRig(link: RemoteLinkImpairment) throws -> Rig {
        let mac = FakeDesktopMac()
        mac.detail = true
        mac.audioEnabled = false
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
        let (macPath, phonePath) = RemoteMemoryDatagramPath.pair(impairment: link)
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        let keys = makeDatagramKeys()
        server.accept(transport: RemoteP2PTransport(path: macPath, keys: keys.first),
                      origin: .internet(peerID: phoneID, keys: RemoteHandshakeKeys(send: b, receive: a), path: .direct))
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: phoneIdentity)
        client.updateRoutes(endpoint: nil, internetDialer: { _ in
            RemoteDialedPath(transport: RemoteP2PTransport(path: phonePath, keys: keys.second),
                             handshakeKeys: RemoteHandshakeKeys(send: a, receive: b), path: .direct)
        })
        return Rig(server: server, client: client, mac: mac, macPath: macPath)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// 节奏被压低（2 Mbps 上下）、大画面、画面每秒变 6 次：开头丢掉几帧之后，主流 2 s 内要恢复，之后帧率要跟得上采集。
    ///
    /// 链路本身是宽的（mini 那次是局域网直连）：开头整段丢包把节奏估计压到 2 Mbps 左右，之后只有积压时才往上涨，
    /// 编码器预算跟着被压住。真窄的链路（2 Mbps 物理带宽）另有节奏探测超量丢包的问题，属码控调优，不在这里。
    func test_main_stream_recovers_quickly_after_early_loss_with_pressed_pacing() async throws {
        let link = RemoteLinkImpairment(delay: 0.03, bytesPerSecond: 25_000_000)
        let rig = try makeRig(link: link)
        defer { rig.client.disconnect(); rig.server.stop() }
        await rig.client.connect()
        XCTAssertEqual(rig.client.path, .direct)

        let shown = Shown()
        let session = RemoteDesktopSession(client: rig.client, maxWidth: 3024, maxHeight: 1964, codec: .hevc)
        session.receiver.setHandlers(onImage: { _, frame in shown.add(frame) }, onCursor: { _ in })
        await session.start()
        defer { session.stop(); rig.mac.latestSource?.pause() }
        XCTAssertEqual(session.state, .streaming)
        let source = try XCTUnwrap(rig.mac.latestSource)

        // 刚连上就丢一阵：第一张关键帧收不齐，手机一个长期参考帧都没确认过，进入「等恢复帧」；
        // 整段丢包同时把节奏估计压到 2 Mbps 上下（之后只有积压时才往上涨）。
        // 全丢 1.6 s：比一帧最多等的 1.5 s 长，在路上的帧只能放弃；又短于判断断线的 2.5 s。
        var lossy = link
        lossy.lossRate = 1
        rig.macPath.setImpairment(lossy)
        // 一个小窗口（屏幕的 1/25）在不停变：背景是满屏细节（恢复帧 / 关键帧大），每帧只变那一块（普通帧小）。
        // 满屏都在变的细节画面一帧就 400 多 KB，跑不了 6 fps，测不出恢复。
        // Debug 下逐像素生成 3024×1964 要好几百毫秒一张：放到主线程以外，跟丢包那段并行。
        let prepared = Task.detached {
            source.prepareCycle(count: 12, window: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        }
        try await Task.sleep(for: .seconds(1.6))
        rig.macPath.setImpairment(link)
        let healed = DispatchTime.now().uptimeNanoseconds
        await prepared.value
        source.run(fps: 6)

        try await Task.sleep(for: .seconds(10))
        let main = shown.mainFrames.filter { $0 > healed }
        let recovery = main.first.map { Double($0 - healed) / 1e9 }
        let later = main.filter { $0 > healed + 2_000_000_000 && $0 <= healed + 10_000_000_000 }
        let fps = Double(later.count) / 8
        let stats = try XCTUnwrap(rig.server.desktopStats?.snapshot())
        print(String(format: "[恢复] 网络恢复后主流第一帧 %@，之后 8 s 主流 %.1f fps，旁路精修 %d 张，编码器丢 %d，关键帧 %d，放弃 %d，"
                     + "编码器码率 %.1f Mbps",
                     recovery.map { String(format: "%.2f s", $0) } ?? "没有", fps, shown.sidecarFrames,
                     stats.encoderDrops, stats.keyframes, stats.lostFrames, Double(stats.bitrate) / 1e6))
        XCTAssertEqual(rig.client.state, .connected)
        XCTAssertLessThan(recovery ?? 99, 2, "网络好了 2 s 内主流要恢复")
        XCTAssertGreaterThan(fps, 3, "源每秒变 6 次，恢复后主流要跟得上大半")
    }

    /// 宽链路（883 时的条件：直连空着、画面很大）不退化：画面一直在大幅变化，几秒内爬到满帧率。
    func test_busy_screen_on_a_wide_idle_link_reaches_full_frame_rate() async throws {
        let rig = try makeRig(link: RemoteLinkImpairment(delay: 0.04, bytesPerSecond: 25_000_000))
        defer { rig.client.disconnect(); rig.server.stop() }
        await rig.client.connect()
        let shown = Shown()
        let session = RemoteDesktopSession(client: rig.client, maxWidth: 3024, maxHeight: 1964, codec: .hevc)
        session.receiver.setHandlers(onImage: { _, frame in shown.add(frame) }, onCursor: { _ in })
        await session.start()
        defer { session.stop(); rig.mac.latestSource?.pause() }
        let source = try XCTUnwrap(rig.mac.latestSource)
        await Task.detached { source.prepareCycle(count: 12) }.value
        source.run(fps: 57)

        try await Task.sleep(for: .seconds(6))
        let start = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(for: .seconds(6))
        let fps = Double(shown.mainFrames.filter { $0 > start }.count) / 6
        print(String(format: "[宽链路] 主流 %.1f fps", fps))
        XCTAssertEqual(rig.client.state, .connected)
        XCTAssertGreaterThan(fps, 45, "链路空着，满屏在变也要接近 57 fps")
    }
}
