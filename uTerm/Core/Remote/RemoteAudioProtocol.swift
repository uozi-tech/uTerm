import AudioToolbox
import Foundation

// 远程桌面的声音（调研 §17）。两端共用。
//
// 声音挂在桌面流上：消息走桌面那条通道，手机看桌面时才有。开关、格式这种低频的用 JSON；
// 每 20 ms 一包的音频帧用定长大端二进制。

/// 声音的编码。开流时手机列出自己能解的，Mac 挑第一个自己也能编的。
nonisolated enum RemoteAudioCodec: String, Codable, Sendable, CaseIterable {
    case opus
    /// 退路：两端 AudioToolbox 肯定都有。
    case aacELD

    var formatID: AudioFormatID {
        switch self {
        case .opus: return kAudioFormatOpus
        case .aacELD: return kAudioFormatMPEG4AAC_ELD
        }
    }

    /// 每包多少采样（48 kHz 下 Opus 20 ms = 960；AAC-ELD 固定 512）。
    var framesPerPacket: UInt32 {
        switch self {
        case .opus: return 960
        case .aacELD: return 512
        }
    }
}

/// 手机 → Mac：打开 / 关闭声音（`desktopAudio`，桌面通道）。看桌面途中随时可发，不用重开视频。
nonisolated struct RemoteDesktopAudioRequest: Codable, Equatable, Sendable {
    var enabled: Bool
    /// 手机能解的编码，按偏好排。
    var codecs: [RemoteAudioCodec] = RemoteAudioCodec.allCases
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

/// 声音的码率与冗余怎么定。纯函数，两端都用。
nonisolated enum RemoteAudioPolicy {
    /// 采样率与声道：Mac 的系统声音按这个采，Opus 按这个编。
    static let sampleRate: Double = 48_000
    static let channels: UInt32 = 2
    /// 平常的码率：立体声音乐够用。
    static let normalBitrate = 64_000
    /// 链路很差时：语音、提示音仍听得清。
    static let lowBitrate = 32_000
    /// 发送节奏（字节 / 秒）低于这个就降到 `lowBitrate`：2 Mbps 下 64 kbps 已占 3%，此时画面更要紧。
    static let lowBitrateBelowPacing: Double = 2_000_000 / 8

    static func bitrate(pacingRate: Double?) -> Int {
        guard let pacingRate, pacingRate < lowBitrateBelowPacing else { return normalBitrate }
        return lowBitrate
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
