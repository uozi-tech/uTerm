import Foundation

// 公网直连时视频走数据报：一帧切成分片，丢了先靠纠错分片补，补不了请求重传，过了时限就放弃这一帧。
// 放弃之后参考链断了，由 Mac 发一个 LTR 刷新帧接上（见 `RemoteDesktopStreamer`），不用等关键帧那一大坨。
// 这里只有纯逻辑：时间由调用方传入，不碰网络，丢包场景可以确定地测。

/// 视频分片的包头。每个分片都带完整的帧信息，所以任意一片先到都知道这一帧长什么样。
nonisolated struct RemoteVideoPacketHeader: Equatable, Sendable {
    /// 桌面流的通道号。换流时对端靠它清掉旧状态。
    var channel: UInt32
    /// 流内连续递增，没有空洞（编码器丢掉的帧不占号），接收端靠它发现整帧都没到。
    var videoSequence: UInt32
    var totalBytes: UInt32
    var index: UInt16
    /// 多少个数据分片配一个纠错分片。0 = 没有。
    var fecGroupSize: UInt8
    /// 接收端从收到第一片起最多等多久。
    var deadlineMillis: UInt16
    /// 发送端测到的往返，接收端用它决定重传请求隔多久发一次。
    var roundTripMillis: UInt16

    static let encodedSize = 19

    func write(to writer: inout RemoteByteWriter) {
        writer.u32(channel)
        writer.u32(videoSequence)
        writer.u32(totalBytes)
        writer.u16(index)
        writer.u8(fecGroupSize)
        writer.u16(deadlineMillis)
        writer.u16(roundTripMillis)
    }

    init(channel: UInt32, videoSequence: UInt32, totalBytes: UInt32, index: UInt16, fecGroupSize: UInt8,
         deadlineMillis: UInt16, roundTripMillis: UInt16) {
        self.channel = channel
        self.videoSequence = videoSequence
        self.totalBytes = totalBytes
        self.index = index
        self.fecGroupSize = fecGroupSize
        self.deadlineMillis = deadlineMillis
        self.roundTripMillis = roundTripMillis
    }

    init(reading reader: inout RemoteByteReader) throws {
        channel = try reader.u32()
        videoSequence = try reader.u32()
        totalBytes = try reader.u32()
        index = try reader.u16()
        fecGroupSize = try reader.u8()
        deadlineMillis = try reader.u16()
        roundTripMillis = try reader.u16()
    }
}

/// 把一帧切成分片并生成纠错分片。
nonisolated enum RemoteVideoPacketizer {
    /// 1200（不易被分片的 UDP 载荷）− 25（加密开销）− 19（包头），留点余量。
    static let fragmentBytes = 1150

    static func fragmentCount(totalBytes: Int) -> Int {
        (totalBytes + fragmentBytes - 1) / fragmentBytes
    }

    static func parityCount(fragments: Int, groupSize: Int) -> Int {
        groupSize > 0 ? (fragments + groupSize - 1) / groupSize : 0
    }

    /// 返回完整的分片载荷（包头 + 内容），数据分片在前，纠错分片在后。
    static func packets(payload: Data, channel: UInt32, videoSequence: UInt32, fecGroupSize: Int, deadlineMillis: Int,
                        roundTripMillis: Int) -> [Data] {
        let count = fragmentCount(totalBytes: payload.count)
        var header = RemoteVideoPacketHeader(channel: channel, videoSequence: videoSequence,
                                             totalBytes: UInt32(payload.count), index: 0,
                                             fecGroupSize: UInt8(clamping: fecGroupSize),
                                             deadlineMillis: UInt16(clamping: deadlineMillis),
                                             roundTripMillis: UInt16(clamping: roundTripMillis))
        var result: [Data] = []
        result.reserveCapacity(count + parityCount(fragments: count, groupSize: fecGroupSize))
        func make(_ index: Int, _ body: some DataProtocol) -> Data {
            header.index = UInt16(index)
            var writer = RemoteByteWriter(capacity: RemoteVideoPacketHeader.encodedSize + body.count)
            header.write(to: &writer)
            writer.bytes(Data(body))
            return writer.data
        }
        let start = payload.startIndex
        for index in 0..<count {
            let lower = start + index * fragmentBytes
            let upper = min(payload.endIndex, lower + fragmentBytes)
            result.append(make(index, payload[lower..<upper]))
        }
        if fecGroupSize > 0 {
            for group in 0..<parityCount(fragments: count, groupSize: fecGroupSize) {
                var parity = [UInt8](repeating: 0, count: fragmentBytes)
                let first = group * fecGroupSize
                for index in first..<min(count, first + fecGroupSize) {
                    let lower = start + index * fragmentBytes
                    let upper = min(payload.endIndex, lower + fragmentBytes)
                    xor(payload[lower..<upper], into: &parity)
                }
                result.append(make(count + group, parity))
            }
        }
        return result
    }

    static func xor(_ data: some Collection<UInt8>, into target: inout [UInt8]) {
        var position = 0
        for byte in data {
            target[position] ^= byte
            position += 1
        }
    }
}

