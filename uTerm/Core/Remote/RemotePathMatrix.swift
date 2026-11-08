import CryptoKit
import Foundation
@preconcurrency import Network

// 网络诊断：同一台 Mac，局域网、IPv6 直连、IPv4 直连、TCP 中继各跑几轮，一次看清每条路能不能通、多快能通、
// 通了之后的往返与丢包。每条路都强制只走自己（不看「只走公网」），不接业务，不影响现有连接。

/// 测哪条路。顺序即实际连接的优先级：局域网 → 打洞直连 → 中继。
nonisolated enum RemotePathProbeMode: String, Codable, CaseIterable, Sendable {
    case localNetwork
    case directIPv6
    case directIPv4
    case relay

    var label: String {
        switch self {
        case .localNetwork: return "局域网"
        case .directIPv6: return "直连 IPv6"
        case .directIPv4: return "直连 IPv4"
        case .relay: return "中继"
        }
    }

    var family: RemoteICEAddressFamily? {
        switch self {
        case .directIPv6: return .ipv6
        case .directIPv4: return .ipv4
        case .localNetwork, .relay: return nil
        }
    }

    var isDirect: Bool { family != nil }
}

/// 局域网那条路要的：Bonjour 此刻看到的端点。
nonisolated struct RemoteLANTarget: Sendable {
    let macName: String
    let endpoint: NWEndpoint
    let expectedPeer: RemotePeer?
}

/// 一条路跑一次的结果。不含 IP 地址。
nonisolated struct RemotePathProbeResult: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// 同一次诊断的结果共用一个；按它找出「上次结果」。
    var runID: UUID?
    var date = Date()
    var round = 0
    var mode = RemotePathProbeMode.relay
    var note = ""
    var network = ""
    var connected = false
    var failure: String?
    /// 从开始到能收发：直连含收集地址、信令与打洞，中继含信令与回拨。
    var setupMillis: Int?
    /// 直连选中的候选地址对，如 `srflx-v6→host-v6`。
    var selectedPair: String?
    var roundTripMillis: Double?
    var roundTripP95Millis: Double?
    var lossPercent: Int?

    var summaryLine: String {
        let time = date.formatted(.iso8601)
        let outcome = connected ? (selectedPair ?? "通") : "失败(\(failure ?? "未知"))"
        return "\(time)\t第\(round)轮\t\(mode.label)\t\(note)\t\(network)\t\(outcome)\t建立\(setupMillis ?? -1)ms\t"
            + "往返p50 \(Self.format(roundTripMillis))\tp95 \(Self.format(roundTripP95Millis))\t丢包\(lossPercent ?? -1)%"
    }

    static func format(_ millis: Double?) -> String {
        millis.map { String(format: "%.0fms", $0) } ?? "-"
    }
}

/// 一条路的汇总。
nonisolated struct RemotePathProbeSummary: Equatable, Sendable {
    var mode: RemotePathProbeMode
    var attempts: Int
    var successes: Int
    var medianSetupMillis: Int?
    var medianRoundTripMillis: Double?
    var medianP95Millis: Double?
    var meanLossPercent: Int?

    static func summarize(_ results: [RemotePathProbeResult]) -> [RemotePathProbeSummary] {
        RemotePathProbeMode.allCases.compactMap { mode in
            let runs = results.filter { $0.mode == mode }
            guard !runs.isEmpty else { return nil }
            let ok = runs.filter(\.connected)
            func median<Value: Comparable>(_ values: [Value]) -> Value? {
                let sorted = values.sorted()
                return sorted.isEmpty ? nil : sorted[sorted.count / 2]
            }
            let losses = ok.compactMap(\.lossPercent)
            return RemotePathProbeSummary(
                mode: mode, attempts: runs.count, successes: ok.count,
                medianSetupMillis: median(ok.compactMap(\.setupMillis)),
                medianRoundTripMillis: median(ok.compactMap(\.roundTripMillis)),
                medianP95Millis: median(ok.compactMap(\.roundTripP95Millis)),
                meanLossPercent: losses.isEmpty ? nil : losses.reduce(0, +) / losses.count)
        }
    }

    /// 这条路失败的原因按出现先后列，重复的记次数：「超时 ×3；中继拒绝」。
    static func failures(of mode: RemotePathProbeMode, in results: [RemotePathProbeResult]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for result in results where result.mode == mode && !result.connected {
            let reason = result.failure ?? "未知"
            if counts[reason] == nil { order.append(reason) }
            counts[reason, default: 0] += 1
        }
        return order.map { reason in
            let count = counts[reason] ?? 1
            return count > 1 ? "\(reason) ×\(count)" : reason
        }.joined(separator: "；")
    }

    /// 毫秒读数的显示：10 以下留一位小数。
    static func millis(_ value: Double?) -> String? {
        value.map { $0 < 10 ? String(format: "%.1f ms", $0) : String(format: "%.0f ms", $0) }
    }

    var line: String {
        "\(mode.label)：成功 \(successes)/\(attempts)，建立 \(medianSetupMillis.map { "\($0)ms" } ?? "-")，"
            + "往返 p50 \(RemotePathProbeResult.format(medianRoundTripMillis)) "
            + "p95 \(RemotePathProbeResult.format(medianP95Millis))，丢包 \(meanLossPercent.map { "\($0)%" } ?? "-")"
    }
}

