import Foundation

/// 对端定期发回的接收报告（数据报 `.report`）。都是累计值，报告本身丢了也不影响下一份。
nonisolated struct RemoteLinkReport: Equatable, Sendable {
    /// 收到过的最大序号。
    var highestSequence: UInt64
    /// 累计收到的包数和字节数。
    var packets: UInt64
    var bytes: UInt64
    /// 用来量往返：最新收到的那个包的序号，以及它在对端等了多久才写进这份报告。
    var echoSequence: UInt64
    var echoHeldMicros: UInt32

    static let encodedSize = 36

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: Self.encodedSize)
        writer.u64(highestSequence)
        writer.u64(packets)
        writer.u64(bytes)
        writer.u64(echoSequence)
        writer.u32(echoHeldMicros)
        return writer.data
    }

    init(highestSequence: UInt64, packets: UInt64, bytes: UInt64, echoSequence: UInt64, echoHeldMicros: UInt32) {
        self.highestSequence = highestSequence
        self.packets = packets
        self.bytes = bytes
        self.echoSequence = echoSequence
        self.echoHeldMicros = echoHeldMicros
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        highestSequence = try reader.u64()
        packets = try reader.u64()
        bytes = try reader.u64()
        echoSequence = try reader.u64()
        echoHeldMicros = try reader.u32()
    }
}

/// 这条数据报链路现在的样子。
nonisolated struct RemoteLinkState: Equatable, Sendable {
    /// 平滑后的往返（纳秒）。还没测到时为 nil。
    var roundTripNanos: UInt64?
    /// 最近约 1 秒的丢包率，0–1。
    var lossRate: Double
    /// 对端实际收到的速率（字节 / 秒），最近 2 秒里的最大值。
    var deliveryRate: Double
    /// 发送节奏（字节 / 秒）。
    var pacingRate: Double
    /// 排队造成的额外往返（纳秒）。
    var queueDelayNanos: UInt64
}