/// 视频重传请求：一帧缺哪些分片。`indices` 为 nil = 整帧都要（只知道它存在，一片都没收到）。
nonisolated struct RemoteVideoNack: Equatable, Sendable {
    var channel: UInt32
    var videoSequence: UInt32
    var indices: [UInt16]?

    private static let wholeFrame: UInt16 = .max
    /// 一个请求最多带多少个序号（放得进一个数据报）。
    static let maxIndices = 500

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: 10 + (indices?.count ?? 0) * 2)
        writer.u32(channel)
        writer.u32(videoSequence)
        if let indices {
            let limited = indices.prefix(Self.maxIndices)
            writer.u16(UInt16(limited.count))
            for index in limited { writer.u16(index) }
        } else {
            writer.u16(Self.wholeFrame)
        }
        return writer.data
    }

    init(channel: UInt32, videoSequence: UInt32, indices: [UInt16]?) {
        self.channel = channel
        self.videoSequence = videoSequence
        self.indices = indices
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        channel = try reader.u32()
        videoSequence = try reader.u32()
        let count = try reader.u16()
        if count == Self.wholeFrame {
            indices = nil
        } else {
            guard Int(count) <= Self.maxIndices else { throw RemoteProtocolError.malformedMessage }
            var list: [UInt16] = []
            for _ in 0..<count { list.append(try reader.u16()) }
            indices = list
        }
    }
}