/// 手机这边跑矩阵：每轮依次测每条路，一条测完再测下一条，互不干扰。
nonisolated struct RemotePathMatrixRunner: Sendable {
    let identity: RemoteIdentityStore
    let localID: UUID
    /// nil = Mac 此刻不在这个局域网里（局域网那条路直接判不通）。
    var lan: RemoteLANTarget?
    /// nil = 没配中继或 Mac 不在中继上（直连与中继都要经中继交换地址，直接判不通，原因见 `relayUnavailable`）。
    var relay: RemoteRelayClient?
    var relayUnavailable = "没有配置中继"

    func run(mac: RemotePeer, rounds: Int, modes: [RemotePathProbeMode] = RemotePathProbeMode.allCases,
             progress: @Sendable (RemotePathProbeResult) async -> Void) async -> [RemotePathProbeResult] {
        var results: [RemotePathProbeResult] = []
        let runID = UUID()
        for round in 1...max(1, rounds) {
            for mode in modes {
                guard !Task.isCancelled else { return results }
                var result = await probe(mac: mac, mode: mode)
                result.runID = runID
                result.round = round
                results.append(result)
                await progress(result)
            }
        }
        return results
    }

    func probe(mac: RemotePeer, mode: RemotePathProbeMode) async -> RemotePathProbeResult {
        if mode == .localNetwork {
            guard let lan else {
                return RemotePathProbeResult(mode: mode, connected: false, failure: "Mac 不在这个局域网里")
            }
            return await RemoteLANProbe(identity: identity).run(lan)
        }
        guard let relay else {
            return RemotePathProbeResult(mode: mode, connected: false, failure: relayUnavailable)
        }
        if let family = mode.family {
            let runner = RemoteICEProbeRunner(relay: relay, identity: identity, localID: localID)
            let ice = await runner.run(mac: mac, family: family)
            var result = RemotePathProbeResult(mode: mode, connected: ice.connected, failure: ice.failure)
            if ice.connected {
                result.setupMillis = ice.gatherMillis + (ice.signalMillis ?? 0) + (ice.connectMillis ?? 0)
                result.selectedPair = "\(ice.selectedLocal ?? "?")→\(ice.selectedRemote ?? "?")"
                result.roundTripMillis = ice.roundTripMillis
                result.roundTripP95Millis = ice.roundTripP95Millis
                result.lossPercent = ice.lossPercent
            }
            return result
        }
        return await RemoteRelayProbe(relay: relay, identity: identity, localID: localID).run(mac: mac)
    }
}

/// 局域网这条路：用一个临时客户端只走 Bonjour 端点，握手 + 配对确认接通，再在这条连接上逐个 ping。
/// 和正式连接走的是同一套代码；Mac 允许同一台手机同时有几条连接，不会挤掉正在用的那条。
@MainActor
struct RemoteLANProbe {
    static let connectLimit: Duration = .seconds(8)

    let identity: RemoteIdentityStore

