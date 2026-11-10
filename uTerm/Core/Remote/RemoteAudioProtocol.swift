import AudioToolbox
import Foundation

// 远程桌面的声音（调研 §17）。两端共用。
//
// 声音挂在桌面流上：消息走桌面那条通道，手机看桌面时才有。开关、格式这种低频的用 JSON；
// 每 20 ms 一包的音频帧用定长大端二进制。

/// 声音的编码。开流时手机列出自己能解的，Mac 挑第一个自己也能编的（无损另由链路条件决定，见 `RemoteAudioPolicy`）。
///
/// 老 Mac 解这个列表时遇到不认识的值会整条请求解不开，所以手机只对声明了 `desktopAudioLossless` 的 Mac 列 `alac`
///（`RemoteDesktopAudioRequest.codecs(lossless:)`）。
nonisolated enum RemoteAudioCodec: String, Codable, Sendable, CaseIterable {
    case opus
    /// 退路：两端 AudioToolbox 肯定都有。
    case aacELD
    /// 无损（Apple Lossless，16-bit，352 采样一包 ≈ 7.3 ms）：只在宽裕、不丢包的链路上用。
    case alac

    var formatID: AudioFormatID {
        switch self {
        case .opus: return kAudioFormatOpus
        case .aacELD: return kAudioFormatMPEG4AAC_ELD
        case .alac: return kAudioFormatAppleLossless
        }
    }

    /// 默认每包多少采样（48 kHz 下 Opus 20 ms = 960；AAC-ELD 固定 512；ALAC 只有 4096 或 352 两档可选，取短的）。
    var framesPerPacket: UInt32 {
        switch self {
        case .opus: return 960
        case .aacELD: return 512
        case .alac: return 352
        }
    }
}

/// 手机 → Mac：打开 / 关闭声音（`desktopAudio`，桌面通道）。看桌面途中随时可发，不用重开视频。
nonisolated struct RemoteDesktopAudioRequest: Codable, Equatable, Sendable {
    var enabled: Bool
    /// 手机能解的编码，按偏好排。
    var codecs: [RemoteAudioCodec] = Self.codecs(lossless: false)

    /// 要列的编码：Mac 声明了 `desktopAudioLossless` 才带上无损（见 `RemoteAudioCodec`）。
    static func codecs(lossless: Bool) -> [RemoteAudioCodec] {
        lossless ? [.opus, .aacELD, .alac] : [.opus, .aacELD]
    }
}

/// Mac → 手机：这条声音流的格式（`desktopAudioFormat`，桌面通道）。每次开始送声音都先发一条；
/// 之后的音频帧按它解。声音被关掉（Mac 上关了开关、采集起不来）时 `codec` 为 nil，`message` 说明原因。
nonisolated struct RemoteDesktopAudioFormat: Codable, Equatable, Sendable {
    /// 每开一次声音流 +1。手机见到新的 `stream` 就重建解码器、清空缓冲：序号从头算。
    var stream: UInt16
    var codec: RemoteAudioCodec?
    var sampleRate: Double = 48_000
    var channels: UInt32 = 2
    var framesPerPacket: UInt32 = 960
    /// 编码器的 magic cookie（AAC 要，Opus 可以没有）。
    var magicCookie: Data? = nil
    /// 声音没开起来时给人看的原因。
    var message: String? = nil
}

/// 一包声音（`desktopAudioFrame`）：
/// `[u8 标志][u16 流][u32 序号][u64 首个采样的 Mac 采集时刻 ns][u16 长度][数据]`
/// + 带冗余时 `[u8 个数]{[u16 长度][数据]}`：依次是序号 −1、−2 的那几包（丢包链路上补洞用）。
///
/// 静音时 Mac 停发，只隔一阵发一个带 `silence`、没有数据的包：手机据此知道不是丢了，不必等。
nonisolated struct RemoteDesktopAudioFrame: Equatable, Sendable {
    struct Flags: OptionSet, Sendable, Equatable {
        let rawValue: UInt8
        /// 这一段是静音，没有数据。
        static let silence = Flags(rawValue: 1 << 0)
        /// 带了前面几包的冗余。
        static let redundancy = Flags(rawValue: 1 << 1)
    }

    var flags: Flags
    var stream: UInt16
    var sequence: UInt32
    var captureNanos: UInt64
    var data: Data
    /// 序号 −1、−2… 的包（按这个顺序），已经有冗余时才有。
    var redundant: [Data] = []

    static let headerSize = 17

    var isSilence: Bool { flags.contains(.silence) }

    init(flags: Flags = [], stream: UInt16, sequence: UInt32, captureNanos: UInt64, data: Data, redundant: [Data] = []) {
        self.flags = redundant.isEmpty ? flags.subtracting(.redundancy) : flags.union(.redundancy)
        self.stream = stream
        self.sequence = sequence
        self.captureNanos = captureNanos
        self.data = data
        self.redundant = redundant
    }

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: Self.headerSize + data.count + redundant.reduce(1) { $0 + 2 + $1.count })
        writer.u8(flags.rawValue)
        writer.u16(stream)
        writer.u32(sequence)
        writer.u64(captureNanos)
        writer.u16(UInt16(data.count))
        writer.bytes(data)
        if flags.contains(.redundancy) {
            writer.u8(UInt8(redundant.count))
            for packet in redundant {
                writer.u16(UInt16(packet.count))
                writer.bytes(packet)
            }
        }
        return writer.data
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        flags = Flags(rawValue: try reader.u8())
        stream = try reader.u16()
        sequence = try reader.u32()
        captureNanos = try reader.u64()
        data = try reader.bytes(Int(try reader.u16()))
        if flags.contains(.redundancy) {
            let count = Int(try reader.u8())
            var packets: [Data] = []
            for _ in 0..<count { packets.append(try reader.bytes(Int(try reader.u16()))) }
            redundant = packets
        }
        guard flags.contains(.silence) || !data.isEmpty else { throw RemoteProtocolError.malformedMessage }
    }
}

/// 这条声音流眼下用什么编：编码、码率、一包多长。换编码或包长要重建编码器、发新格式（手机重建解码器），
/// 只改码率不用。
nonisolated enum RemoteAudioProfile: Equatable, Sendable {
    case opus(bitrate: Int, frameMillis: Int)
    case lossless

    var codec: RemoteAudioCodec { self == .lossless ? .alac : .opus }

    var framesPerPacket: UInt32 {
        switch self {
        case .opus(_, let frameMillis): return UInt32(frameMillis) * 48
        case .lossless: return RemoteAudioCodec.alac.framesPerPacket
        }
    }

    var bitrate: Int? {
        if case .opus(let bitrate, _) = self { return bitrate }
        return nil
    }

    /// 两档之间要不要重建编码器（码率不同不用）。
    func needsNewEncoder(from other: RemoteAudioProfile) -> Bool {
        codec != other.codec || framesPerPacket != other.framesPerPacket
    }

    /// 档位高低（升档要等、降档立刻，按这个比）。
    var rank: Int {
        switch self {
        case .opus(let bitrate, _): return bitrate
        case .lossless: return Int.max
        }
    }
}