/// 从接收报告估计链路：往返、丢包率、实际速率，并决定发送节奏。
///
/// **丢包不等于拥塞。** 手机网络和跨省链路上随机丢 1–5% 很常见，这时降速不会少丢一个包，只会白白损失带宽，
/// TCP 就栽在这里（往返 100 ms、丢 1% 时只剩约 1.4 Mbps）。所以这里只把两件事当拥塞：
/// - 排队：最近 `queueWindow` 里最快的往返也比基线慢了 `queueThreshold`。瓶颈的缓冲在变满，再发只会更慢。
/// - 大量丢包：`heavyLoss` 以上持续超过 `heavyLossHold`。多半撞上了限速器，排队信号看不出来。
///
/// 其余丢包交给重传和纠错。节奏只在确实有东西排队等发时才往上涨：没东西发的时候量不出带宽。
/// 涨也分两段：头一次撞到排队前涨得快，好尽快找到上限；撞过之后只慢慢探，否则每隔几个往返就冲过头一次，
/// 瓶颈把多出来的包全丢掉，重传反而占掉带宽。发出去的也不能比实际送达的快太多，送不到的再发也没用。
nonisolated struct RemoteLinkEstimator {
    struct Config: Equatable {
        var minRate: Double = 125_000
        var maxRate: Double = 125_000_000
        var initialRate: Double = 1_000_000
        var growth: Double = 1.25
        /// 撞过一次排队之后每个往返涨多少。
        var probeGrowth: Double = 1.05
        /// 节奏最多比最近实际送达的速率高多少。
        var deliveryHeadroom: Double = 1.25
        var backoff: Double = 0.85
        var queueThreshold: UInt64 = 40_000_000
        var queueWindow: UInt64 = 150_000_000
        var minRoundTripWindow: UInt64 = 10_000_000_000
        var heavyLoss: Double = 0.20
        var heavyLossHold: UInt64 = 1_000_000_000
        var deliveryWindow: UInt64 = 2_000_000_000
        var lossWindow: UInt64 = 1_000_000_000
    }

    private struct Sent {
        var sequence: UInt64
        var nanos: UInt64
    }

    private struct ReportPoint {
        var nanos: UInt64
        var highest: UInt64
        var packets: UInt64
        var bytes: UInt64
    }

    private struct TimedValue {
        var nanos: UInt64
        var value: UInt64
    }

    private struct RateSample {
        var nanos: UInt64
        var rate: Double
    }

    let config: Config
    private var sent: [Sent]
    private var reports: [ReportPoint] = []
    private var trips: [TimedValue] = []
    private var minTrips: [TimedValue] = []
    private var rates: [RateSample] = []
    private var smoothedTrip: Double?
    private var lastAdjustment: UInt64
    private var heavyLossSince: UInt64?
    private var backlogged = false
    private var foundCeiling = false
    private(set) var lossRate = 0.0
    private(set) var pacingRate: Double

    private static let sentCapacity = 8192

    init(config: Config = Config(), now: UInt64) {
        self.config = config
        pacingRate = config.initialRate
        lastAdjustment = now
        sent = Array(repeating: Sent(sequence: 0, nanos: 0), count: Self.sentCapacity)
    }

    var state: RemoteLinkState {
        RemoteLinkState(roundTripNanos: smoothedTrip.map { UInt64($0) }, lossRate: lossRate, deliveryRate: deliveryRate,
                        pacingRate: pacingRate, queueDelayNanos: queueDelay)
    }

    private var deliveryRate: Double {
        rates.lazy.map(\.rate).max() ?? 0
    }

    private var minTrip: UInt64? {
        minTrips.lazy.map(\.value).min()
    }

    private var queueDelay: UInt64 {
        guard let base = minTrip, let fastest = trips.lazy.map(\.value).min(), fastest > base else { return 0 }
        return fastest - base
    }

    mutating func recordSent(sequence: UInt64, now: UInt64) {
        sent[Int(sequence % UInt64(Self.sentCapacity))] = Sent(sequence: sequence, nanos: now)
    }

    /// 发送队列里有东西在等令牌：说明节奏卡住了发送。
    mutating func noteBacklog() {
        backlogged = true
    }

    /// 一份接收报告。返回节奏有没有变。
    @discardableResult
    mutating func record(_ report: RemoteLinkReport, now: UInt64) -> Bool {
        recordRoundTrip(report, now: now)
        recordDelivery(report, now: now)
        return adjust(now: now)
    }

    private mutating func recordRoundTrip(_ report: RemoteLinkReport, now: UInt64) {
        let slot = sent[Int(report.echoSequence % UInt64(Self.sentCapacity))]
        guard slot.sequence == report.echoSequence, slot.sequence != 0, now > slot.nanos else { return }
        let held = UInt64(report.echoHeldMicros) * 1000
        let elapsed = now - slot.nanos
        let trip = elapsed > held ? elapsed - held : 0
        guard trip > 0 else { return }
        smoothedTrip = smoothedTrip.map { $0 * 0.875 + Double(trip) * 0.125 } ?? Double(trip)
        trips.removeAll { now &- $0.nanos > config.queueWindow }
        trips.append(TimedValue(nanos: now, value: trip))
        minTrips.removeAll { now &- $0.nanos > config.minRoundTripWindow }
        if let last = minTrips.last, last.value <= trip { return }
        // 单调栈：比新样本大的旧样本再也不会成为最小值。
        minTrips.removeAll { $0.value >= trip }
        minTrips.append(TimedValue(nanos: now, value: trip))
    }

    private mutating func recordDelivery(_ report: RemoteLinkReport, now: UInt64) {
        let point = ReportPoint(nanos: now, highest: report.highestSequence, packets: report.packets, bytes: report.bytes)
        defer {
            reports.append(point)
            reports.removeAll { now &- $0.nanos > config.lossWindow * 2 }
        }
        guard let oldest = reports.first(where: { now &- $0.nanos <= config.lossWindow }) ?? reports.last else { return }
        let expected = point.highest > oldest.highest ? point.highest - oldest.highest : 0
        // 只有一小段就下结论，一个包就是几十个百分点。
        if expected >= 20 {
            let received = point.packets > oldest.packets ? point.packets - oldest.packets : 0
            lossRate = expected > received ? Double(expected - received) / Double(expected) : 0
        } else if expected == 0, now &- oldest.nanos >= config.lossWindow / 2 {
            lossRate = 0
        }
        // 速率按相隔至少 100 ms 的两份报告算，太近的话一次突发就是个大得离谱的数。
        guard let base = reports.last(where: { now &- $0.nanos >= 100_000_000 }), now > base.nanos,
              point.bytes >= base.bytes else { return }
        let rate = Double(point.bytes - base.bytes) / (Double(now - base.nanos) / 1e9)
        rates.removeAll { now &- $0.nanos > config.deliveryWindow }
        rates.append(RateSample(nanos: now, rate: rate))
    }

    private mutating func adjust(now: UInt64) -> Bool {
        let wasBacklogged = backlogged
        backlogged = false
        let spacing = max(50_000_000, UInt64(smoothedTrip ?? 0))
        guard now &- lastAdjustment >= spacing else {
            backlogged = wasBacklogged
            return false
        }
        if lossRate >= config.heavyLoss {
            heavyLossSince = heavyLossSince ?? now
        } else {
            heavyLossSince = nil
        }
        let old = pacingRate
        if queueDelay > config.queueThreshold {
            // 瓶颈在排队：退到略低于实际送达的速率，把队列放空。
            let delivered = deliveryRate
            pacingRate = delivered > 0 ? min(pacingRate, delivered * config.backoff) : pacingRate * config.backoff
            foundCeiling = true
            // 这一轮的样本都是排着队量的，留着会连续误判。
            trips.removeAll()
            rates.removeAll()
        } else if let since = heavyLossSince, now &- since >= config.heavyLossHold {
            pacingRate *= config.backoff
            heavyLossSince = now
            foundCeiling = true
        } else if wasBacklogged {
            let grown = pacingRate * (foundCeiling ? config.probeGrowth : config.growth)
            // 还没有送达样本（刚开始）时不设限，有了就不能甩开它太多。
            let delivered = deliveryRate
            let limit = delivered > 0 ? delivered * config.deliveryHeadroom : grown
            pacingRate = max(pacingRate, min(grown, limit))
        }
        pacingRate = min(config.maxRate, max(config.minRate, pacingRate))
        lastAdjustment = now
        return pacingRate != old
    }
}