    func run(_ target: RemoteLANTarget, pings: Int = 40) async -> RemotePathProbeResult {
        var result = RemotePathProbeResult(mode: .localNetwork)
        let client = RemoteMacClient(macName: target.macName, endpoint: target.endpoint, identity: identity,
                                     expectedPeer: target.expectedPeer)
        client.updateRoutes(endpoint: target.endpoint, internetDialer: nil)
        defer { client.disconnect() }
        let started = DispatchTime.now()
        let connecting = Task { await client.connect() }
        let clock = ContinuousClock()
        let deadline = clock.now + Self.connectLimit
        while clock.now < deadline, !Task.isCancelled {
            if case .connected = client.state { break }
            if case .failed = client.state { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        connecting.cancel()
        switch client.state {
        case .connected:
            break
        case .failed(let message):
            result.failure = message
            return result
        case .awaitingApproval:
            result.failure = "Mac 上还没同意这台设备"
            return result
        case .idle, .connecting:
            result.failure = "超时"
            return result
        }
        result.setupMillis = RemoteRelayProbe.millis(since: started)
        let measured = await client.measureRoundTrips(count: pings)
        let percentiles = RemoteRoundTrips.percentiles(measured.millis.sorted())
        result.connected = true
        result.selectedPair = "TCP 局域网"
        result.roundTripMillis = percentiles.p50
        result.roundTripP95Millis = percentiles.p95
        result.lossPercent = measured.lost * 100 / max(1, pings)
        return result
    }
}

/// 一次诊断的结论：实际连接会走哪条路。正式连接先试局域网，再打洞（两族里谁先通走谁，这里取往返更短的），
/// 最后中继。
nonisolated enum RemotePathVerdict {
    static func chosen(_ summaries: [RemotePathProbeSummary], skipsLocalNetwork: Bool = false)
        -> RemotePathProbeSummary? {
        let usable = summaries.filter { $0.successes > 0 }
        if !skipsLocalNetwork, let lan = usable.first(where: { $0.mode == .localNetwork }) { return lan }
        let direct = usable.filter(\.mode.isDirect)
            .min { ($0.medianRoundTripMillis ?? .infinity) < ($1.medianRoundTripMillis ?? .infinity) }
        return direct ?? usable.first { $0.mode == .relay }
    }
}

/// 中继这条路：打招呼 → 经中继拨 → Mac 回拨接上 → 在这条字节流上量往返。
nonisolated struct RemoteRelayProbe: Sendable {
    static let signalTimeout: TimeInterval = 8

    let relay: RemoteRelayClient
    let identity: RemoteIdentityStore
    let localID: UUID

    func run(mac: RemotePeer, pings: Int = 40) async -> RemotePathProbeResult {
        var result = RemotePathProbeResult(mode: .relay)
        let started = DispatchTime.now()
        let transport: any RemoteTransport
        do {
            let session = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }).base64URLEncoded
            try await greet(mac: mac, session: session)
            transport = try await relay.dial(host: mac.id, session: session)
        } catch {
            result.failure = error.localizedDescription
            return result
        }
        defer { transport.cancel() }
        let meter = RemoteStreamEchoMeter(transport: transport)
        guard await meter.start() else {
            result.failure = "中继接上了但字节流起不来"
            return result
        }
        result.setupMillis = Self.millis(since: started)
        let measured = await meter.measure(count: pings)
        result.connected = true
        result.selectedPair = "TCP 中继"
        result.roundTripMillis = measured.p50
        result.roundTripP95Millis = measured.p95
        result.lossPercent = measured.lossPercent
        return result
    }

    private func greet(mac: RemotePeer, session: String) async throws {
        let shared = try RemoteSignalBox.sharedKey(local: try identity.localIdentity(), remotePublicKey: mac.publicKey)
        let offer = RemoteSignalBody(kind: .relayProbe, deviceID: localID, sentAt: Date().timeIntervalSince1970,
                                     nonce: RemoteSignalBody.newNonce())
        let sealed = try RemoteSignalBox.seal(offer, key: shared, session: session, direction: .phoneToMac)
        let box: String
        do {
            box = try await relay.signal(to: mac.id, from: localID, session: session, box: sealed,
                                         timeout: Self.signalTimeout)
        } catch RemoteRelayError.notAllowed {
            throw RemoteRelayProbeError.noAnswer
        }
        let reply: RemoteSignalBody
        do {
            reply = try RemoteSignalBox.open(box, key: shared, session: session, direction: .macToPhone)
        } catch {
            throw RemoteProtocolError.peerIdentityChanged
        }
        guard reply.deviceID == mac.id else { throw RemoteProtocolError.peerIdentityChanged }
        if reply.kind == .denied { throw RemoteRelayError.notAllowed }
        guard reply.kind == .relayProbeAnswer else { throw RemoteRelayError.malformed }
    }

    static func millis(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }
}

nonisolated enum RemoteRelayProbeError: LocalizedError {
    case noAnswer

    var errorDescription: String? {
        "\(Int(RemoteRelayProbe.signalTimeout)) 秒内没等到 Mac 回复（信令超时，或 Mac 版本不支持中继诊断）"
    }
}

