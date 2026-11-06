import CryptoKit
import Foundation

// 打洞诊断（G2）：只量能不能通、多快能通、通了之后的往返和丢包，不接业务。
// 打洞能不能作为连接路径取决于真实网络组合，这里的结果决定后面还做不做 P2P。

/// 一次诊断的结果。不含 IP 地址，可以放心复制给别人看。
nonisolated struct RemoteICEProbeResult: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    /// 用户写的网络备注，如「移动 5G ↔ 家里电信」。
    var note = ""
    /// 手机此刻走的网络：Wi-Fi、蜂窝……
    var network = ""
    var macName = ""
    var connected = false
    var failure: String?
    var gatherMillis = 0
    var signalMillis: Int?
    /// 从拿到 Mac 的回复到打通。
    var connectMillis: Int?
    var localCandidates: [String] = []
    var remoteCandidates: [String] = []
    var selectedLocal: String?
    var selectedRemote: String?
    var roundTripMillis: Double?
    var roundTripP95Millis: Double?
    var lossPercent: Int?

    var summaryLine: String {
        let time = date.formatted(.iso8601)
        let path = connected ? "\(selectedLocal ?? "?")→\(selectedRemote ?? "?")" : "失败(\(failure ?? "未知"))"
        let roundTrip = roundTripMillis.map { String(format: "%.0fms", $0) } ?? "-"
        return "\(time)\t\(note)\t\(network)\t\(path)\t收集\(gatherMillis)ms\t信令\(signalMillis ?? -1)ms\t"
            + "打通\(connectMillis ?? -1)ms\t往返\(roundTrip)\t丢包\(lossPercent ?? -1)%\t"
            + "本机[\(localCandidates.joined(separator: ","))]\t对端[\(remoteCandidates.joined(separator: ","))]"
    }
}