/// 视频的丢包策略：每一步该花多少换恢复能力。全是纯函数，测试直接穷举。
nonisolated enum RemoteLossPolicy {
    /// 多少个数据分片配一个纠错分片（XOR）。0 = 不纠错。
    ///
    /// 重传便宜（往返短）时不值得常驻开销，丢得多了再开；往返长时重传赶不上这一帧，宁可多花一点。
    static func fecGroupSize(lossRate: Double, roundTripNanos: UInt64?) -> Int {
        let roundTrip = roundTripNanos ?? 50_000_000
        if roundTrip < 20_000_000, lossRate < 0.05 { return 0 }
        switch lossRate {
        case ..<0.005: return 0
        case ..<0.02: return 16
        case ..<0.05: return 8
        case ..<0.10: return 5
        default: return 3
        }
    }

    /// 编码器该用目标码率的多少：纠错分片也要占带宽。
    static func mediaBudgetFactor(fecGroupSize: Int) -> Double {
        fecGroupSize > 0 ? Double(fecGroupSize) / Double(fecGroupSize + 1) : 1
    }

    /// 不管分片到得多慢，一帧最多等这么久。
    static let maxFrameWaitNanos: UInt64 = 1_500_000_000
    /// 编码码率最多占发送节奏的多少。留点余量给重传和终端，否则发送队列只涨不跌，延迟越排越长。
    static let linkShare = 0.9

    /// 接收端等一帧等多久（毫秒）：够它发完，再够两轮重传。等太久画面卡，太短动不动要恢复。
    static func frameDeadlineMillis(frameBytes: Int, roundTripNanos: UInt64?, pacingRate: Double) -> Int {
        let roundTrip = Double(roundTripNanos ?? 100_000_000) / 1e6
        let sending = Double(frameBytes) / max(1, pacingRate) * 1000
        return min(1500, Int(sending + roundTrip * 2 + 40))
    }

    /// 视频连续判丢多少帧算拥塞（一秒内）。零星丢一帧是突发丢包，恢复一下就好。
    static let lostFramesForCongestion = 3
}