/// 在一条可靠字节流上量往返：发固定 9 字节的 ping，对端原样弹回。
nonisolated final class RemoteStreamEchoMeter: @unchecked Sendable {
    static let packetBytes = 9

    private let transport: any RemoteTransport
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.relay-probe")
    private let lock = NSLock()
    private var buffer = Data()
    private var sentAt: [UInt64: DispatchTime] = [:]
    private var roundTrips: [Double] = []
    private var failed = false

    init(transport: any RemoteTransport) {
        self.transport = transport
    }

    /// 接上事件与读循环。中继的字节流交过来时已经连上，没有 `.ready` 可等，出错就算失败。
    func start() async -> Bool {
        transport.start(queue: queue) { [weak self] event in
            switch event {
            case .failed, .cancelled, .waiting: self?.locked { self?.failed = true }
            case .ready: break
            }
        }
        queue.async { self.readNext() }
        try? await Task.sleep(for: .milliseconds(50))
        return !locked { failed }
    }

    func measure(count: Int, interval: Duration = .milliseconds(50), settle: Duration = .seconds(2)) async
        -> (p50: Double?, p95: Double?, lossPercent: Int) {
        for sequence in 0..<UInt64(count) {
            var packet = Data([0x01])
            for shift in stride(from: 56, through: 0, by: -8) {
                packet.append(UInt8(truncatingIfNeeded: sequence >> UInt64(shift)))
            }
            locked { sentAt[sequence] = .now() }
            let probe = packet
            queue.async { self.transport.send(probe) { _ in } }
            try? await Task.sleep(for: interval)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + settle
        while locked({ roundTrips.count }) < count, clock.now < deadline, !locked({ failed }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let trips = locked { roundTrips.sorted() }
        let percentiles = RemoteRoundTrips.percentiles(trips)
        return (percentiles.p50, percentiles.p95, (count - trips.count) * 100 / max(1, count))
    }

    private func readNext() {
        transport.receive(maximumLength: 64 * 1024) { [weak self] data, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if isComplete || error != nil {
                self.locked { self.failed = true }
                return
            }
            self.readNext()
        }
    }

    private func consume(_ data: Data) {
        let now = DispatchTime.now()
        locked {
            buffer.append(data)
            while buffer.count >= Self.packetBytes {
                let packet = buffer.prefix(Self.packetBytes)
                buffer.removeFirst(Self.packetBytes)
                guard packet.first == 0x01 else { continue }
                var sequence: UInt64 = 0
                for byte in packet.dropFirst() { sequence = sequence << 8 | UInt64(byte) }
                guard let sent = sentAt.removeValue(forKey: sequence) else { continue }
                roundTrips.append(Double(now.uptimeNanoseconds &- sent.uptimeNanoseconds) / 1e6)
            }
        }
    }

    private func locked<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Mac 这一端：把中继回拨进来的字节原样弹回，到时间就关。
nonisolated enum RemoteStreamEchoServer {
    static let lifetime: Duration = .seconds(30)

    static func serve(_ transport: any RemoteTransport) async {
        let queue = DispatchQueue(label: "com.uozi.uTerm.remote.relay-echo")
        let done = RemoteEchoDone()
        transport.start(queue: queue) { event in
            switch event {
            case .failed, .cancelled: done.finish()
            case .ready, .waiting: break
            }
        }
        @Sendable func pump() {
            transport.receive(maximumLength: 64 * 1024) { data, isComplete, error in
                if let data, !data.isEmpty { transport.send(data) { _ in } }
                if isComplete || error != nil {
                    done.finish()
                    return
                }
                pump()
            }
        }
        queue.async { pump() }
        let clock = ContinuousClock()
        let deadline = clock.now + lifetime
        while !done.isFinished, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        queue.async { transport.cancel() }
    }
}

private nonisolated final class RemoteEchoDone: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

/// 链路诊断记录：只存在这台设备上，留最近 300 条。
nonisolated struct RemotePathMatrixLog {
    private static let key = DefaultsKey.remotePathMatrixLog
    static let limit = 300
    let defaults: UserDefaults

    func load() -> [RemotePathProbeResult] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([RemotePathProbeResult].self, from: data)) ?? []
    }

    func append(_ new: [RemotePathProbeResult]) {
        let all = new.reversed() + load()
        if let data = try? JSONEncoder().encode(Array(all.prefix(Self.limit))) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    /// 记录是最新在前的平铺列表；按 `runID` 切成一次次检测，最新的一次在前，每次之内按时间先后
    /// （旧记录没有 `runID` 的各自成组）。
    static func runs(_ results: [RemotePathProbeResult]) -> [[RemotePathProbeResult]] {
        var runs: [[RemotePathProbeResult]] = []
        for result in results {
            if let runID = result.runID, let index = runs.lastIndex(where: { $0.first?.runID == runID }) {
                runs[index].append(result)
            } else {
                runs.append([result])
            }
        }
        return runs.map { $0.reversed() }
    }

    /// 拷贝给排查用的纯文本：先每条路的汇总，空一行，再逐条明细。
    static func exportText(_ results: [RemotePathProbeResult]) -> String {
        let summaries = RemotePathProbeSummary.summarize(results).map(\.line)
        return (summaries + [""] + results.map(\.summaryLine)).joined(separator: "\n")
    }

    /// 最近一次诊断的全部结果（按时间先后）。
    func lastRun() -> [RemotePathProbeResult] {
        let all = load()
        guard let runID = all.first?.runID else { return [] }
        return all.filter { $0.runID == runID }.reversed()
    }
}
