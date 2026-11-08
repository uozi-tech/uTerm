import CoreVideo
import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 弱网矩阵：同一套远程桌面 + 声音，在几档模拟的差网络上各跑一遍，出一张可对比的读数表。只出数据、不设门槛
/// （只断言「跑得起来」），修什么看表再定。
///
/// 真实的 `RemoteHostServer` / `RemoteMacClient` / 编码器 / 解码器 / 码控 / 抖动缓冲，只有网络是模拟的：
/// - 直连（UDP）：`RemoteMemoryDatagramPath` + `RemoteP2PTransport`，和公网打洞成功后同一条代码路径；
/// - 中继（TCP）：`RemoteFaultProxy` 把手机到 Mac 的 TCP 整段当成一跳（中继本身只转发，不改变排队与重传）。
/// 建连计时那一组另外经真实的 `uterm-relay`（本机起），手机到中继这一段加差网络。
///
/// 默认跳过（不进 test-fast）。跑法：`make test-weak-network`（= `scripts/test-weak-network.sh`），
/// 结果写进 `docs/remote-weak-network-baseline.md`。
@MainActor
final class RemoteWeakNetworkMatrixTests: XCTestCase {

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["UTERM_WEAK_NET_MATRIX"] == "1" else {
            throw XCTSkip("弱网矩阵默认不跑：make test-weak-network")
        }
    }

    // MARK: - 档位

    nonisolated struct Phase: Sendable {
        let at: TimeInterval
        let link: RemoteLinkImpairment
    }

    nonisolated struct Profile: Sendable {
        let id: String
        let name: String
        let summary: String
        let link: RemoteLinkImpairment
        var phases: [Phase] = []
        var seconds: TimeInterval = 15

        /// 单程平均时延（毫秒）：估声音端到端延迟用。
        var meanOneWayMillis: Double { (link.delay + link.jitter / 2) * 1000 }
    }

    /// `rttMillis` 是往返的固定部分；`jitterMillis` 是单程附加的随机延迟上限（每个包独立取值）。
    private static func link(rttMillis: Double, jitterMillis: Double = 0, loss: Double = 0,
                             mbps: Double?) -> RemoteLinkImpairment {
        RemoteLinkImpairment(delay: rttMillis / 2000, jitter: jitterMillis / 1000, lossRate: loss,
                             bytesPerSecond: mbps.map { Int($0 * 1_000_000 / 8) })
    }

    static let baseline = Profile(id: "baseline", name: "基线", summary: "20 Mbps · RTT 50 ms · 不丢包",
                                  link: link(rttMillis: 50, jitterMillis: 2, mbps: 20))
    static let threeG = Profile(id: "3g", name: "3G", summary: "750 kbps · RTT 200 ms · 丢 1%",
                                link: link(rttMillis: 200, jitterMillis: 10, loss: 0.01, mbps: 0.75))
    static let loss5 = Profile(id: "loss5", name: "高丢包 5%", summary: "10 Mbps · RTT 100 ms · 丢 5%",
                               link: link(rttMillis: 100, jitterMillis: 5, loss: 0.05, mbps: 10))
    static let loss10 = Profile(id: "loss10", name: "高丢包 10%", summary: "10 Mbps · RTT 100 ms · 丢 10%",
                                link: link(rttMillis: 100, jitterMillis: 5, loss: 0.10, mbps: 10))
    /// 单程 75–225 ms 均匀分布：往返 300 ± 150 ms。
    static let jitter = Profile(id: "jitter", name: "高延迟抖动", summary: "10 Mbps · RTT 300 ± 150 ms",
                                link: link(rttMillis: 150, jitterMillis: 150, mbps: 10))
    static let dropAt: TimeInterval = 8
    static let restoreAt: TimeInterval = 18
    static let bandwidthDrop = Profile(id: "drop", name: "带宽骤降", summary: "20 → 1 → 20 Mbps（8 s / 18 s）· RTT 60 ms",
                                       link: link(rttMillis: 60, jitterMillis: 2, mbps: 20),
                                       phases: [Phase(at: dropAt, link: link(rttMillis: 60, jitterMillis: 2, mbps: 1)),
                                                Phase(at: restoreAt, link: link(rttMillis: 60, jitterMillis: 2, mbps: 20))],
                                       seconds: 30)

    static let steadyProfiles = [baseline, threeG, loss5, loss10, jitter]

    // MARK: - 用例

    func test_matrix_1_baseline() async throws { try await runBoth(Self.baseline) }
    func test_matrix_2_3g() async throws { try await runBoth(Self.threeG) }
    func test_matrix_3_loss5() async throws { try await runBoth(Self.loss5) }
    func test_matrix_4_loss10() async throws { try await runBoth(Self.loss10) }
    func test_matrix_5_jitter() async throws { try await runBoth(Self.jitter) }
    func test_matrix_6_bandwidth_drop() async throws { try await runBoth(Self.bandwidthDrop) }

    /// 直连中途断掉（包全丢，手机不知道网络变了：NAT 映射过期、中间设备掐流）→ 靠心跳发现 → 回落中继。
    func test_matrix_7_direct_breaks_silently() async throws {
        for _ in 0..<Self.rounds { try await runPathSwitch(notifies: false) }
    }

    /// Wi-Fi 换蜂窝：直连断掉的同时系统报网络变了（`networkChanged`）→ 探一下 → 回落中继。
    func test_matrix_8_network_change() async throws {
        for _ in 0..<Self.rounds { try await runPathSwitch(notifies: true) }
    }

    /// 每格跑几轮（`UTERM_WEAK_NET_ROUNDS`，默认 3）：单轮之间差得很多，表里给中位数和范围。
    nonisolated static var rounds: Int {
        max(1, Int(ProcessInfo.processInfo.environment["UTERM_WEAK_NET_ROUNDS"] ?? "") ?? 3)
    }

    /// 只跑一条路（`UTERM_WEAK_NET_TRANSPORT` = direct / relay），调参时省一半时间。
    nonisolated static var transports: [Transport] {
        switch ProcessInfo.processInfo.environment["UTERM_WEAK_NET_TRANSPORT"] {
        case "direct": return [.direct]
        case "relay": return [.relay]
        default: return Transport.allCases
        }
    }

    /// 画面怎么变（`UTERM_WEAK_NET_CONTENT`，逗号分隔：full / typing / scroll / area；默认全跑）。
    nonisolated static var contents: [SyntheticContent] {
        let raw = ProcessInfo.processInfo.environment["UTERM_WEAK_NET_CONTENT"] ?? ""
        let picked = raw.split(separator: ",").compactMap { SyntheticContent(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        return picked.isEmpty ? SyntheticContent.allCases : picked
    }

    private func runBoth(_ profile: Profile) async throws {
        for _ in 0..<Self.rounds { for content in Self.contents { for transport in Self.transports {
            let row = try await measure(profile, transport: transport, content: content)
            Self.report.add(row)
            print("[弱网矩阵] \(row.consoleLine)")
        } } }
    }

    // MARK: - 夹具

    nonisolated enum Transport: String, CaseIterable, Sendable {
        case direct = "直连 UDP"
        case relay = "中继 TCP"
    }

    /// 手机上显示出来的一帧新画面：显示时刻与它在 Mac 上被采集的时刻（同一进程、同一个钟）。
    nonisolated struct ShownFrame: Sendable {
        let at: UInt64
        let capture: UInt64
    }

    /// 只记新画面：精修帧、旁路帧是同一张画面的重编（采集时刻相同），不算。
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var shown: [ShownFrame] = []
        private var lastCapture: UInt64 = 0
        func add(_ frame: RemoteDesktopFrame) {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock(); defer { lock.unlock() }
            guard frame.captureNanos > lastCapture else { return }
            lastCapture = frame.captureNanos
            shown.append(ShownFrame(at: now, capture: frame.captureNanos))
        }
        var all: [UInt64] { lock.lock(); defer { lock.unlock() }; return shown.map(\.at) }
        var frames: [ShownFrame] { lock.lock(); defer { lock.unlock() }; return shown }
    }

    /// 按墙钟拉声音（和真实的播放回调一样匀速），断线重开后换成新的取样回调。
    private final class AudioPuller: @unchecked Sendable {
        private let lock = NSLock()
        private var pull: (@Sendable (Int) -> [Float])?
        func set(_ value: (@Sendable (Int) -> [Float])?) { lock.lock(); pull = value; lock.unlock() }
        private func current() -> (@Sendable (Int) -> [Float])? { lock.lock(); defer { lock.unlock() }; return pull }
        func start() -> Task<Void, Never> {
            Task.detached { [self] in
                let started = DispatchTime.now().uptimeNanoseconds
                var pulled = 0
                while !Task.isCancelled {
                    let owed = Int(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 * 48_000)
                    let current = current()
                    while pulled + 480 <= owed {
                        _ = current?(480)
                        pulled += 480
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }
    }

    private struct Rig {
        let server: RemoteHostServer
        let client: RemoteMacClient
        let mac: FakeDesktopMac
        let setLink: (RemoteLinkImpairment) -> Void
        let teardown: () -> Void
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private struct Trusted {
        let server: RemoteHostServer
        let phoneIdentity: RemoteIdentityStore
        let phoneID: UUID
    }

    private func makeServer(desktop: RemoteDesktopEnvironment) throws -> Trusted {
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let phoneID = RemoteLocalDevice.id()
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      desktopEnvironment: desktop)
        server.internetAccessPolicy = { $0 == phoneID }
        try server.trust(RemotePeer(id: phoneID, name: "测试 iPhone",
                                    publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        return Trusted(server: server, phoneIdentity: phoneIdentity, phoneID: phoneID)
    }

    private nonisolated static func handshakeKeys() -> (mac: RemoteHandshakeKeys, phone: RemoteHandshakeKeys) {
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        return (RemoteHandshakeKeys(send: b, receive: a), RemoteHandshakeKeys(send: a, receive: b))
    }

    /// 直连：Mac 那头已经接上的数据报通道，手机拨号就拿另一头。
    /// 直连的一对数据报路径。每次拨号新建一对、Mac 那头接上：断线重连时和真实的重新打洞一样拿到一条新路，
    /// 不会去复用已经关掉的那条（复用的话「恢复」永远量不出来）。
    private final class DirectPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var link: RemoteLinkImpairment
        private var current: (mac: RemoteMemoryDatagramPath, phone: RemoteMemoryDatagramPath)?
        init(link: RemoteLinkImpairment) { self.link = link }
        func make() -> (mac: RemoteMemoryDatagramPath, phone: RemoteMemoryDatagramPath) {
            lock.lock(); defer { lock.unlock() }
            let pair = RemoteMemoryDatagramPath.pair(impairment: link)
            current = pair
            return pair
        }
        func setLink(_ value: RemoteLinkImpairment) {
            lock.lock(); defer { lock.unlock() }
            link = value
            current?.mac.setImpairment(value)
            current?.phone.setImpairment(value)
        }
    }

    private func makeDirectRig(link: RemoteLinkImpairment) throws -> Rig {
        let mac = FakeDesktopMac()
        mac.detail = true
        let trusted = try makeServer(desktop: mac.environment())
        let paths = DirectPaths(link: link)
        let server = trusted.server
        let phoneID = trusted.phoneID
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: trusted.phoneIdentity)
        client.updateRoutes(endpoint: nil, internetDialer: { [weak server] _ in
            let (macPath, phonePath) = paths.make()
            let keys = Self.handshakeKeys()
            let datagramKeys = makeDatagramKeys()
            await MainActor.run {
                server?.accept(transport: RemoteP2PTransport(path: macPath, keys: datagramKeys.first),
                               origin: .internet(peerID: phoneID, keys: keys.mac, path: .direct))
            }
            return RemoteDialedPath(transport: RemoteP2PTransport(path: phonePath, keys: datagramKeys.second),
                                    handshakeKeys: keys.phone, path: .direct)
        })
        return Rig(server: trusted.server, client: client, mac: mac,
                   setLink: { paths.setLink($0) },
                   teardown: { client.disconnect(); trusted.server.stop() })
    }

    /// TCP 监听 → `RemoteHostServer.accept(origin: .internet(path: .relay))`；手机经故障代理连过来。
    private struct TCPEntry {
        let listener: NWListener
        let port: UInt16
    }

    private func makeTCPEntry(server: RemoteHostServer, phoneID: UUID, keys: RemoteHandshakeKeys) async throws -> TCPEntry {
        let listener = try NWListener(using: RemoteLink.parameters(), on: .any)
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.newConnectionHandler = { [weak server] connection in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    server?.accept(transport: RemoteNWTransport(connection: connection),
                                   origin: .internet(peerID: phoneID, keys: keys, path: .relay))
                }
            }
        }
        listener.start(queue: DispatchQueue(label: "test.weak-net.listener"))
        var ports = ready.stream.makeAsyncIterator()
        let readyPort = await ports.next()
        let port = try XCTUnwrap(readyPort)
        return TCPEntry(listener: listener, port: port)
    }

    private func makeProxy(to port: UInt16, link: RemoteLinkImpairment) async throws -> (RemoteFaultProxy, UInt16) {
        let proxy = try RemoteFaultProxy(targetPort: port, impairment: link)
        let ready = await waitUntil { proxy.port != nil }
        XCTAssertTrue(ready)
        return (proxy, try XCTUnwrap(proxy.port))
    }

    private nonisolated static func tcpDial(port: UInt16, keys: RemoteHandshakeKeys) -> RemoteDialedPath {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: RemoteLink.parameters())
        return RemoteDialedPath(transport: RemoteNWTransport(connection: connection), handshakeKeys: keys, path: .relay)
    }

    private func makeRelayRig(link: RemoteLinkImpairment) async throws -> Rig {
        let mac = FakeDesktopMac()
        mac.detail = true
        let trusted = try makeServer(desktop: mac.environment())
        let keys = Self.handshakeKeys()
        let entry = try await makeTCPEntry(server: trusted.server, phoneID: trusted.phoneID, keys: keys.mac)
        let (proxy, proxyPort) = try await makeProxy(to: entry.port, link: link)
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: trusted.phoneIdentity)
        client.updateRoutes(endpoint: nil, internetDialer: { _ in Self.tcpDial(port: proxyPort, keys: keys.phone) })
        return Rig(server: trusted.server, client: client, mac: mac,
                   setLink: { proxy.setImpairment($0) },
                   teardown: { client.disconnect(); trusted.server.stop(); proxy.stop(); entry.listener.cancel() })
    }

    // MARK: - 一轮测量

    nonisolated struct Sample: Sendable {
        let t: Double
        let target: Int
        let bytes: Int
    }

    @MainActor private final class Sampler {
        private(set) var samples: [Sample] = []
        private(set) var bufferedMillis: [Int] = []
        func record(t: Double, stats: RemoteDesktopStreamerStats.Snapshot?, audio: RemoteAudioReceiver.Snapshot) {
            if let stats { samples.append(Sample(t: t, target: stats.bitrate, bytes: stats.bytes)) }
            if audio.counters.played > 0 { bufferedMillis.append(audio.bufferedMillis) }
        }
    }

    @MainActor private struct Streaming {
        let session: RemoteDesktopSession
        let frames: Frames
        let output: SilentAudioOutput
        let puller: AudioPuller
        let pullTask: Task<Void, Never>
        let connectMillis: Double
        let firstFrameMillis: Double?
        let audioStartMillis: Double?

        func stop() {
            pullTask.cancel()
            session.stop()
        }
    }

    /// 建连 → 开桌面 → 等首帧 → 开声音。
    private func startStreaming(_ rig: Rig) async throws -> Streaming {
        let connectStart = Date()
        await rig.client.connect()
        let connectMillis = Date().timeIntervalSince(connectStart) * 1000
        XCTAssertEqual(rig.client.state, .connected)

        let output = SilentAudioOutput()
        let session = RemoteDesktopSession(client: rig.client, maxWidth: 1206, maxHeight: 2622, codec: .hevc,
                                           audioOutput: output)
        let frames = Frames()
        session.receiver.setHandlers(onImage: { _, frame in frames.add(frame) }, onCursor: { _ in })
        let desktopStart = DispatchTime.now().uptimeNanoseconds
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let gotFirst = await waitUntil(20) { !frames.all.isEmpty }
        let firstFrameMillis = gotFirst ? frames.all.first.map { Double($0 - desktopStart) / 1e6 } : nil

        let puller = AudioPuller()
        let audioStart = Date()
        session.setAudio(true)
        let playing = await waitUntil(10) { session.audioState == .playing }
        puller.set(output.pull)
        let pullTask = puller.start()
        return Streaming(session: session, frames: frames, output: output, puller: puller, pullTask: pullTask,
                         connectMillis: connectMillis, firstFrameMillis: firstFrameMillis,
                         audioStartMillis: playing ? Date().timeIntervalSince(audioStart) * 1000 : nil)
    }

    /// Mac 每开一次流就建一个新的采集源：发现新的就让它按 `content` 出画面。
    @MainActor private final class SourceDriver {
        let content: SyntheticContent
        private var running: [ObjectIdentifier] = []
        init(content: SyntheticContent) { self.content = content }
        func drive(_ mac: FakeDesktopMac) {
            for source in mac.sources where !running.contains(ObjectIdentifier(source)) {
                running.append(ObjectIdentifier(source))
                source.play(content)
            }
        }
        /// 所有采集源一共出过几帧（重连会换新的源）。
        func produced(_ mac: FakeDesktopMac) -> Int { mac.sources.reduce(0) { $0 + $1.produced } }
        func stop(_ mac: FakeDesktopMac) {
            for source in mac.sources { source.pause() }
        }
    }

    private func measure(_ profile: Profile, transport: Transport, content: SyntheticContent) async throws -> Row {
        let rig: Rig
        if transport == .direct {
            rig = try makeDirectRig(link: profile.link)
        } else {
            rig = try await makeRelayRig(link: profile.link)
        }
        defer { rig.teardown() }
        let streaming = try await startStreaming(rig)
        defer { streaming.stop() }
        let driver = SourceDriver(content: content)
        driver.drive(rig.mac)
        defer { driver.stop(rig.mac) }

        let sampler = Sampler()
        let start = DispatchTime.now().uptimeNanoseconds
        let producedBefore = driver.produced(rig.mac)
        let audioBefore = streaming.session.audioReceiver.snapshot()
        var pending = profile.phases
        while true {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if elapsed >= profile.seconds { break }
            while let next = pending.first, elapsed >= next.at {
                rig.setLink(next.link)
                pending.removeFirst()
            }
            driver.drive(rig.mac)
            streaming.puller.set(streaming.output.pull)
            sampler.record(t: elapsed, stats: rig.server.desktopStats?.snapshot(),
                           audio: streaming.session.audioReceiver.snapshot())
            try await Task.sleep(for: .milliseconds(250))
        }
        let end = DispatchTime.now().uptimeNanoseconds
        let produced = driver.produced(rig.mac) - producedBefore
        let audioAfter = streaming.session.audioReceiver.snapshot()
        let stats = rig.server.desktopStats?.snapshot()
        XCTAssertEqual(rig.client.state, .connected,
                       "\(profile.name) · \(content.name) · \(transport.rawValue) 跑完应该还连着")

        var row = Row(profile: profile, transport: transport, content: content)
        row.connectMillis = streaming.connectMillis
        row.firstFrameMillis = streaming.firstFrameMillis
        row.audioStartMillis = streaming.audioStartMillis
        row.video = VideoReadout(frames: streaming.frames.frames, start: start, end: end, samples: sampler.samples,
                                 stats: stats, produced: produced)
        row.audio = AudioReadout(before: audioBefore, after: audioAfter, buffered: sampler.bufferedMillis,
                                 oneWayMillis: profile.meanOneWayMillis)
        if !profile.phases.isEmpty {
            row.recovery = Self.dropRecovery(samples: sampler.samples, frames: streaming.frames.all, start: start)
        }
        return row
    }

    // MARK: - 路径切换

    private func runPathSwitch(notifies: Bool) async throws {
        let profile = Self.baseline
        let mac = FakeDesktopMac()
        mac.detail = true
        let trusted = try makeServer(desktop: mac.environment())
        let directKeys = Self.handshakeKeys()
        let (macPath, phonePath) = RemoteMemoryDatagramPath.pair(impairment: profile.link)
        let datagramKeys = makeDatagramKeys()
        trusted.server.accept(transport: RemoteP2PTransport(path: macPath, keys: datagramKeys.first),
                              origin: .internet(peerID: trusted.phoneID, keys: directKeys.mac, path: .direct))
        // 回落用的中继路径：同样的基线网络，走 TCP。
        let relayKeys = Self.handshakeKeys()
        let entry = try await makeTCPEntry(server: trusted.server, phoneID: trusted.phoneID, keys: relayKeys.mac)
        let (proxy, proxyPort) = try await makeProxy(to: entry.port, link: profile.link)
        let dials = DialCounter()
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: trusted.phoneIdentity)
        client.updateRoutes(endpoint: nil, internetDialer: { _ in
            if dials.next() == 0 {
                return RemoteDialedPath(transport: RemoteP2PTransport(path: phonePath, keys: datagramKeys.second),
                                        handshakeKeys: directKeys.phone, path: .direct)
            }
            return Self.tcpDial(port: proxyPort, keys: relayKeys.phone)
        })
        let rig = Rig(server: trusted.server, client: client, mac: mac, setLink: { _ in },
                      teardown: { client.disconnect(); trusted.server.stop(); proxy.stop(); entry.listener.cancel() })
        defer { rig.teardown() }

        let streaming = try await startStreaming(rig)
        defer { streaming.stop() }
        XCTAssertEqual(client.path, .direct)
        let driver = SourceDriver(content: .fullScreen)
        driver.drive(mac)
        defer { driver.stop(mac) }
        try await Task.sleep(for: .seconds(6))

        // 断：两个方向的包全丢。
        let breakAt = DispatchTime.now().uptimeNanoseconds
        var dead = profile.link
        dead.lossRate = 1
        macPath.setImpairment(dead)
        phonePath.setImpairment(dead)
        // 系统报网络变了总在接口换完之后：晚 1 s 再通知，这时已经收不到旧路径上还在路上的包
        // （立刻通知的话，那些包会被当成「探测有回音」）。
        var notified = !notifies

        var detected: Double?
        var reconnected: Double?
        var firstFrame: Double?
        var audioAtResume: RemoteAudioReceiver.Snapshot?
        let limit: Double = 60
        var settledAt: Double?
        while true {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - breakAt) / 1e9
            if elapsed > limit { break }
            if !notified, elapsed >= 1 {
                client.networkChanged(isSatisfied: true)
                notified = true
            }
            if detected == nil, client.state != .connected { detected = elapsed * 1000 }
            if detected != nil, reconnected == nil, client.state == .connected, client.path == .relay {
                reconnected = elapsed * 1000
            }
            if firstFrame == nil, let frame = streaming.frames.all.first(where: { $0 > breakAt + 300_000_000 }),
               reconnected != nil {
                firstFrame = Double(frame - breakAt) / 1e6
                settledAt = elapsed
                audioAtResume = streaming.session.audioReceiver.snapshot()
            }
            driver.drive(mac)
            streaming.puller.set(streaming.output.pull)
            if let settledAt, elapsed - settledAt >= 10 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let end = DispatchTime.now().uptimeNanoseconds
        let audioAfter = streaming.session.audioReceiver.snapshot()
        XCTAssertNotNil(firstFrame, "60 s 内应该回落到中继并恢复画面")

        var row = SwitchRow(name: notifies ? "网络切换（系统通知）" : "直连静默中断",
                            summary: notifies ? "直连包全丢，1 s 后系统报网络变了 → 中继 TCP" : "直连包全丢、无通知 → 中继 TCP")
        row.detectMillis = detected
        row.reconnectMillis = reconnected
        row.firstFrameMillis = firstFrame
        if let firstFrame {
            let resumed = breakAt + UInt64(firstFrame * 1e6)
            row.afterRecovery = VideoReadout(frames: streaming.frames.frames, start: resumed, end: end,
                                             samples: [], stats: rig.server.desktopStats?.snapshot())
        }
        // 重连后声音是新的一路流，计数从头算：只比恢复之后的这一段。
        if let audioAtResume, audioAtResume.stream == audioAfter.stream {
            row.audio = AudioReadout(before: audioAtResume, after: audioAfter, buffered: [],
                                     oneWayMillis: profile.meanOneWayMillis)
        }
        Self.report.add(row)
        print("[弱网矩阵] \(row.consoleLine)")
    }

    private final class DialCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { count += 1; lock.unlock() }; return count }
    }

    // MARK: - 建连（经真实中继）

    private func relayConfig() throws -> RemoteRelayConfig {
        guard let json = ProcessInfo.processInfo.environment["UTERM_RELAY_CONFIG"], !json.isEmpty else {
            throw XCTSkip("没有本机中继：用 make test-weak-network 跑")
        }
        return try XCTUnwrap(RemoteRelayConfig(importing: Data(json.utf8)))
    }

    nonisolated enum DialVariant: String, CaseIterable, Sendable {
        case punched = "打洞成功 → 直连"
        case macNoDirect = "Mac 不给直连 → 中继"
        case relayOnly = "不打洞，直接中继"
    }

    /// 手机到中继这一段加差网络（TCP 与 STUN 同一端口号），Mac 到中继不加。打洞本身在本机回环上，不受差网络影响，
    /// 所以「打洞成功」一行只反映经中继交换地址的开销。
    func test_matrix_9_connect_through_relay() async throws {
        let config = try relayConfig()
        for profile in [Self.baseline, Self.threeG, Self.loss10, Self.jitter] {
            let tcp = try RemoteFaultProxy(targetPort: UInt16(config.port), impairment: profile.link)
            let ready = await waitUntil { tcp.port != nil }
            XCTAssertTrue(ready)
            let port = try XCTUnwrap(tcp.port)
            let udp = try RemoteUDPFaultProxy(targetPort: UInt16(config.port), impairment: profile.link, listenPort: port)
            defer { tcp.stop(); udp.stop() }
            var phoneConfig = config
            phoneConfig.host = "127.0.0.1"
            phoneConfig.port = Int(port)

            let mac = try await makeRelayMac(config: config)
            defer { mac.server.stop() }
            for variant in DialVariant.allCases {
                mac.server.relayLink?.acceptsDirect = variant != .macNoDirect
                var millis: [Double] = []
                var paths: [String] = []
                for _ in 0..<3 {
                    let relay = RemoteRelayClient(config: phoneConfig)
                    var dialer = RemotePathDialer(relay: relay, identity: mac.phoneIdentity, localID: mac.phoneID,
                                                  allowsDirect: variant != .relayOnly)
                    let peer = mac.peer
                    let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                                 identity: mac.phoneIdentity, expectedPeer: peer)
                    client.updateRoutes(endpoint: nil, internetDialer: { [dialer] context in
                        try await dialer.dial(peer, invitationToken: context.pairingToken, trace: context.trace)
                    })
                    let started = Date()
                    await client.connect()
                    millis.append(Date().timeIntervalSince(started) * 1000)
                    paths.append(client.state == .connected ? (client.path?.label ?? "?") : "失败")
                    client.disconnect()
                    await relay.stop()
                    try await Task.sleep(for: .milliseconds(300))
                }
                let row = ConnectRow(profile: profile, variant: variant, millis: millis, paths: paths)
                Self.report.add(row)
                print("[弱网矩阵] \(row.consoleLine)")
            }
        }
    }

    private struct RelayMac {
        let server: RemoteHostServer
        let peer: RemotePeer
        let phoneIdentity: RemoteIdentityStore
        let phoneID: UUID
    }

    private func makeRelayMac(config: RemoteRelayConfig) async throws -> RelayMac {
        let identity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let suite = "RemoteWeakNetworkMatrixTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let phoneID = RemoteLocalDevice.id()
        let server = RemoteHostServer(registry: TerminalSessionRegistry(), identity: identity, localName: "测试 Mac",
                                      localID: UUID(), advertises: false,
                                      relayRevocations: RemoteRelayRevocations(defaults: defaults))
        server.internetAccessPolicy = { $0 == phoneID }
        server.relayConfig = config
        server.updateInternetAccess(enabled: true, keepAwake: false)
        let registered = await waitUntil { server.relayLink?.state == .registered }
        XCTAssertTrue(registered, "没注册上中继：\(String(describing: server.relayLink?.state))")
        try server.trust(RemotePeer(id: phoneID, name: "测试 iPhone",
                                    publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        let peer = RemotePeer(id: server.localID, name: "测试 Mac",
                              publicKey: try identity.localIdentity().publicKey.rawRepresentation, pairedAt: Date())
        return RelayMac(server: server, peer: peer, phoneIdentity: phoneIdentity, phoneID: phoneID)
    }

    // MARK: - 读数

    nonisolated struct VideoReadout: Sendable {
        var shown = 0
        var fps = 0.0
        var stalls = 0
        var stallSeconds = 0.0
        var longestGap = 0.0
        var sentMbps = 0.0
        var targetStart = 0.0
        var targetMin = 0.0
        var targetEnd = 0.0
        var roundTripP50 = 0.0
        var roundTripP95 = 0.0
        var keyframes = 0
        var lostFrames = 0
        var congestionDrops = 0
        /// 画面从 Mac 上采集到在手机上显示（毫秒）：p50 / p95 / 最大。只算新画面。
        var latencyP50 = 0.0
        var latencyP95 = 0.0
        var latencyMax = 0.0
        /// 源在窗口里出了多少帧新画面、手机显示了其中多少（nil = 不知道源出了几帧）。
        var delivered: Double?
        /// 每 2 秒一格：目标 / 实发（Mbps）。
        var curve: [(target: Double, sent: Double)] = []

        init(frames shownFrames: [ShownFrame], start: UInt64, end: UInt64, samples: [Sample],
             stats: RemoteDesktopStreamerStats.Snapshot?, produced: Int? = nil) {
            let shownWindow = shownFrames.filter { $0.at > start && $0.at <= end }
            let window = shownWindow.map(\.at)
            let latencies = shownWindow.map { Double($0.at &- $0.capture) / 1e6 }.sorted()
            if !latencies.isEmpty {
                latencyP50 = latencies[latencies.count / 2]
                latencyP95 = latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
                latencyMax = latencies.last ?? 0
            }
            if let produced, produced > 0 { delivered = min(1, Double(window.count) / Double(produced)) }
            let seconds = Double(end - start) / 1e9
            shown = window.count
            fps = Double(window.count) / max(seconds, 0.001)
            let points = [start] + window + [end]
            let gaps = zip(points.dropFirst(), points).map { Double($0.0 - $0.1) / 1e9 }
            let stallGaps = gaps.filter { $0 > 0.2 }
            stalls = stallGaps.count
            stallSeconds = stallGaps.reduce(0, +)
            longestGap = gaps.max() ?? 0
            if let first = samples.first, let last = samples.last, last.t > first.t {
                sentMbps = Double(last.bytes - first.bytes) * 8 / (last.t - first.t) / 1e6
                targetStart = Double(first.target) / 1e6
                targetEnd = Double(last.target) / 1e6
                targetMin = Double(samples.map(\.target).min() ?? 0) / 1e6
                var bucket = 2.0
                var previous = first
                var bucketTargets: [Int] = []
                for sample in samples {
                    bucketTargets.append(sample.target)
                    if sample.t >= bucket, sample.t > previous.t {
                        let target = Double(bucketTargets.reduce(0, +)) / Double(bucketTargets.count) / 1e6
                        let sent = Double(sample.bytes - previous.bytes) * 8 / (sample.t - previous.t) / 1e6
                        curve.append((target, sent))
                        previous = sample
                        bucketTargets = []
                        bucket += 2
                    }
                }
            }
            if let stats {
                let trips = stats.roundTripNanos.suffix(120).map { Double($0) / 1e6 }.sorted()
                if !trips.isEmpty {
                    roundTripP50 = trips[trips.count / 2]
                    roundTripP95 = trips[min(trips.count - 1, Int(Double(trips.count) * 0.95))]
                }
                keyframes = stats.keyframes
                lostFrames = stats.lostFrames
                congestionDrops = stats.congestionDrops
            }
        }
    }

    nonisolated struct AudioReadout: Sendable {
        var played = 0
        var underruns = 0
        var concealed = 0
        var late = 0
        var dropped = 0
        /// 为把深度垫回目标多放的静音包（不算补洞，但也是一段空白）。
        var stretched = 0
        /// 接收端等不到、跳过的包。
        var skipped = 0
        var targetMillis = 0
        var bufferedMillis = 0.0
        var estimatedMillis = 0.0

        init(before: RemoteAudioReceiver.Snapshot, after: RemoteAudioReceiver.Snapshot, buffered: [Int],
             oneWayMillis: Double) {
            played = after.counters.played - before.counters.played
            underruns = after.counters.underruns - before.counters.underruns
            concealed = after.counters.concealed - before.counters.concealed
            late = after.counters.late - before.counters.late
            dropped = after.counters.dropped - before.counters.dropped
            stretched = after.counters.stretched - before.counters.stretched
            skipped = after.skipped - before.skipped
            targetMillis = after.targetMillis
            bufferedMillis = buffered.isEmpty ? Double(after.bufferedMillis)
                                              : Double(buffered.reduce(0, +)) / Double(buffered.count)
            estimatedMillis = oneWayMillis + bufferedMillis
        }
    }

    nonisolated struct DropRecovery: Sendable {
        /// 降速后最后一次卡顿结束（相对降速时刻，秒）；降速期间没卡顿就是 0。
        var settleSeconds: Double?
        /// 降速期间的卡顿。
        var stallsDuringDrop = 0
        var stallSecondsDuringDrop = 0.0
        var longestDuringDrop = 0.0
        /// 恢复带宽后，目标码率回到降速前八成用了多久（秒）；nil = 观测窗口内没回去。
        var reboundSeconds: Double?
        var targetBeforeDrop = 0.0
        var targetDuringDrop = 0.0
    }

    private static func dropRecovery(samples: [Sample], frames: [UInt64], start: UInt64) -> DropRecovery {
        var result = DropRecovery()
        let before = samples.filter { $0.t >= 3 && $0.t < dropAt }.map(\.target).sorted()
        let reference = before.isEmpty ? 0 : before[before.count / 2]
        result.targetBeforeDrop = Double(reference) / 1e6
        result.targetDuringDrop = Double(samples.filter { $0.t >= dropAt && $0.t < restoreAt }.map(\.target).min() ?? 0) / 1e6
        if let rebound = samples.first(where: { $0.t >= restoreAt && Double($0.target) >= 0.8 * Double(reference) }) {
            result.reboundSeconds = rebound.t - restoreAt
        }
        let dropStart = start + UInt64(dropAt * 1e9), dropEnd = start + UInt64(restoreAt * 1e9)
        let window = frames.filter { $0 > dropStart && $0 <= dropEnd }
        let points = [dropStart] + window + [dropEnd]
        var settle = 0.0
        for (later, earlier) in zip(points.dropFirst(), points) where Double(later - earlier) / 1e9 > 0.2 {
            result.stallsDuringDrop += 1
            result.stallSecondsDuringDrop += Double(later - earlier) / 1e9
            result.longestDuringDrop = max(result.longestDuringDrop, Double(later - earlier) / 1e9)
            settle = Double(later - dropStart) / 1e9
        }
        result.settleSeconds = settle
        return result
    }

    nonisolated struct Row: Sendable {
        let profile: Profile
        let transport: Transport
        let content: SyntheticContent
        var connectMillis = 0.0
        var firstFrameMillis: Double?
        var audioStartMillis: Double?
        var video: VideoReadout?
        var audio: AudioReadout?
        var recovery: DropRecovery?

        var consoleLine: String {
            let v = video
            return "\(profile.name) · \(content.name) · \(transport.rawValue)：建连 \(ms(connectMillis))，首帧 \(ms(firstFrameMillis))，"
                + "卡顿 \(v?.stalls ?? -1) 次 \(f1(v?.stallSeconds)) s，\(f1(v?.fps)) fps，交付 \(pct(v?.delivered))，"
                + "画面延迟 p50 \(ms(v?.latencyP50)) / p95 \(ms(v?.latencyP95))，"
                + "目标 \(f1(v?.targetStart))→\(f1(v?.targetMin))→\(f1(v?.targetEnd)) Mbps，实发 \(f1(v?.sentMbps)) Mbps，"
                + "声音欠载 \(audio?.underruns ?? -1) / 补洞 \(audio?.concealed ?? -1) / 垫静音 \(audio?.stretched ?? -1)"
                + " / 晚到 \(audio?.late ?? -1) / 跳过 \(audio?.skipped ?? -1)，声音目标 \(audio?.targetMillis ?? -1) ms"
        }
    }

    nonisolated struct SwitchRow: Sendable {
        let name: String
        let summary: String
        var detectMillis: Double?
        var reconnectMillis: Double?
        var firstFrameMillis: Double?
        var afterRecovery: VideoReadout?
        var audio: AudioReadout?

        init(name: String, summary: String) {
            self.name = name
            self.summary = summary
        }

        var consoleLine: String {
            "\(name)：察觉 \(ms(detectMillis))，连回 \(ms(reconnectMillis))，画面恢复 \(ms(firstFrameMillis))，"
                + "恢复后卡顿 \(afterRecovery?.stalls ?? -1) 次，声音欠载 \(audio?.underruns ?? -1)"
        }
    }

    nonisolated struct ConnectRow: Sendable {
        let profile: Profile
        let variant: DialVariant
        let millis: [Double]
        let paths: [String]

        var median: Double { millis.sorted()[millis.count / 2] }
        var consoleLine: String {
            "建连 \(profile.name) · \(variant.rawValue)：\(millis.map { ms($0) }.joined(separator: " / "))，路径 \(paths.joined(separator: "/"))"
        }
    }

    // MARK: - 报告

    nonisolated final class Report: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [Row] = []
        private var switches: [SwitchRow] = []
        private var connects: [ConnectRow] = []
        func add(_ row: Row) { lock.lock(); rows.append(row); lock.unlock() }
        func add(_ row: SwitchRow) { lock.lock(); switches.append(row); lock.unlock() }
        func add(_ row: ConnectRow) { lock.lock(); connects.append(row); lock.unlock() }
        var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return rows.isEmpty && switches.isEmpty && connects.isEmpty }

        func markdown() -> String {
            lock.lock(); defer { lock.unlock() }
            var out: [String] = []
            if !rows.isEmpty {
                let groups = grouped(rows) { "\($0.profile.id)|\($0.content.rawValue)|\($0.transport.rawValue)" }
                let rounds = groups.map(\.count).max() ?? 1
                out.append("### 远程桌面 + 声音")
                out.append("")
                out.append("每格 \(rounds) 轮，写中位数，小字是各轮的最小–最大。")
                out.append("")
                out.append("画面内容：" + SyntheticContent.allCases.map { "**\($0.name)**——\($0.summary)" }.joined(separator: "；") + "。")
                out.append("")
                out.append("卡顿 = 超过 200 ms 没有新画面（精修帧不算新画面）。交付 = 源出的新画面里手机显示了几成。"
                           + "画面延迟 = 一帧在 Mac 上采集到在手机上显示（同一进程同一个钟，含编码、传输、解码）。"
                           + "码率是 Mac 端码控的目标码率，「实发」是发送端实际吐出的字节。声音延迟 = 单程网络时延 + 抖动缓冲平均深度（估算）。"
                           + "帧往返是 Mac 码控自己量的（发出到收到确认）。")
                out.append("")
                out.append("| 档位 | 内容 | 路径 | 建连 | 首帧 | 卡顿次数 | 卡顿总时长 | 最长卡顿 | 帧率 | 交付 | 画面延迟 p50 | 画面延迟 p95 | 目标码率 最低 / 末 | 实发 | 帧往返 p50 | 帧往返 p95 | 关键帧 / 丢帧 | 声音欠载 / 补洞 | 声音估算延迟 |")
                out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
                for group in groups {
                    let row = group[0]
                    let v = group.compactMap(\.video)
                    let a = group.compactMap(\.audio)
                    let firsts = group.map { $0.firstFrameMillis ?? 20_000 }
                    out.append("| \(row.profile.name)<br><sub>\(row.profile.summary)</sub> | \(row.content.name) | \(row.transport.rawValue) | "
                               + agg(group.map(\.connectMillis), ms) + " | "
                               + agg(firsts) { $0 >= 20_000 ? "> 20 s" : ms($0) } + " | "
                               + agg(v.map { Double($0.stalls) }, f0) + " | " + agg(v.map(\.stallSeconds)) { "\(f1($0)) s" } + " | "
                               + agg(v.map(\.longestGap)) { "\(f2($0)) s" } + " | " + agg(v.map(\.fps), f1) + " | "
                               + agg(v.compactMap(\.delivered), pct) + " | " + agg(v.map(\.latencyP50), ms) + " | "
                               + agg(v.map(\.latencyP95), ms) + " | "
                               + agg(v.map(\.targetMin), f1) + " / " + agg(v.map(\.targetEnd), f1) + " Mbps | "
                               + agg(v.map(\.sentMbps), f1) + " Mbps | " + agg(v.map(\.roundTripP50), ms) + " | "
                               + agg(v.map(\.roundTripP95), ms) + " | " + agg(v.map { Double($0.keyframes) }, f0) + " / "
                               + agg(v.map { Double($0.lostFrames) }, f0) + " | " + agg(a.map { Double($0.underruns) }, f0) + " / "
                               + agg(a.map { Double($0.concealed) }, f0) + " | " + agg(a.map(\.estimatedMillis), ms) + " |")
                }
                let drops = groups.filter { $0[0].recovery != nil }
                if !drops.isEmpty {
                    out.append("")
                    out.append("#### 带宽骤降的恢复")
                    out.append("")
                    out.append("| 内容 | 路径 | 降速前目标 | 降速期间最低目标 | 降速期间卡顿总时长 | 降速期间最长卡顿 | 恢复带宽后码率回到八成 |")
                    out.append("|---|---|---|---|---|---|---|")
                    for group in drops {
                        let r = group.compactMap(\.recovery)
                        out.append("| \(group[0].content.name) | \(group[0].transport.rawValue) | " + agg(r.map(\.targetBeforeDrop), f1) + " Mbps | "
                                   + agg(r.map(\.targetDuringDrop), f1) + " Mbps | " + agg(r.map(\.stallSecondsDuringDrop)) { "\(f1($0)) s" }
                                   + " | " + agg(r.map(\.longestDuringDrop)) { "\(f2($0)) s" } + " | "
                                   + agg(r.map { $0.reboundSeconds ?? 99 }) { $0 >= 99 ? "没回去" : "\(f1($0)) s" } + " |")
                    }
                }
                out.append("")
                out.append("#### 码率曲线（每 2 秒：目标 / 实发，Mbps；每轮一行）")
                out.append("")
                for row in rows {
                    let curve = row.video?.curve.map { "\(f1($0.target))/\(f1($0.sent))" }.joined(separator: " → ") ?? ""
                    out.append("- \(row.profile.name) · \(row.content.name) · \(row.transport.rawValue)：\(curve)")
                }
            }
            if !switches.isEmpty {
                out.append("")
                out.append("### 路径切换（基线网络，直连 → 中继 TCP）")
                out.append("")
                out.append("时间都从断开那一刻算起；中位数，小字是各轮范围。")
                out.append("")
                out.append("| 场景 | 轮数 | 察觉断开 | 连回（中继） | 画面恢复 | 恢复后 10 s 卡顿总时长 | 恢复后帧率 | 恢复后声音欠载 / 补洞 |")
                out.append("|---|---|---|---|---|---|---|---|")
                for group in grouped(switches, by: \.name) {
                    let row = group[0]
                    let v = group.compactMap(\.afterRecovery)
                    let a = group.compactMap(\.audio)
                    out.append("| \(row.name)<br><sub>\(row.summary)</sub> | \(group.count) | "
                               + agg(group.compactMap(\.detectMillis), ms) + " | " + agg(group.compactMap(\.reconnectMillis), ms) + " | "
                               + agg(group.compactMap(\.firstFrameMillis), ms) + " | " + agg(v.map(\.stallSeconds)) { "\(f1($0)) s" } + " | "
                               + agg(v.map(\.fps), f1) + " | "
                               + (a.isEmpty ? "（声音没恢复）" : agg(a.map { Double($0.underruns) }, f0) + " / "
                                  + agg(a.map { Double($0.concealed) }, f0)) + " |")
                }
            }
            if !connects.isEmpty {
                out.append("")
                out.append("### 建连耗时（经真实中继 1.3.0，手机到中继一段加差网络，各 3 次）")
                out.append("")
                out.append("「打洞不通 → 中继」在本机测不出（两端都在回环上，打洞总能通）：它比「Mac 不给直连」多出等打洞的时间，"
                           + "上限是 `RemoteDirectAttempt.connectLimit`（\(RemoteDirectAttempt.connectLimit)）。")
                out.append("")
                out.append("| 档位 | 方式 | 中位数 | 3 次 | 实际路径 |")
                out.append("|---|---|---|---|---|")
                for row in connects {
                    out.append("| \(row.profile.name) | \(row.variant.rawValue) | \(ms(row.median)) | "
                               + "\(row.millis.map { ms($0) }.joined(separator: " / ")) | \(row.paths.joined(separator: " / ")) |")
                }
            }
            return out.joined(separator: "\n")
        }

        /// 按键分组，保持第一次出现的顺序。
        private func grouped<T>(_ items: [T], by key: (T) -> String) -> [[T]] {
            var order: [String] = []
            var groups: [String: [T]] = [:]
            for item in items {
                let k = key(item)
                if groups[k] == nil { order.append(k) }
                groups[k, default: []].append(item)
            }
            return order.compactMap { groups[$0] }
        }

        /// 中位数；多轮且不一样时后面跟各轮的最小–最大。
        private func agg(_ values: [Double], _ format: (Double) -> String) -> String {
            guard !values.isEmpty else { return "—" }
            let sorted = values.sorted()
            let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2]
                                               : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            let low = format(sorted.first!), high = format(sorted.last!)
            return sorted.count > 1 && low != high ? "\(format(median))<br><sub>\(low)–\(high)</sub>" : format(median)
        }
    }

    nonisolated(unsafe) static let report = Report()

    nonisolated override class func tearDown() {
        guard !report.isEmpty else { return }
        let markdown = report.markdown()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("weak-network-matrix.md")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        print("<!-- weak-net-matrix:begin -->\n\(markdown)\n<!-- weak-net-matrix:end -->")
        print("[弱网矩阵] 报告：\(url.path)")
    }
}

private nonisolated func ms(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value >= 10_000 ? String(format: "%.1f s", value / 1000) : String(format: "%.0f ms", value)
}

private nonisolated func pct(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }

extension SyntheticContent {
    nonisolated var name: String {
        switch self {
        case .fullScreen: "满屏变化"
        case .typing: "打字"
        case .scroll: "局部滚动"
        case .smallArea: "小区域"
        }
    }

    nonisolated var summary: String {
        switch self {
        case .fullScreen: "每帧整屏都变，30 fps（压力上限）"
        case .typing: "终端里一个字一个字出现，10 字/秒"
        case .scroll: "约四成屏幕的窗格里文字匀速上滚，30 fps"
        case .smallArea: "一角约 4% 的区域整块变化，30 fps"
        }
    }
}

private nonisolated func f0(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "—" }
private nonisolated func f1(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
private nonisolated func f2(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }
