import CoreMedia
import Foundation

// 远程桌面（P2）的消息体。两端共用。
//
// 控制类（开流请求 / 开流结果）低频，用 JSON；每秒几十上百条的（视频帧、确认、输入、光标）
// 一律定长大端二进制，不经 JSON。坐标一律是**显示器归一化坐标**（左上角原点，0…1），
// 与采集分辨率、手机缩放都无关：Mac 按显示器当前的点尺寸换算成全局坐标。

nonisolated enum RemoteVideoCodec: String, Codable, Sendable, CaseIterable {
    case hevc
    case h264

    /// 帧头里的 1 字节编号。
    var wireValue: UInt8 {
        switch self {
        case .hevc: return 1
        case .h264: return 2
        }
    }

    init?(wireValue: UInt8) {
        switch wireValue {
        case 1: self = .hevc
        case 2: self = .h264
        default: return nil
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .hevc: return kCMVideoCodecType_HEVC
        case .h264: return kCMVideoCodecType_H264
        }
    }
}

/// 手机 → Mac：开始看桌面（通道 0）。
nonisolated struct RemoteDesktopStartRequest: Codable, Equatable, Sendable {
    var requestID: UUID
    /// 手机希望的最大视频尺寸（像素，横向 × 纵向，与方向无关：Mac 按显示器的横竖去套）。
    var maxWidth: Int
    var maxHeight: Int
    var codec: RemoteVideoCodec
    /// nil = 主显示器。多显示器切换留的口子，本期 Mac 只认主显示器。
    var displayID: UInt32? = nil
}

/// Mac → 手机：开流结果（`desktopStarted`，通道 = 这条桌面流的通道）。
nonisolated struct RemoteDesktopInfo: Codable, Equatable, Sendable {
    enum Failure: String, Codable, Sendable {
        /// Mac 上没打开「允许远程桌面」。
        case disabled
        /// 没有屏幕录制授权（或授权后还没重启 uTerm）。
        case screenPermission
        /// 采集 / 编码起不来。
        case captureFailed
    }

    var requestID: UUID
    /// nil = 成功。
    var failure: Failure? = nil
    /// 给人看的失败原因 / 提示。
    var message: String? = nil
    var displayID: UInt32 = 0
    /// 显示器的点尺寸（决定纵横比与「1 点」有多大）。
    var displayWidth: Double = 0
    var displayHeight: Double = 0
    /// 视频的像素尺寸。
    var streamWidth: Int = 0
    var streamHeight: Int = 0
    var codec: RemoteVideoCodec = .hevc
    /// 能否注入鼠标键盘（有「辅助功能」授权）。false 时手机只能看。
    var canControl: Bool = false
    /// `canControl == false` 时的说明。
    var controlNote: String? = nil
}

/// 一帧视频（`desktopFrame`）：
/// `[u8 标志][u8 编码][u32 序号][u64 Mac 采集时刻 ns][u16 宽][u16 高]`
/// + 关键帧时 `[u8 参数集个数]{[u16 长度][参数集]}`（H.264 = SPS/PPS，HEVC = VPS/SPS/PPS）
/// + AVCC 码流（每个 NAL 前 4 字节大端长度，即 VideoToolbox 直接吐出来的格式）。
nonisolated struct RemoteDesktopFrame: Equatable, Sendable {
    struct Flags: OptionSet, Sendable, Equatable {
        let rawValue: UInt8
        static let keyframe = Flags(rawValue: 1 << 0)
        /// 静止精修帧：画面没变，只是用更低的 QP 把同一画面重编一次。
        static let refine = Flags(rawValue: 1 << 1)
    }

    var flags: Flags
    var codec: RemoteVideoCodec
    var sequence: UInt32
    /// Mac 端的单调时钟（`DispatchTime.uptimeNanoseconds`），手机原样带回确认里，Mac 用自己的钟算往返。
    var captureNanos: UInt64
    var width: UInt16
    var height: UInt16
    var parameterSets: [Data]
    var data: Data

    var isKeyframe: Bool { flags.contains(.keyframe) }

    static let headerSize = 18

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: Self.headerSize + data.count + parameterSets.reduce(1) { $0 + 2 + $1.count })
        writer.u8(flags.rawValue)
        writer.u8(codec.wireValue)
        writer.u32(sequence)
        writer.u64(captureNanos)
        writer.u16(width)
        writer.u16(height)
        if isKeyframe {
            writer.u8(UInt8(parameterSets.count))
            for set in parameterSets {
                writer.u16(UInt16(set.count))
                writer.bytes(set)
            }
        }
        writer.bytes(data)
        return writer.data
    }

    init(flags: Flags, codec: RemoteVideoCodec, sequence: UInt32, captureNanos: UInt64,
         width: UInt16, height: UInt16, parameterSets: [Data], data: Data) {
        self.flags = flags
        self.codec = codec
        self.sequence = sequence
        self.captureNanos = captureNanos
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
        self.data = data
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        flags = Flags(rawValue: try reader.u8())
        guard let codec = RemoteVideoCodec(wireValue: try reader.u8()) else { throw RemoteProtocolError.malformedMessage }
        self.codec = codec
        sequence = try reader.u32()
        captureNanos = try reader.u64()
        width = try reader.u16()
        height = try reader.u16()
        var sets: [Data] = []
        if flags.contains(.keyframe) {
            let count = Int(try reader.u8())
            for _ in 0..<count {
                sets.append(try reader.bytes(Int(try reader.u16())))
            }
            guard !sets.isEmpty else { throw RemoteProtocolError.malformedMessage }
        }
        parameterSets = sets
        data = reader.rest()
        guard !data.isEmpty else { throw RemoteProtocolError.malformedMessage }
    }
}

/// 手机 → Mac：一帧处理完了（`desktopAck`）。`[u32 序号][u64 采集时刻（原样带回）][u32 解码耗时 µs][u8 标志]`。
///
/// 手机收到的**每一帧**都要回，包括解码失败、等关键帧时跳过的帧——Mac 的在途计数靠它归零，
/// 少回一帧 Mac 就会少一个在途名额，回少了会把流卡死。
nonisolated struct RemoteDesktopAck: Equatable, Sendable {
    var sequence: UInt32
    var captureNanos: UInt64
    var decodeMicros: UInt32
    /// 这一帧没能解出来（手机随后会单独请求关键帧）。
    var failed: Bool = false

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: 17)
        writer.u32(sequence)
        writer.u64(captureNanos)
        writer.u32(decodeMicros)
        writer.u8(failed ? 1 : 0)
        return writer.data
    }

    init(sequence: UInt32, captureNanos: UInt64, decodeMicros: UInt32, failed: Bool = false) {
        self.sequence = sequence
        self.captureNanos = captureNanos
        self.decodeMicros = decodeMicros
        self.failed = failed
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        sequence = try reader.u32()
        captureNanos = try reader.u64()
        decodeMicros = try reader.u32()
        failed = try reader.u8() & 1 == 1
    }
}

/// Mac → 手机：光标位置（`desktopCursor`）。`[f32 x][f32 y][u8 可见]`，显示器归一化坐标。
nonisolated struct RemoteDesktopCursor: Equatable, Sendable {
    var x: Float
    var y: Float
    var visible: Bool = true

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: 9)
        writer.f32(x)
        writer.f32(y)
        writer.u8(visible ? 1 : 0)
        return writer.data
    }

    init(x: Float, y: Float, visible: Bool = true) {
        self.x = x
        self.y = y
        self.visible = visible
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        x = try reader.f32()
        y = try reader.f32()
        visible = try reader.u8() == 1
    }
}

/// 修饰键（自定义位，与平台无关；Mac 端翻成 `CGEventFlags`）。
nonisolated struct RemoteKeyModifiers: OptionSet, Sendable, Hashable {
    let rawValue: UInt32
    static let shift = RemoteKeyModifiers(rawValue: 1 << 0)
    static let control = RemoteKeyModifiers(rawValue: 1 << 1)
    static let option = RemoteKeyModifiers(rawValue: 1 << 2)
    static let command = RemoteKeyModifiers(rawValue: 1 << 3)
    static let capsLock = RemoteKeyModifiers(rawValue: 1 << 4)
    static let function = RemoteKeyModifiers(rawValue: 1 << 5)
}

nonisolated enum RemoteMouseButton: UInt8, Sendable {
    case left = 0
    case right = 1
    case other = 2
}

/// 滚动阶段，对应 macOS 触控板滚动的两段：手指在板上（`gesture`）与松手后的惯性（`momentum`）。
/// 带阶段的像素滚动在 Safari / Xcode 里才有「跟手 + 惯性」的手感。
nonisolated enum RemoteScrollPhase: UInt8, Sendable {
    /// 不带阶段的离散滚动（鼠标滚轮式）。
    case none = 0
    case began = 1
    case changed = 2
    case ended = 3
    case momentumBegan = 4
    case momentum = 5
    case momentumEnded = 6
}

/// 手机 → Mac：一次输入（`desktopInput`）。`[u8 类型]` + 各自的定长字段。
nonisolated enum RemoteDesktopInput: Equatable, Sendable {
    /// 指针移到（归一化）位置。按着键时 Mac 端自动发成拖拽事件。
    case move(x: Float, y: Float)
    case button(RemoteMouseButton, down: Bool, clickCount: UInt8, x: Float, y: Float, modifiers: RemoteKeyModifiers)
    /// 像素滚动量（Mac 的点），与手指移动同向——自然滚动：手指往下拖，内容跟着往下走、露出上面的内容。
    /// 这正是 `CGEvent` 像素滚轮的符号约定（wheel 为正 = 往上翻），Mac 端原样当滚轮值用。
    case scroll(dx: Float, dy: Float, phase: RemoteScrollPhase)
    /// 一个物理键（macOS 虚拟键码）。
    case key(code: UInt16, down: Bool, modifiers: RemoteKeyModifiers)
    /// 一段已经上屏的文字（软键盘 / 输入法的结果），Mac 端按 Unicode 直接注入，绕开 Mac 的输入法。
    case text(String)

    private enum Tag: UInt8 {
        case move = 1, button = 2, scroll = 3, key = 4, text = 5
    }

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: 24)
        switch self {
        case .move(let x, let y):
            writer.u8(Tag.move.rawValue)
            writer.f32(x)
            writer.f32(y)
        case .button(let button, let down, let clicks, let x, let y, let modifiers):
            writer.u8(Tag.button.rawValue)
            writer.u8(button.rawValue)
            writer.u8(down ? 1 : 0)
            writer.u8(clicks)
            writer.f32(x)
            writer.f32(y)
            writer.u32(modifiers.rawValue)
        case .scroll(let dx, let dy, let phase):
            writer.u8(Tag.scroll.rawValue)
            writer.f32(dx)
            writer.f32(dy)
            writer.u8(phase.rawValue)
        case .key(let code, let down, let modifiers):
            writer.u8(Tag.key.rawValue)
            writer.u16(code)
            writer.u8(down ? 1 : 0)
            writer.u32(modifiers.rawValue)
        case .text(let text):
            writer.u8(Tag.text.rawValue)
            writer.bytes(Data(text.utf8))
        }
        return writer.data
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        guard let tag = Tag(rawValue: try reader.u8()) else { throw RemoteProtocolError.malformedMessage }
        switch tag {
        case .move:
            self = .move(x: try reader.f32(), y: try reader.f32())
        case .button:
            guard let button = RemoteMouseButton(rawValue: try reader.u8()) else { throw RemoteProtocolError.malformedMessage }
            let down = try reader.u8() == 1
            let clicks = try reader.u8()
            self = .button(button, down: down, clickCount: clicks, x: try reader.f32(), y: try reader.f32(),
                           modifiers: RemoteKeyModifiers(rawValue: try reader.u32()))
        case .scroll:
            let dx = try reader.f32()
            let dy = try reader.f32()
            guard let phase = RemoteScrollPhase(rawValue: try reader.u8()) else { throw RemoteProtocolError.malformedMessage }
            self = .scroll(dx: dx, dy: dy, phase: phase)
        case .key:
            let code = try reader.u16()
            let down = try reader.u8() == 1
            self = .key(code: code, down: down, modifiers: RemoteKeyModifiers(rawValue: try reader.u32()))
        case .text:
            guard let text = String(data: reader.rest(), encoding: .utf8), !text.isEmpty else {
                throw RemoteProtocolError.malformedMessage
            }
            self = .text(text)
        }
    }
}

// MARK: - 字节读写

/// 大端定长字段的拼装。
nonisolated struct RemoteByteWriter {
    private(set) var data: Data

    init(capacity: Int) {
        data = Data(capacity: capacity)
    }

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func f32(_ value: Float) { u32(value.bitPattern) }

    mutating func bytes(_ bytes: Data) { data.append(bytes) }
}

/// 大端定长字段的读取；越界抛 `malformedMessage`（对端发来的就是坏消息）。
nonisolated struct RemoteByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    private mutating func take(_ count: Int) throws -> Data.SubSequence {
        guard count >= 0, data.endIndex - offset >= count else { throw RemoteProtocolError.malformedMessage }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u16() throws -> UInt16 {
        try take(2).reduce(0) { $0 << 8 | UInt16($1) }
    }

    mutating func u32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() throws -> UInt64 {
        try take(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    mutating func bytes(_ count: Int) throws -> Data { Data(try take(count)) }

    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset...])
    }
}