/// 发送端留着最近发过的帧，等重传请求和确认。
nonisolated struct RemoteVideoSendBuffer {
    struct Limits: Equatable {
        var maxFrames = 256
        var maxBytes = 32 * 1024 * 1024
        /// 接收端最多等一帧 `RemoteLossPolicy.maxFrameWaitNanos`，在那之前还可能来要重传：多留一秒。
        var maxAgeNanos: UInt64 = RemoteLossPolicy.maxFrameWaitNanos + 1_000_000_000
    }

    private struct Frame {
        let videoSequence: UInt32
        let sequence: UInt32
        let packets: [Data]
        let dataCount: Int
        let sentNanos: UInt64
        let expiresNanos: UInt64
        var lastProbeNanos: UInt64
        var lastWholeResend: UInt64 = 0

        /// 只算原始载荷，和 `add` 里累加的一致。
        var byteCount: Int {
            packets.prefix(dataCount).reduce(0) { $0 + $1.count - RemoteVideoPacketHeader.encodedSize }
        }
    }

    let limits: Limits
    private var frames: [Frame] = []
    private var totalBytes = 0
    private var nextVideoSequence: UInt32 = 1

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    var isEmpty: Bool { frames.isEmpty }

    /// 切好一帧，返回要发的分片。
    mutating func add(payload: Data, sequence: UInt32, channel: UInt32, fecGroupSize: Int, deadlineMillis: Int,
                      roundTripMillis: Int, now: UInt64) -> [Data] {
        let videoSequence = nextVideoSequence
        nextVideoSequence &+= 1
        let packets = RemoteVideoPacketizer.packets(payload: payload, channel: channel, videoSequence: videoSequence,
                                                    fecGroupSize: fecGroupSize, deadlineMillis: deadlineMillis,
                                                    roundTripMillis: roundTripMillis)
        frames.append(Frame(videoSequence: videoSequence, sequence: sequence, packets: packets,
                            dataCount: RemoteVideoPacketizer.fragmentCount(totalBytes: payload.count),
                            sentNanos: now, expiresNanos: now &+ UInt64(deadlineMillis) * 1_000_000, lastProbeNanos: now))
        totalBytes += payload.count
        trim(now: now)
        return packets
    }

    /// 重传请求要的分片。这一帧已经不在了就什么也不发，接收端到时限自己放弃。
    mutating func packets(for nack: RemoteVideoNack, now: UInt64) -> [Data] {
        guard let position = frames.firstIndex(where: { $0.videoSequence == nack.videoSequence }) else { return [] }
        guard let indices = nack.indices else {
            guard now &- frames[position].lastWholeResend >= 50_000_000 else { return [] }
            frames[position].lastWholeResend = now
            return frames[position].packets
        }
        let packets = frames[position].packets
        return indices.compactMap { Int($0) < packets.count ? packets[Int($0)] : nil }
    }

    mutating func acknowledge(sequence: UInt32) {
        guard let position = frames.firstIndex(where: { $0.sequence == sequence }) else { return }
        totalBytes -= frames[position].byteCount
        frames.remove(at: position)
    }

    /// 接收端说这些帧放弃了。返回它们对应的编码序号（发送端的在途计数靠它释放）。
    mutating func markLost(videoSequences: [UInt32]) -> [UInt32] {
        var result: [UInt32] = []
        for videoSequence in videoSequences {
            guard let position = frames.firstIndex(where: { $0.videoSequence == videoSequence }) else { continue }
            result.append(frames[position].sequence)
            totalBytes -= frames[position].byteCount
            frames.remove(at: position)
        }
        return result
    }

    /// 尾部丢包探测：一帧的最后几片都丢了，接收端没有后续的包可以比对，发现不了。发出去超过一个往返还没
    /// 确认，就把最后一片再发一次，让接收端知道这一帧的存在和长度。
    mutating func probes(now: UInt64, roundTripNanos: UInt64) -> [Data] {
        var result: [Data] = []
        let wait = max(30_000_000, roundTripNanos + roundTripNanos / 4)
        for position in frames.indices where now &- frames[position].lastProbeNanos >= wait {
            guard now < frames[position].expiresNanos, let last = frames[position].packets.last else { continue }
            frames[position].lastProbeNanos = now
            result.append(frames[position].packets[frames[position].dataCount - 1])
            if frames[position].packets.count > frames[position].dataCount { result.append(last) }
        }
        return result
    }

    /// 过了时限还没人回话的帧：接收端多半已经放弃，或者连存在都不知道。返回编码序号，发送端按丢失处理。
    mutating func expire(now: UInt64, graceNanos: UInt64) -> [UInt32] {
        var result: [UInt32] = []
        frames.removeAll { frame in
            guard now > frame.expiresNanos &+ graceNanos else { return false }
            result.append(frame.sequence)
            totalBytes -= frame.byteCount
            return true
        }
        return result
    }

    private mutating func trim(now: UInt64) {
        while let oldest = frames.first,
              frames.count > limits.maxFrames || totalBytes > limits.maxBytes || now &- oldest.sentNanos > limits.maxAgeNanos {
            totalBytes -= oldest.byteCount
            frames.removeFirst()
        }
    }
}