/// 一个 ICE agent 加上诊断要读的状态。
nonisolated final class RemoteICEProbeSession: @unchecked Sendable {
    private static let pingByte: UInt8 = 0x01
    private static let pongByte: UInt8 = 0x02
    private static let packetBytes = 9

    private let lock = NSLock()
    private var phase = RemoteICEAgent.Phase.disconnected
    private var gatheringDone = false
    private var connectedAt: DispatchTime?
    private var sentAt: [UInt64: DispatchTime] = [:]
    private var roundTrips: [UInt64: Double] = [:]
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.ice-probe")
    private var agent: RemoteICEAgent?

    /// `echoes`：Mac 这一端把收到的 ping 原样弹回。
    init?(stunHost: String?, stunPort: UInt16, echoes: Bool) {
        let box = WeakBox()
        var handlers = RemoteICEAgent.Handlers()
        handlers.onPhase = { box.session?.record(phase: $0) }
        handlers.onGatheringDone = { box.session?.recordGatheringDone() }
        handlers.onData = { box.session?.receive($0, echoes: echoes) }
        guard let agent = RemoteICEAgent(stunHost: stunHost, stunPort: stunPort, queue: queue, handlers: handlers) else {
            return nil
        }
        self.agent = agent
        box.session = self
    }

    private final class WeakBox: @unchecked Sendable {
        weak var session: RemoteICEProbeSession?
    }

    deinit {
        agent?.close()
    }

    func gather() -> Bool { agent?.gather() ?? false }
    func localDescription() -> String? { agent?.localDescription() }
    func setRemote(_ description: String) -> Bool { agent?.setRemote(description) ?? false }
    func selectedCandidates() -> (local: String, remote: String)? { agent?.selectedCandidates() }
    func close() { agent?.close() }

    var currentPhase: RemoteICEAgent.Phase { locked { phase } }
    var isGatheringDone: Bool { locked { gatheringDone } }
    var connectedTime: DispatchTime? { locked { connectedAt } }

    /// 等收集完成（或到时限）。STUN 没回音时 libjuice 要重试二十多秒，不能一直等。
    func waitForGathering(limit: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !isGatheringDone, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 等打通或失败。
    func waitForConnection(limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline, !Task.isCancelled {
            let current = currentPhase
            if current.isConnected { return true }
            if current == .failed { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// 发一串 ping，量往返（中位数、p95）和丢包。
    func measure(count: Int = 40, interval: Duration = .milliseconds(50), settle: Duration = .milliseconds(800)) async
        -> (roundTripMillis: Double?, p95Millis: Double?, lossPercent: Int) {
        for sequence in 0..<UInt64(count) {
            locked { sentAt[sequence] = .now() }
            agent?.send(Self.packet(Self.pingByte, sequence))
            try? await Task.sleep(for: interval)
        }
        try? await Task.sleep(for: settle)
        let trips = locked { roundTrips.values.sorted() }
        let percentiles = RemoteRoundTrips.percentiles(trips)
        return (percentiles.p50, percentiles.p95, (count - trips.count) * 100 / max(1, count))
    }

    private func record(phase newPhase: RemoteICEAgent.Phase) {
        locked {
            phase = newPhase
            if newPhase.isConnected, connectedAt == nil { connectedAt = .now() }
        }
    }

    private func recordGatheringDone() {
        locked { gatheringDone = true }
    }

    private func receive(_ data: Data, echoes: Bool) {
        guard data.count == Self.packetBytes, let kind = data.first else { return }
        if kind == Self.pingByte, echoes {
            var reply = data
            reply[reply.startIndex] = Self.pongByte
            agent?.send(reply)
        } else if kind == Self.pongByte {
            var sequence: UInt64 = 0
            for byte in data.dropFirst() { sequence = sequence << 8 | UInt64(byte) }
            let now = DispatchTime.now()
            locked {
                guard let sent = sentAt[sequence], roundTrips[sequence] == nil else { return }
                roundTrips[sequence] = Double(now.uptimeNanoseconds - sent.uptimeNanoseconds) / 1e6
            }
        }
    }

    private static func packet(_ kind: UInt8, _ sequence: UInt64) -> Data {
        var data = Data([kind])
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: sequence >> UInt64(shift)))
        }
        return data
    }

    private func locked<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 手机发起一次打洞诊断。
nonisolated struct RemoteICEProbeRunner: Sendable {
    static let gatherLimit: Duration = .milliseconds(2500)
    static let connectLimit: Duration = .seconds(15)
    /// 比 Mac 的收集时限长：Mac 收集完才回复。
    static let signalTimeout: TimeInterval = 8

    let relay: RemoteRelayClient
    let identity: RemoteIdentityStore
    let localID: UUID

    /// `family`：只用这一族的候选地址（nil = 都用）。不出公网的地址（`fe80::`、`169.254.*`、`fc00::/7`）一律不用：
    /// 手机插着线或连着调试隧道时两端会经那条链路互相看见，打通的是那根线，不是公网。
    /// `publicOnly`：私有 IPv4 也不用（默认）。诊断量的是公网路径，同一局域网里私有地址一配就通，会把局域网算成直连。
    func run(mac: RemotePeer, family: RemoteICEAddressFamily? = nil, publicOnly: Bool = true) async -> RemoteICEProbeResult {
        var result = RemoteICEProbeResult()
        result.macName = mac.name
        let config = relay.relayConfig
        guard let session = RemoteICEProbeSession(stunHost: config.host, stunPort: UInt16(clamping: config.port),
                                                  echoes: false) else {
            result.failure = "无法创建 ICE agent"
            return result
        }
        defer { session.close() }
        do {
            let started = DispatchTime.now()
            guard session.gather() else {
                result.failure = "无法开始收集地址"
                return result
            }
            await session.waitForGathering(limit: Self.gatherLimit)
            result.gatherMillis = Self.millis(since: started)
            guard let gathered = session.localDescription() else {
                result.failure = "拿不到本机描述"
                return result
            }
            let description = RemoteICEDescriptionFilter.keep(gathered, family: family, publicOnly: publicOnly)
            result.localCandidates = Self.labels(description)
            guard !result.localCandidates.isEmpty else {
                result.failure = "本机没有\(family?.label ?? "")公网候选地址"
                return result
            }

            let fullAnswer = try await exchange(description: description, mac: mac)
            result.signalMillis = Self.millis(since: started) - result.gatherMillis
            let answer = RemoteICEDescriptionFilter.keep(fullAnswer, family: family, publicOnly: publicOnly)
            result.remoteCandidates = Self.labels(answer)
            guard !result.remoteCandidates.isEmpty else {
                result.failure = "Mac 没有\(family?.label ?? "")公网候选地址"
                return result
            }
            let answered = DispatchTime.now()
            guard session.setRemote(answer) else {
                result.failure = "Mac 的描述解析失败"
                return result
            }
            guard await session.waitForConnection(limit: Self.connectLimit) else {
                result.failure = session.currentPhase == .failed ? "所有候选地址都不通" : "超时"
                return result
            }
            result.connected = true
            if let connected = session.connectedTime {
                result.connectMillis = Int((connected.uptimeNanoseconds &- answered.uptimeNanoseconds) / 1_000_000)
            }
            if let selected = session.selectedCandidates() {
                result.selectedLocal = RemoteICECandidateKind(sdp: selected.local)?.label
                result.selectedRemote = RemoteICECandidateKind(sdp: selected.remote)?.label
            }
            let measured = await session.measure()
            result.roundTripMillis = measured.roundTripMillis
            result.roundTripP95Millis = measured.p95Millis
            result.lossPercent = measured.lossPercent
        } catch {
            result.failure = error.localizedDescription
        }
        return result
    }

    private func exchange(description: String, mac: RemotePeer) async throws -> String {
        let sessionID = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }).base64URLEncoded
        let shared = try RemoteSignalBox.sharedKey(local: try identity.localIdentity(), remotePublicKey: mac.publicKey)
        let offer = RemoteSignalBody(kind: .iceProbe, deviceID: localID, sentAt: Date().timeIntervalSince1970,
                                     nonce: RemoteSignalBody.newNonce(), ice: description)
        let sealed = try RemoteSignalBox.seal(offer, key: shared, session: sessionID, direction: .phoneToMac)
        let box = try await relay.signal(to: mac.id, from: localID, session: sessionID, box: sealed,
                                         timeout: Self.signalTimeout)
        let reply: RemoteSignalBody
        do {
            reply = try RemoteSignalBox.open(box, key: shared, session: sessionID, direction: .macToPhone)
        } catch {
            throw RemoteProtocolError.peerIdentityChanged
        }
        guard reply.deviceID == mac.id else { throw RemoteProtocolError.peerIdentityChanged }
        if reply.kind == .denied { throw RemoteRelayError.notAllowed }
        guard reply.kind == .iceProbeAnswer, let answer = reply.ice else { throw RemoteRelayError.malformed }
        return answer
    }

    private static func labels(_ description: String) -> [String] {
        RemoteICECandidateKind.all(inDescription: description).map(\.label).sorted()
    }

    private static func millis(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }
}