/// 声音的码率与冗余怎么定。纯函数，两端都用。
nonisolated enum RemoteAudioPolicy {
    /// 采样率与声道：Mac 的系统声音按这个采，Opus 按这个编。
    static let sampleRate: Double = 48_000
    static let channels: UInt32 = 2

    /// 声音最多占链路容量的多少：画面要紧，声音让着它（a7 的码控给编码器留了 10% 余量，声音在这里面）。
    static let maxShare = 0.05
    /// 最低码率：链路再差，语音、提示音也要听得清。
    static let floorBitrate = 32_000
    /// Opus 各档（立体声）。实测 Apple 的编码器是 VBR，实际码率约为设定值的 86–93%。
    static let opusTiers = [64_000, 128_000, 256_000, 384_000]
    /// 有过丢包、退出无损时用的 Opus 上限。
    static let opusMax = 510_000
    /// 这个码率及以上、走数据报时一包 10 ms：20 ms 一包会超过数据报上限（384 kbps 约 1 KB），带不了冗余。
    static let shortFrameFromBitrate = 384_000
    /// 中继（TCP 转发）给的固定码率：拿不到链路容量，中继上行常常只有几 Mbps。
    static let relayBitrate = 256_000
    /// 无损要的链路容量与丢包上限。
    static let losslessCapacity = 40_000_000.0
    static let losslessMaxLoss = 0.001
    /// 一个声音包（`RemoteDesktopAudioFrame` 编码后）在数据报路径上最多多大：1200 的数据报扣掉加密、通道号与包头。
    static let datagramPayloadLimit = 1100

    /// 链路眼下的情况（声音发送端每发一批包看一次）。
    struct Link: Equatable, Sendable {
        enum Path: Equatable, Sendable {
            /// 局域网 TCP：没有发送节奏，用画面码控的目标码率估容量。
            case localNetwork
            /// 公网直连（数据报）：有发送节奏与丢包率。
            case direct
            /// 中继转发（TCP）。
            case relay
        }

        var path: Path
        /// 链路容量估计（比特 / 秒）：直连是发送节奏，局域网是画面码控的目标码率；不知道为 nil。
        var capacity: Double?
        var lossRate: Double = 0
        /// 手机能解无损（列了 `alac`）。
        var peerDecodesLossless = false
    }

    /// 这条链路该用哪一档（不含升档的等待，见 `RemoteAudioTierSelector`）。
    ///
    /// 码率取不超过容量 5% 的最高一档：64k 要 ≥ 1.28 Mbps、128k ≥ 2.56、256k ≥ 5.12、384k ≥ 7.68
    ///（即「≥ 8 Mbps 上 384k」）；不够 64k 时取 max(`floorBitrate`, 5%)。无损只在容量 ≥ 40 Mbps、丢包 < 0.1%、手机能解时用；够格却有丢包时退到 Opus 510k。
    static func profile(for link: Link) -> RemoteAudioProfile {
        if link.path == .relay { return .opus(bitrate: relayBitrate, frameMillis: 20) }
        guard let capacity = link.capacity else { return .opus(bitrate: relayBitrate, frameMillis: 20) }
        let datagrams = link.path == .direct
        if capacity >= losslessCapacity, link.peerDecodesLossless {
            if link.lossRate < losslessMaxLoss { return .lossless }
            return .opus(bitrate: opusMax, frameMillis: datagrams ? 10 : 20)
        }
        let budget = capacity * maxShare
        let bitrate = opusTiers.last(where: { Double($0) <= budget }) ?? max(floorBitrate, Int(budget))
        return .opus(bitrate: bitrate, frameMillis: datagrams && bitrate >= shortFrameFromBitrate ? 10 : 20)
    }

    /// 每包带几个前面的包当冗余。声音包很小（64 kbps 约 160 B），多带一份几乎不占带宽，
    /// 却能在不等往返的情况下补上单个丢包；重传回来的包已经赶不上播放，所以不做重传。
    static func redundancy(lossRate: Double) -> Int {
        switch lossRate {
        case ..<0.005: return 0
        case ..<0.05: return 1
        default: return 2
        }
    }

    /// 静音判定：峰值低于 −60 dBFS。
    static let silenceThreshold: Float = 0.001
    /// 连续静音这么久才停发：短暂停顿（说话的换气、两个音之间）不切，免得开头被吃掉。
    static let silenceHoldNanos: UInt64 = 200_000_000
    /// 停发期间每隔这么久发一个静音包，手机据此知道链路还在、不是丢了。
    static let silenceHeartbeatNanos: UInt64 = 1_000_000_000
}

