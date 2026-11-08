import Foundation

/// 链路层的排队与端到端计量（调研 §16.5）。两端都声明 `link-flow` 才启用；纯值类型，`RemoteLink` 在自己的队列上驱动它。
///
/// 为什么要它：TCP 路径上（局域网、中继）每条消息原来是整段直接交给网络栈的。视频的在途上限按「交给网络栈」算，
/// 到了中继上这些字节全堵在 TCP 和中继的缓冲里，后来的声音、按键、确认都得排在它们后面。Mac 本机的 TCP 读数看不见
/// 中继里的积压（§16.2：中继读得很积极，数据堆在它发给手机的那段），所以计量必须端到端：
///
/// - **端到端计量**：收方每收 16 KB 或每 20 ms 回一个 `linkAck`（累计收到的链路字节数）。发方由此知道「发出去了但
///   对端还没收到」的字节（含中继里的积压）、送达速率与最小往返。
/// - **闸门**：只有在途 ≤ 送达速率 × (最小往返 + 30 ms) × 1.25（至少 64 KB）时才交新数据给网络栈，其余留在这里排队。
///   紧急消息（声音、确认、光标、心跳、桌面开流）不过闸门：它们很小，而且最怕排队。
/// - **分级与分片**：紧急消息一个 FIFO，最先发；其余按通道各一个 FIFO（同一通道内保序，终端的输出与关闭、
///   粘贴与之后的按键都不会颠倒），通道之间轮转。超过 16 KB 的消息切成片，一帧视频不再独占链路。
///
/// 送达速率取最近 2 s 的最大值、最小往返取最近 10 s 的最小值（BBR 的做法）。闸门偏紧时送达速率被闸门本身限住，
/// 下一轮的预算是它的 (1 + 30 ms / 往返) × 1.25 倍，所以会一轮轮涨到链路真正的上限，不会自己把自己锁死。
nonisolated struct RemoteLinkFlow {
    struct Config: Equatable, Sendable {
        /// 大于这个的消息切片。
        var fragmentBytes = 16 * 1024
        /// 在途预算的下限：局域网往返 1 ms 时速率估计会很小，太紧会让一帧视频要分好几轮才发完。
        var minimumBudget = 64 * 1024
        /// 还没有任何读数时的预算。
        var initialBudget = 256 * 1024
        /// 允许在链路里排队的时长。
        var queueSlackNanos: UInt64 = 30_000_000
        var gain = 1.25
        var rateWindowNanos: UInt64 = 2_000_000_000
        var roundTripWindowNanos: UInt64 = 10_000_000_000
        /// 收方：收到这么多字节就立刻回一个 `linkAck`。
        var ackBytes = 16 * 1024
        /// 收方：最多攒这么久就回。
        var ackDelayNanos: UInt64 = 20_000_000

        static let standard = Config()
    }

    /// 交给链路去封装、加密、发出的一条记录：一条完整消息或其中一片。
    struct Record: Equatable, Sendable {
        var message: RemoteMessage
        /// 原消息的最后一片（或整条）带着它；链路在这条记录交出去之后回调原消息的完成。
        var token: Int?
    }

    /// 收方收到一条记录后要不要回 `linkAck`。
    enum AckDecision: Equatable, Sendable {
        case none
        case now
        /// 到这个时刻还没回过就回（已经约过就不再约）。
        case at(UInt64)
    }

    let config: Config

    init(config: Config = .standard) {
        self.config = config
    }

    /// 不过闸门、最先发的消息：小，且怕排队。顺序上它们彼此保序，但会越过普通消息。
    ///
    /// `desktopStarted` 也算：手机靠它绑定桌面通道，之后的光标、延迟这些紧急消息要是越过它先到，会因为通道还没绑定
    /// 被丢掉（光标去重，鼠标不动就不会重发）。它排进紧急队列后，紧急消息之间保序，普通消息本来就在紧急之后。
    static func isUrgent(_ kind: RemoteMessage.Kind) -> Bool {
        switch kind {
        case .ping, .pong, .desktopAck, .desktopCursor, .desktopLatency, .desktopKeyframe, .desktopVideoLost,
             .desktopStarted, .desktopAudio, .desktopAudioFormat, .desktopAudioFrame:
            return true
        default:
            return false
        }
    }

    // MARK: - 发方

    private struct Pending {
        var message: RemoteMessage
        var token: Int?
        /// 分片时才编码；整条发的消息不必先编码一遍。
        var encoded: Data?
        var offset = 0

        var size: Int { RemoteMessage.headerSize + message.payload.count }
        var remaining: Int { size - offset }
    }

    private var urgent: [Pending] = []
    private var urgentHead = 0
    private var lanes: [UInt32: [Pending]] = [:]
    /// 通道的轮转顺序。
    private var order: [UInt32] = []
    private var cursor = 0

    /// 已经交给网络栈的字节（不含 `linkAck` 自己）。
    private(set) var sentBytes: UInt64 = 0
    /// 对端报来的累计收到字节。
    private(set) var peerReceivedBytes: UInt64 = 0
    /// 往返采样点：发到第多少字节时的时刻。
    private var checkpoints: [(bytes: UInt64, nanos: UInt64)] = []
    private var roundTrips: [(nanos: UInt64, value: UInt64)] = []
    private var acks: [(nanos: UInt64, bytes: UInt64)] = []
    private var rates: [(nanos: UInt64, value: Double)] = []

    var inPipe: Int { Int(sentBytes &- peerReceivedBytes) }

    var hasQueued: Bool { urgentHead < urgent.count || lanes.values.contains { !$0.isEmpty } }

    /// 排着、还没交给网络栈的字节。
    var queuedBytes: Int {
        urgent[urgentHead...].reduce(0) { $0 + $1.remaining }
            + lanes.values.reduce(0) { total, lane in total + lane.reduce(0) { $0 + $1.remaining } }
    }

    var minimumRoundTripNanos: UInt64? { roundTrips.map(\.value).min() }
    /// 字节 / 秒。
    var deliveryRate: Double? { rates.map(\.value).max() }

    /// 闸门：在途超过它就不再交普通消息。
    var budget: Int {
        guard let rate = deliveryRate, let trip = minimumRoundTripNanos else { return config.initialBudget }
        let seconds = Double(trip + config.queueSlackNanos) / 1e9
        return max(config.minimumBudget, Int(rate * seconds * config.gain))
    }

    mutating func enqueue(_ message: RemoteMessage, token: Int?) {
        let pending = Pending(message: message, token: token)
        if Self.isUrgent(message.kind) {
            urgent.append(pending)
            return
        }
        if lanes[message.channel] == nil { order.append(message.channel) }
        lanes[message.channel, default: []].append(pending)
    }

    /// 下一条该交出去的记录；被闸门拦住或没东西时 nil。
    mutating func next() -> Record? {
        if urgentHead < urgent.count {
            let pending = urgent[urgentHead]
            urgentHead += 1
            if urgentHead == urgent.count {
                urgent.removeAll(keepingCapacity: true)
                urgentHead = 0
            }
            return Record(message: pending.message, token: pending.token)
        }
        guard inPipe < budget, !order.isEmpty else { return nil }
        for _ in 0..<order.count {
            cursor %= order.count
            let channel = order[cursor]
            guard var lane = lanes[channel], !lane.isEmpty else {
                lanes[channel] = nil
                order.remove(at: cursor)
                if order.isEmpty { return nil }
                continue
            }
            cursor += 1
            var head = lane[0]
            let record: Record
            if head.offset == 0 && head.size <= config.fragmentBytes {
                record = Record(message: head.message, token: head.token)
                lane.removeFirst()
            } else {
                let bytes = head.encoded ?? head.message.encoded()
                head.encoded = bytes
                let end = min(bytes.count, head.offset + config.fragmentBytes)
                let last = end == bytes.count
                let fragment = RemoteLinkFragment(channel: head.message.channel, last: last,
                                                  bytes: bytes[(bytes.startIndex + head.offset)..<(bytes.startIndex + end)])
                record = Record(message: RemoteMessage(.linkFragment, payload: fragment.encoded()),
                                token: last ? head.token : nil)
                head.offset = end
                if last { lane.removeFirst() } else { lane[0] = head }
            }
            lanes[channel] = lane
            return record
        }
        return nil
    }

    /// 一条记录（不是 `linkAck`）交给网络栈了。`bytes` = 封装加密后的帧长。
    mutating func recordSent(bytes: Int, now: UInt64) {
        sentBytes &+= UInt64(bytes)
        // 每 10 ms 最多一个往返采样点，够用且不攒一大串。
        if checkpoints.last.map({ now &- $0.nanos >= 10_000_000 }) ?? true {
            checkpoints.append((sentBytes, now))
            if checkpoints.count > 512 { checkpoints.removeFirst(checkpoints.count - 512) }
        }
    }

    /// 对端报来累计收到的字节。
    mutating func receiveAck(_ total: UInt64, now: UInt64) {
        guard total > peerReceivedBytes, total <= sentBytes else { return }
        peerReceivedBytes = total
        // 往返：最晚一个已被覆盖的采样点。
        if let index = checkpoints.lastIndex(where: { $0.bytes <= total }) {
            roundTrips.append((now, now &- checkpoints[index].nanos))
            checkpoints.removeFirst(index + 1)
        }
        roundTrips.removeAll { now &- $0.nanos > config.roundTripWindowNanos }
        // 送达速率：和至少一个往返（且至少 40 ms）之前的那次确认比。
        acks.append((now, total))
        let span = max(minimumRoundTripNanos ?? 0, 40_000_000)
        if let base = acks.last(where: { now &- $0.nanos >= span }) {
            let rate = Double(total - base.bytes) / (Double(now &- base.nanos) / 1e9)
            rates.append((now, rate))
        }
        acks.removeAll { now &- $0.nanos > config.rateWindowNanos }
        rates.removeAll { now &- $0.nanos > config.rateWindowNanos }
    }

    // MARK: - 收方

    /// 收到的链路字节（不含 `linkAck`）。
    private(set) var receivedBytes: UInt64 = 0
    private var ackedBytes: UInt64 = 0
    private var ackDue: UInt64?
    private var assembling: [UInt32: Data] = [:]

    /// 收到一条记录（不是 `linkAck`）。`bytes` = 帧长，与发方的 `recordSent` 同一口径。
    mutating func recordReceived(bytes: Int, now: UInt64) -> AckDecision {
        receivedBytes &+= UInt64(bytes)
        if receivedBytes - ackedBytes >= UInt64(config.ackBytes) { return .now }
        if ackDue != nil { return .none }
        let due = now &+ config.ackDelayNanos
        ackDue = due
        return .at(due)
    }

    /// 要回的 `linkAck` 值；没有新收到的就 nil。
    mutating func takeAck() -> UInt64? {
        ackDue = nil
        guard receivedBytes > ackedBytes else { return nil }
        ackedBytes = receivedBytes
        return receivedBytes
    }

    /// 收到一片：拼齐了返回原消息。
    mutating func reassemble(_ payload: Data) throws -> RemoteMessage? {
        let fragment = try RemoteLinkFragment(decoding: payload)
        var buffer = assembling[fragment.channel] ?? Data()
        buffer.append(fragment.bytes)
        guard buffer.count <= RemoteConstants.maxFrameBytes else { throw RemoteProtocolError.frameTooLarge(buffer.count) }
        guard fragment.last else {
            assembling[fragment.channel] = buffer
            return nil
        }
        assembling[fragment.channel] = nil
        return try RemoteMessage(decoding: buffer)
    }
}

/// 一片：`[u8 标志（bit0 = 最后一片）][u32 原消息的通道][片]`。同一通道同时只有一条消息在分片。
nonisolated struct RemoteLinkFragment: Equatable, Sendable {
    var channel: UInt32
    var last: Bool
    var bytes: Data

    init(channel: UInt32, last: Bool, bytes: some DataProtocol) {
        self.channel = channel
        self.last = last
        self.bytes = Data(bytes)
    }

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: 5 + bytes.count)
        writer.u8(last ? 1 : 0)
        writer.u32(channel)
        writer.bytes(bytes)
        return writer.data
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        last = try reader.u8() & 1 == 1
        channel = try reader.u32()
        bytes = reader.rest()
        guard !bytes.isEmpty else { throw RemoteProtocolError.malformedMessage }
    }
}

/// `linkAck` 的负载：`[u64 累计收到的链路字节]`。
nonisolated enum RemoteLinkAck {
    static func encode(_ total: UInt64) -> Data {
        var writer = RemoteByteWriter(capacity: 8)
        writer.u64(total)
        return writer.data
    }

    static func decode(_ payload: Data) throws -> UInt64 {
        var reader = RemoteByteReader(payload)
        return try reader.u64()
    }
}