nonisolated enum RemoteICEAddressFamily: String, Codable, CaseIterable, Sendable {
    case ipv4
    case ipv6

    var label: String { self == .ipv4 ? " IPv4 " : " IPv6 " }
}

/// 按地址族筛候选地址，并去掉不出公网的地址（链路本地、IPv6 唯一本地）。不是候选地址的行（ufrag、密码……）原样留着。
nonisolated enum RemoteICEDescriptionFilter {
    /// `publicOnly`：再去掉不出公网的 IPv4（10/8、172.16/12、192.168/16、运营商 NAT 100.64/10、回环，以及
    /// 198.18/15——Clash / Surge 一类代理的 TUN 网卡用它当假地址，Mac 开着代理时会成为 host 候选）。
    /// 「只走公网」与网络诊断用：同一局域网里两端的私有地址一配就通，量到的是局域网，不是外出时的那条路。
    /// srflx 候选的地址本身是公网映射，留着。
    static func keep(_ description: String, family: RemoteICEAddressFamily?, publicOnly: Bool = false) -> String {
        description.split(separator: "\r\n", omittingEmptySubsequences: false).flatMap {
            $0.split(separator: "\n", omittingEmptySubsequences: false)
        }.filter { line in
            guard line.hasPrefix("a=candidate:") else { return true }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let typeIndex = fields.firstIndex(of: "typ"), typeIndex >= 2 else { return false }
            let address = fields[typeIndex - 2].lowercased()
            let isIPv6 = address.contains(":")
            if isIPv6 ? Self.isLinkLocalOrPrivateIPv6(address) : address.hasPrefix("169.254.") {
                return false
            }
            if publicOnly, !isIPv6, Self.isPrivateIPv4(address) { return false }
            switch family {
            case nil: return true
            case .ipv4: return !isIPv6
            case .ipv6: return isIPv6
            }
        }.joined(separator: "\r\n")
    }

    /// `fe80::/10` 链路本地与 `fc00::/7` 唯一本地（ULA）。后者不出公网：`devicectl` 在手机与 Mac 之间建的
    /// 调试隧道就是 ULA（经 USB 或 Wi-Fi），打洞要是挑中它，量到的是那条隧道。
    private static func isLinkLocalOrPrivateIPv6(_ address: String) -> Bool {
        ["fe8", "fe9", "fea", "feb", "fc", "fd"].contains { address.hasPrefix($0) }
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        case (198, 18...19): return true
        default: return false
        }
    }
}

/// 往返时间的中位数和 p95。
nonisolated enum RemoteRoundTrips {
    static func percentiles(_ sorted: [Double]) -> (p50: Double?, p95: Double?) {
        guard !sorted.isEmpty else { return (nil, nil) }
        let p95Index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        return (sorted[sorted.count / 2], sorted[max(0, p95Index)])
    }
}

/// Mac 回应一次打洞诊断：回复自己的候选地址，把收到的 ping 弹回去，到时间就关。
nonisolated enum RemoteICEProbeResponder {
    static let lifetime: Duration = .seconds(30)

    static func serve(request: RemoteSignalResponder.ProbeRequest, session sessionID: String, localID: UUID,
                      stunHost: String, stunPort: UInt16, reply: @Sendable (String) async -> Void) async {
        guard let session = RemoteICEProbeSession(stunHost: stunHost, stunPort: stunPort, echoes: true) else { return }
        defer { session.close() }
        // 先设对端，这一端才是 controlled；地址一出来就开始往手机打。
        guard session.setRemote(request.remoteDescription), session.gather() else { return }
        await session.waitForGathering(limit: RemoteICEProbeRunner.gatherLimit)
        guard let description = session.localDescription() else { return }
        let answer = RemoteSignalBody(kind: .iceProbeAnswer, deviceID: localID, sentAt: Date().timeIntervalSince1970,
                                      nonce: RemoteSignalBody.newNonce(), ice: description)
        guard let sealed = try? RemoteSignalBox.seal(answer, key: request.sharedKey, session: sessionID,
                                                     direction: .macToPhone) else { return }
        await reply(sealed)
        try? await Task.sleep(for: lifetime)
    }
}