/// 接收端把分片拼回帧。按 `videoSequence` 严格顺序交付：解码器跳不过缺的帧。
nonisolated struct RemoteVideoReassembler {
    struct Output: Equatable {
        /// 按顺序交给解码器的帧。
        var frames: [Data] = []
        var nacks: [RemoteVideoNack] = []
        /// 过了时限只能放弃的帧。
        var lost: [UInt32] = []
    }

    struct Counters: Equatable {
        var packets = 0
        var duplicates = 0
        var recoveredByFEC = 0
        var nackedPackets = 0
        var completedFrames = 0
        var lostFrames = 0
    }

    private struct Partial {
        var header: RemoteVideoPacketHeader
        var fragments: [Data?]
        var parities: [Data?]
        var firstArrival: UInt64
        var lastArrival: UInt64
        var highestIndex = 0
        var lastNack: [Int: UInt64] = [:]
        var received = 0

        /// 什么时候放弃。分片还在一片片到，说明它只是发得慢（节奏刚被压下去，或者排在别的帧后面），不算丢：
        /// 从最后一片算起再等够两轮重传。总时长封顶，解码器不能为一帧无限等下去。
        var deadline: UInt64 {
            let planned = firstArrival &+ UInt64(header.deadlineMillis) * 1_000_000
            let quiet = max(80_000_000, UInt64(header.roundTripMillis) * 2_000_000 + 40_000_000)
            let cap = firstArrival &+ RemoteLossPolicy.frameWaitCap(deadlineMillis: Int(header.deadlineMillis))
            return min(cap, max(planned, lastArrival &+ quiet))
        }
        var isComplete: Bool { received == fragments.count }
    }

    /// 一个分片后面的分片到了，这个分片等多久算丢（包会乱序）。
    static let reorderWaitNanos: UInt64 = 6_000_000
    /// 一帧在途最多拼多少帧：超出的是对端出错。
    static let maxPartialFrames = 128
    static let maxFrameBytes = UInt32(RemoteConstants.maxFrameBytes)

    private var channel: UInt32 = 0
    private var nextExpected: UInt32 = 1
    private var partials: [UInt32: Partial] = [:]
    /// 已知存在但一片都没收到的帧：比它新的帧到了才知道。值 = 判丢时刻。
    private var missing: [UInt32: UInt64] = [:]
    private var lastMissingNack: [UInt32: UInt64] = [:]
    private var highestSeen: UInt32 = 0
    private(set) var counters = Counters()

    var hasWork: Bool { !partials.isEmpty || !missing.isEmpty }
    /// 当前这条流的通道号（确认要发回这个通道）。
    var currentChannel: UInt32 { channel }

    /// 收到一个分片。
    mutating func receive(_ packet: Data, now: UInt64) -> Output {
        var output = Output()
        var reader = RemoteByteReader(packet)
        guard let header = try? RemoteVideoPacketHeader(reading: &reader), header.totalBytes > 0,
              header.totalBytes <= Self.maxFrameBytes else { return output }
        if header.channel != channel {
            // 换流了。旧流迟到的包通道号更小，不认。
            guard header.channel > channel else { return output }
            channel = header.channel
            partials = [:]
            missing = [:]
            lastMissingNack = [:]
            nextExpected = 1
            highestSeen = 0
        }
        counters.packets += 1
        let videoSequence = header.videoSequence
        guard videoSequence >= nextExpected else {
            counters.duplicates += 1
            return output
        }
        let body = packet[(packet.startIndex + RemoteVideoPacketHeader.encodedSize)...]
        if partials[videoSequence] == nil {
            guard partials.count < Self.maxPartialFrames else { return output }
            let count = RemoteVideoPacketizer.fragmentCount(totalBytes: Int(header.totalBytes))
            let parities = RemoteVideoPacketizer.parityCount(fragments: count, groupSize: Int(header.fecGroupSize))
            partials[videoSequence] = Partial(header: header, fragments: Array(repeating: nil, count: count),
                                              parities: Array(repeating: nil, count: parities),
                                              firstArrival: now, lastArrival: now)
            missing[videoSequence] = nil
        }
        // 比它旧、没见过的帧：整帧都没到。
        if videoSequence > highestSeen {
            var cursor = max(highestSeen &+ 1, nextExpected)
            while cursor < videoSequence {
                if partials[cursor] == nil { missing[cursor] = now &+ UInt64(header.deadlineMillis) * 1_000_000 }
                cursor &+= 1
            }
            highestSeen = videoSequence
        }
        guard var partial = partials[videoSequence] else { return output }
        partial.lastArrival = now
        let index = Int(header.index)
        partial.highestIndex = max(partial.highestIndex, min(index, partial.fragments.count - 1))
        if index < partial.fragments.count {
            let expected = Self.fragmentSize(index: index, header: header, count: partial.fragments.count)
            if partial.fragments[index] != nil {
                counters.duplicates += 1
            } else if body.count == expected {
                partial.fragments[index] = Data(body)
                partial.received += 1
            }
        } else if index - partial.fragments.count < partial.parities.count, body.count == RemoteVideoPacketizer.fragmentBytes {
            partial.parities[index - partial.fragments.count] = Data(body)
        }
        recoverWithParity(&partial)
        partials[videoSequence] = partial
        deliver(into: &output, now: now)
        return output
    }

    /// 定时调用：发重传请求、放弃过期的帧。
    mutating func tick(now: UInt64) -> Output {
        var output = Output()
        for videoSequence in partials.keys.sorted() {
            guard var partial = partials[videoSequence], !partial.isComplete, now < partial.deadline else { continue }
            let wait = max(Self.reorderWaitNanos, UInt64(partial.header.roundTripMillis) * 1_000_000 / 4)
            let retry = max(10_000_000, UInt64(partial.header.roundTripMillis) * 1_250_000)
            let tailQuiet = now &- partial.lastArrival >= wait
            var indices: [UInt16] = []
            for index in partial.fragments.indices where partial.fragments[index] == nil {
                guard (index < partial.highestIndex && now &- partial.lastArrival >= Self.reorderWaitNanos) || tailQuiet,
                      now &- (partial.lastNack[index] ?? 0) >= retry else { continue }
                partial.lastNack[index] = now
                indices.append(UInt16(index))
            }
            if !indices.isEmpty {
                counters.nackedPackets += indices.count
                output.nacks.append(RemoteVideoNack(channel: channel, videoSequence: videoSequence, indices: indices))
            }
            partials[videoSequence] = partial
        }
        for (videoSequence, deadline) in missing where now < deadline {
            let last = lastMissingNack[videoSequence] ?? 0
            guard now &- last >= 30_000_000 else { continue }
            lastMissingNack[videoSequence] = now
            output.nacks.append(RemoteVideoNack(channel: channel, videoSequence: videoSequence, indices: nil))
        }
        deliver(into: &output, now: now)
        return output
    }

    /// 同一组里只缺一个数据分片、纠错分片到了：异或补回来。
    private mutating func recoverWithParity(_ partial: inout Partial) {
        let groupSize = Int(partial.header.fecGroupSize)
        guard groupSize > 0, !partial.isComplete else { return }
        for group in partial.parities.indices {
            guard let parity = partial.parities[group] else { continue }
            let first = group * groupSize
            let range = first..<min(partial.fragments.count, first + groupSize)
            let absent = range.filter { partial.fragments[$0] == nil }
            guard absent.count == 1, let target = absent.first else { continue }
            var bytes = [UInt8](parity)
            for index in range where index != target {
                if let fragment = partial.fragments[index] { RemoteVideoPacketizer.xor(fragment, into: &bytes) }
            }
            let size = Self.fragmentSize(index: target, header: partial.header, count: partial.fragments.count)
            partial.fragments[target] = Data(bytes.prefix(size))
            partial.received += 1
            counters.recoveredByFEC += 1
        }
    }

    private static func fragmentSize(index: Int, header: RemoteVideoPacketHeader, count: Int) -> Int {
        guard index == count - 1 else { return RemoteVideoPacketizer.fragmentBytes }
        let remainder = Int(header.totalBytes) % RemoteVideoPacketizer.fragmentBytes
        return remainder == 0 ? RemoteVideoPacketizer.fragmentBytes : remainder
    }

    /// 从 `nextExpected` 起能交就交，队头过期就判丢、接着往后。
    private mutating func deliver(into output: inout Output, now: UInt64) {
        while nextExpected <= highestSeen {
            if let partial = partials[nextExpected] {
                if partial.isComplete {
                    var frame = Data(capacity: Int(partial.header.totalBytes))
                    for fragment in partial.fragments {
                        if let fragment { frame.append(fragment) }
                    }
                    output.frames.append(frame)
                    counters.completedFrames += 1
                } else if now >= partial.deadline {
                    output.lost.append(nextExpected)
                    counters.lostFrames += 1
                } else {
                    return
                }
                partials[nextExpected] = nil
            } else if let deadline = missing[nextExpected] {
                guard now >= deadline else { return }
                missing[nextExpected] = nil
                lastMissingNack[nextExpected] = nil
                output.lost.append(nextExpected)
                counters.lostFrames += 1
            }
            nextExpected &+= 1
        }
    }
}