/// 档位的升降：降档立刻（链路变差时声音先让），升档要连续 `upgradeHoldNanos` 都够格（免得在两档之间来回切；
/// 换编码或包长时手机要重建解码器、重新缓冲一下）。开流时从不高于 256k 的一档起步，够格再往上升。
///
/// 无损另加退避：丢包率在 0.1% 上下晃时会在无损和 Opus 510k 之间每十几秒切一次（2026-11-09 真机实测），
/// 每次都要重建解码器、断一下声。所以每从无损掉下来一次，回无损要等的时间翻倍（5 → 10 → 20 … 最多 2 分钟）；
/// 在无损上稳住 2 分钟后清零。
nonisolated struct RemoteAudioTierSelector: Equatable, Sendable {
    static let upgradeHoldNanos: UInt64 = 5_000_000_000
    static let losslessHoldCapNanos: UInt64 = 120_000_000_000
    /// 在无损上连续待这么久，退避清零。
    static let losslessSettleNanos: UInt64 = 120_000_000_000
    static let startCap = RemoteAudioProfile.opus(bitrate: 256_000, frameMillis: 20)

    private(set) var current: RemoteAudioProfile
    private var upgradeSince: UInt64?
    /// 从无损掉下来的次数（退避指数）。
    private var losslessDrops = 0
    /// 这次进入无损的时间。
    private var losslessSince: UInt64?

    init(initial wanted: RemoteAudioProfile) {
        current = wanted.rank <= Self.startCap.rank ? wanted : Self.startCap
    }

    /// 升到 `wanted` 要连续够格多久。
    func requiredHold(for wanted: RemoteAudioProfile) -> UInt64 {
        guard wanted == .lossless, losslessDrops > 0 else { return Self.upgradeHoldNanos }
        let shift = UInt64(min(losslessDrops, 8))
        return min(Self.upgradeHoldNanos << shift, Self.losslessHoldCapNanos)
    }

    /// 喂一次眼下该用的档。返回 true = 档位变了（调用方按 `current` 调码率或重建编码器）。
    mutating func update(_ wanted: RemoteAudioProfile, now: UInt64) -> Bool {
        if current == .lossless, let since = losslessSince, now &- since >= Self.losslessSettleNanos {
            losslessDrops = 0
        }
        if wanted.rank < current.rank || (wanted.rank == current.rank && wanted != current) {
            switchTo(wanted, now: now)
            return true
        }
        guard wanted.rank > current.rank else {
            upgradeSince = nil
            return false
        }
        guard let since = upgradeSince else {
            upgradeSince = now
            return false
        }
        guard now &- since >= requiredHold(for: wanted) else { return false }
        switchTo(wanted, now: now)
        return true
    }

    private mutating func switchTo(_ wanted: RemoteAudioProfile, now: UInt64) {
        if current == .lossless, wanted != .lossless { losslessDrops += 1 }
        losslessSince = wanted == .lossless ? now : nil
        current = wanted
        upgradeSince = nil
    }
}

/// 手机记住每台 Mac 要不要声音（远程桌面工具栏上的扬声器按钮），下次看这台 Mac 时照样打开。只在本机，不同步。
nonisolated enum RemoteDesktopAudioPreference {
    static func wantsAudio(mac: UUID, defaults: UserDefaults = RemoteLocalState.defaults) -> Bool {
        (defaults.stringArray(forKey: DefaultsKey.remoteDesktopAudioMacs) ?? []).contains(mac.uuidString)
    }

    static func setWantsAudio(_ on: Bool, mac: UUID, defaults: UserDefaults = RemoteLocalState.defaults) {
        var macs = Set(defaults.stringArray(forKey: DefaultsKey.remoteDesktopAudioMacs) ?? [])
        if on { macs.insert(mac.uuidString) } else { macs.remove(mac.uuidString) }
        defaults.set(macs.sorted(), forKey: DefaultsKey.remoteDesktopAudioMacs)
    }
}
