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
    /// nil = 主显示器。要看别的显示器时填 `RemoteDesktopInfo.displays` 里的 id。
    var displayID: UInt32? = nil
    /// 手机能另开一个解码器解旁路精修帧（`RemoteDesktopFrame.Flags.sidecar`）。HEVC 时 Mac 据此改用
    /// 10-bit 主流 + 旁路精修；nil / false（老手机）时照旧 8-bit + 主流里精修。老 Mac 不认这个键，照旧发。
    var sidecarRefine: Bool? = nil
    /// 手机能从数据报通道收视频。路径是公网直连时 Mac 才会用；老 Mac 不认这个键，照旧走可靠通道。
    var videoDatagrams: Bool? = nil
    /// 手机要画面往返读数（`desktopLatency`），显示在调试信息里。老 Mac 不认这个键，什么都不发。
    var latencyStats: Bool? = nil
    /// 要光标形状（`desktopCursorImage`）：Mac 主控端拿它当本机光标。老 Mac 不认这个键，什么都不发。
    var cursorImages: Bool? = nil
    /// 看的设备每个点几个像素（Duo / iPad / 视网膜 Mac 是 2，iPhone 是 3，普通外接屏是 1）。无显示器的 Mac
    /// 拿它把 `maxWidth` / `maxHeight` 换成点数，定虚拟屏多大（`RemoteHeadlessDisplay.virtualSize`）。
    /// 老 Mac 不认这个键；老的主控端不发，被控端按 2 算、下限照旧。
    var pointScale: Double? = nil
    /// 只看这一个窗口（`RemoteDesktopWindowList` 里的 id）。nil = 整块显示器。只发给声明了 `desktop-windows`
    /// 的 Mac：老 Mac 不认这个键，会照旧给整块显示器。
    var windowID: UInt32? = nil
    /// 只看一个窗口时，先把那个窗口调成这么大（点）再开流：一般是看的设备上画布的点尺寸，窗口里的内容按它重排，
    /// 字和在 Mac 上一样大。要「辅助功能」授权，没有就不调；App 有最小窗口尺寸时得到的可能更大。流结束后 Mac 把
    /// 窗口还原。nil = 不动窗口。
    var windowFit: RemoteDesktopFit? = nil
    /// 只看一个窗口时，看着的这段时间把它保持在最前：它的 App 不是当前 App 了就重新提上来。被别的窗口盖住、
    /// 或者 App 退到后台时 macOS 不让它重绘，动画就停在最后一帧。要「辅助功能」授权。会和坐在 Mac 前的人抢窗口，
    /// 所以由看的人决定开不开。只发给声明了 `desktop-window-front` 的 Mac；老 Mac 不认这个键，什么都不做。
    var windowKeepFront: Bool? = nil
    /// 只看一个窗口时，鼠标键盘直接投给那个窗口所在的进程：Mac 上的指针不动、前台 App 不变，窗口被盖住也点得到，
    /// 坐在 Mac 前的人可以同时用自己的键鼠。个别 App 不吃这样投来的事件，所以由看的人决定开不开。
    /// 只发给声明了 `desktop-window-input` 的 Mac；老 Mac 不认这个键，照旧走全局输入通道。
    var windowIndependentInput: Bool? = nil
}

/// 一个点尺寸。
nonisolated struct RemoteDesktopFit: Codable, Equatable, Sendable {
    var width: Double
    var height: Double
}

/// Mac → 主控端：光标此刻的样子（I 形、调整大小的箭头…）。图是 PNG，尺寸与热点都按点算。
nonisolated struct RemoteDesktopCursorImage: Codable, Equatable, Sendable {
    var png: Data
    var width: Double
    var height: Double
    var hotX: Double
    var hotY: Double
}

/// Mac → 手机：画面往返（`desktopLatency`），有画面在走时每 2 s 一条。
///
/// 往返 = Mac 采集这一帧 → 手机解码完回确认 → Mac 收到确认。它约等于手机上的一次操作到看见结果：
/// 输入去 Mac 的半程 + 画面回手机的半程，正好对上确认回程 + 画面去程。手机自己量不了：帧上的采集时刻是 Mac 的钟。
nonisolated struct RemoteDesktopLatency: Codable, Equatable, Sendable {
    var p50Millis: Int
    var p95Millis: Int
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
    /// 这条流的视频走数据报通道。
    var videoDatagrams: Bool? = nil
    /// Mac 上此刻接着的全部显示器（老 Mac 不报，为 nil）。看哪一块由开流请求的 `displayID` 定。
    var displays: [RemoteDesktopDisplaySummary]? = nil
    /// 这条流只看一个窗口时是它的 id 与标题；此时 `displayWidth` / `displayHeight` 是窗口的点尺寸，
    /// 归一化坐标按窗口算。之后窗口改大小由 `desktopGeometry` 更新。
    var windowID: UInt32? = nil
    var windowTitle: String? = nil
}

/// 主控端 → Mac：要窗口列表（`desktopWindows`，通道 0）。
nonisolated struct RemoteDesktopWindowListRequest: Codable, Equatable, Sendable {
    var requestID: UUID
}

/// Mac → 主控端：此刻能单独看的窗口（`desktopWindowList`，通道 0），最前面的窗口在前。
nonisolated struct RemoteDesktopWindowList: Codable, Equatable, Sendable {
    var requestID: UUID
    var windows: [RemoteDesktopWindowSummary]
    /// 列不出来时给人看的原因（没开远程桌面、没有屏幕录制授权）。
    var message: String? = nil
}

/// 一个窗口的简介：给主控端的「只看一个窗口」菜单用。
nonisolated struct RemoteDesktopWindowSummary: Codable, Equatable, Hashable, Sendable {
    var id: UInt32
    /// 所属 App 的名字（「Xcode」）。
    var app: String
    /// 窗口标题，可能为空。
    var title: String
    /// 点尺寸。
    var width: Double
    var height: Double
}

extension RemoteDesktopWindowSummary {
    /// 菜单里的第一行：有标题用标题，没有用 App 名。
    nonisolated var menuTitle: String { title.isEmpty ? app : title }

    /// 第二行：App 名（标题为空时不重复）和尺寸。
    nonisolated var menuDetail: String {
        let size = "\(Int(width))×\(Int(height))"
        return title.isEmpty ? size : "\(app) · \(size)"
    }
}

/// Mac → 主控端：只看一个窗口时画面对应的范围（`desktopGeometry`，桌面通道）。
///
/// 视频帧的尺寸开流后不变。窗口改了大小、或者弹出的菜单伸出了窗口，系统把新的范围等比缩进同一帧、靠左上角放，
/// 右边或下边空出来。这里告诉主控端：现在画面对应多大一块（点），以及它占视频帧的多大一部分。
nonisolated struct RemoteDesktopGeometryUpdate: Codable, Equatable, Sendable {
    /// 画面对应范围的点尺寸（替换 `RemoteDesktopInfo.displayWidth` / `displayHeight`）。
    var width: Double
    var height: Double
    /// 内容占视频帧的比例（0…1，从左上角算）。
    var contentWidth: Double
    var contentHeight: Double
    /// 视频帧现在的像素尺寸（替换 `RemoteDesktopInfo.streamWidth` / `streamHeight`）。原地换尺寸之后和开流时不一样了；
    /// 老 Mac 不发，主控端照旧用开流时的。
    var streamWidth: Int? = nil
    var streamHeight: Int? = nil
}

/// 一块显示器的简介：给主控端的「切换显示器」菜单用。
nonisolated struct RemoteDesktopDisplaySummary: Codable, Equatable, Hashable, Sendable {
    var id: UInt32
    var name: String
    /// 点尺寸。
    var width: Double
    var height: Double
    var isMain: Bool
}

extension RemoteDesktopDisplaySummary {
    /// 「切换显示器」菜单里的一行（两端共用）。
    nonisolated var menuTitle: String {
        let size = "\(Int(width))×\(Int(height))"
        return isMain ? String(localized: "\(name)（主显示器，\(size)）")
                      : String(localized: "\(name)（\(size)）")
    }

    /// 两行写法的第二行（手机菜单：名字一行，这一行放「主显示器」和尺寸）。
    nonisolated var menuDetail: String {
        let size = "\(Int(width))×\(Int(height))"
        return isMain ? String(localized: "主显示器 · \(size)") : size
    }
}

/// Mac → 手机：锁屏与帘幕状态（`desktopScreenState`，桌面通道）。只发给声明了 `desktop-unlock` 的手机。
nonisolated struct RemoteDesktopScreenState: Codable, Equatable, Sendable {
    /// Mac 停在锁屏界面上。
    var locked: Bool
    /// 帘幕模式开着：Mac 的物理屏是黑的，本机键鼠暂停。
    var curtained: Bool
    /// 这台 Mac 允许手机远程解锁、挂帘幕（开了设置里的开关，并且有「辅助功能」授权）。
    var unlockAvailable: Bool
    /// 屏上正等着验证的系统框（要 Touch ID 或登录密码的那种）。只发给声明了 `desktop-auth-prompt` 的对端；
    /// 老对端解码时忽略这个键。
    var authPrompt: RemoteDesktopAuthPrompt? = nil
}

/// Mac 上一个等着验证身份的系统框：管理员授权（SecurityAgent）或 App 调 LocalAuthentication（coreautha）。
/// 指纹没法远程给，主控端能做的是让 Mac 点「使用密码」、填登录密码，或取消这个框。
nonisolated struct RemoteDesktopAuthPrompt: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// 系统授权（装软件、改系统设置、`sudo`、脚本要管理员权限）：只有密码框。
        case authorization
        /// App 要验证身份（LocalAuthentication）：先是 Touch ID，可以改用密码。
        case localAuthentication
        /// 以后的 Mac 认出的新种类，老主控端按通用文案显示。
        case other

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    /// 那个框的窗口号。主控端回应时带上，Mac 据此确认要填的还是同一个框（中途换了框就不填）。
    var id: UInt32
    var kind: Kind
}

/// 主控端 → Mac：回应屏上的验证框（`desktopAuthPrompt`，桌面通道）。密码只在 Mac 内存里用一次。
nonisolated struct RemoteDesktopAuthPromptRequest: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    enum Action: String, Codable, Sendable {
        /// 改用密码并填入登录密码、确认。
        case fill
        /// 取消这个框（等同在 Mac 上点「取消」）。
        case cancel
    }

    var requestID: UUID
    var promptID: UInt32
    var action: Action
    /// `fill` 时的登录密码。
    var password: String?

    /// 不让密码经 `print` / 字符串插值意外进日志。
    var description: String { "RemoteDesktopAuthPromptRequest(\(requestID), \(action.rawValue))" }
    var debugDescription: String { description }
}

/// Mac → 主控端：回应验证框的结果（`desktopAuthPromptResult`，桌面通道）。
nonisolated struct RemoteDesktopAuthPromptResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// 填完密码后框关了（通过了）。
        case accepted
        /// 填完密码后框还在：密码不对。
        case rejected
        /// 已取消。
        case cancelled
        /// 那个框已经不在了（Mac 前有人处理掉了，或换成了另一个框）。
        case gone
        /// 没能把框切到前台、或没找到密码输入框：密码没有输，免得打进别的 App。
        case notFocused
        /// Mac 没开远程解锁，或没有「辅助功能」授权，或这台设备不是正在看屏幕的那台。
        case notAllowed
        /// 等不到结果。
        case timedOut
    }

    var requestID: UUID
    var outcome: Outcome
}

/// 手机 → Mac：用登录密码解锁锁屏（`desktopUnlock`，桌面通道）。密码只在 Mac 内存里用一次。
nonisolated struct RemoteDesktopUnlockRequest: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    var requestID: UUID
    var password: String

    /// 不让密码经 `print` / 字符串插值意外进日志。
    var description: String { "RemoteDesktopUnlockRequest(\(requestID))" }
    var debugDescription: String { description }
}

/// Mac → 手机：解锁结果（`desktopUnlockResult`，桌面通道）。
nonisolated struct RemoteDesktopUnlockResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// 解开了，帘幕已挂上。
        case unlocked
        /// 输完密码回车后 Mac 仍锁着。不等于密码不对：Mac 读不到锁屏「拒绝了这个密码」的信号，
        /// 密码也可能根本没进锁屏的输入框（2026-11-08：一个卡住的选区截图抓着键盘，按键全被它吃掉）。
        /// 线上值沿用老版的 "rejected"，老手机照旧认得。
        case stillLocked = "rejected"
        /// Mac 上有程序占着键盘（截图选区等），按 Esc 也没让开：密码没有输。只发给声明了
        /// `desktopUnlockOutcomes` 的手机。
        case inputBlocked
        /// Mac 本来就没锁。
        case notLocked
        /// Mac 没开远程解锁，或没有「辅助功能」授权，或这台手机不是正在看屏幕的那台。
        case notAllowed
        /// 等不到锁屏状态变化。
        case timedOut
    }

    var requestID: UUID
    var outcome: Outcome
}

/// 手机 → Mac：开 / 关帘幕（`desktopCurtain`，桌面通道）。
nonisolated struct RemoteDesktopCurtainRequest: Codable, Equatable, Sendable {
    var on: Bool
}

/// 手机 → Mac：暂停 / 恢复推流（`desktopPause`，桌面通道）。
///
/// 只管这一条桌面流：Mac 换流（重连、重新开流）后从不暂停起步。暂停不动帘幕 / 锁屏、不断连接，
/// 也不动码控状态（对码控而言就像屏幕静止了一阵）。
nonisolated struct RemoteDesktopPauseRequest: Codable, Equatable, Sendable {
    var paused: Bool
}

/// 归一化的一块矩形：相对被看的那块显示器（或窗口），左上角原点，0…1。
nonisolated struct RemoteDesktopRegion: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let whole = RemoteDesktopRegion(x: 0, y: 0, width: 1, height: 1)

    /// 夹进 0…1；宽高不是正数返回 nil。
    var clamped: RemoteDesktopRegion? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        let x0 = min(1, max(0, x)), y0 = min(1, max(0, y))
        let x1 = min(1, max(0, x + width)), y1 = min(1, max(0, y + height))
        guard x1 > x0, y1 > y0 else { return nil }
        return RemoteDesktopRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `other` 整个落在这一块里（留一点浮点余量）。
    func contains(_ other: RemoteDesktopRegion, tolerance: Double = 1e-6) -> Bool {
        other.x >= x - tolerance && other.y >= y - tolerance
            && other.x + other.width <= x + width + tolerance && other.y + other.height <= y + height + tolerance
    }
}

/// 主控端 → Mac：此刻看得见的那一块（`desktopRegion`，桌面通道）。`visible` 为 nil = 没放大，回到整块。
nonisolated struct RemoteDesktopRegionRequest: Codable, Equatable, Sendable {
    var visible: RemoteDesktopRegion?
}

/// 一帧视频（`desktopFrame`）：
/// `[u8 标志][u8 编码][u32 序号][u64 Mac 采集时刻 ns][u16 宽][u16 高]`
/// + 带 `hasLTRToken` 时 `[u64 令牌]`，带 `hasRegion` 时 `[u16 x][u16 y][u16 宽][u16 高]`（各乘 65535）
/// + 关键帧时 `[u8 参数集个数]{[u16 长度][参数集]}`（H.264 = SPS/PPS，HEVC = VPS/SPS/PPS）
/// + AVCC 码流（每个 NAL 前 4 字节大端长度，即 VideoToolbox 直接吐出来的格式）。
nonisolated struct RemoteDesktopFrame: Equatable, Sendable {
    struct Flags: OptionSet, Sendable, Equatable {
        let rawValue: UInt8
        static let keyframe = Flags(rawValue: 1 << 0)
        /// 静止精修帧：画面没变，只是用更低的 QP 把同一画面重编一次。
        static let refine = Flags(rawValue: 1 << 1)
        /// 旁路精修帧（与 `refine`、`keyframe` 同时出现）：另一个编码会话编的高画质关键帧，不进主流的
        /// 参考链。手机用另一个解码器解、显示到下一帧主流画面为止；主流接着从自己的上一帧往下解。
        /// 只发给开流时声明了 `sidecarRefine` 的手机。
        static let sidecar = Flags(rawValue: 1 << 2)
        /// 只参考手机确认收到过的长期参考帧（LTR），前面丢了帧也解得开。不是关键帧，小得多。
        static let ltrRefresh = Flags(rawValue: 1 << 3)
        /// 带 `ltrToken`。
        static let hasLTRToken = Flags(rawValue: 1 << 4)
        /// 带 `region`：这一帧不是整块画面，只是其中一块（主控端放大后 Mac 按看得见的那块取的）。
        /// 只发给发过 `desktopRegion` 的主控端。
        static let hasRegion = Flags(rawValue: 1 << 5)
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
    /// 这一帧是长期参考帧：手机解出来后把它带回确认，Mac 才知道以后可以参考它。
    var ltrToken: UInt64? = nil
    /// 这一帧画的是哪一块（nil = 整块）。每帧各带各的，换区域的那一帧起就按新的摆，不会错位。
    var region: RemoteDesktopRegion? = nil

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
        if flags.contains(.hasLTRToken) { writer.u64(ltrToken ?? 0) }
        if flags.contains(.hasRegion), let region {
            for value in [region.x, region.y, region.width, region.height] {
                writer.u16(UInt16(clamping: Int((min(1, max(0, value)) * 65535).rounded())))
            }
        }
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
         width: UInt16, height: UInt16, parameterSets: [Data], data: Data, ltrToken: UInt64? = nil,
         region: RemoteDesktopRegion? = nil) {
        self.ltrToken = ltrToken
        self.region = region
        var flags = ltrToken == nil ? flags.subtracting(.hasLTRToken) : flags.union(.hasLTRToken)
        flags = region == nil ? flags.subtracting(.hasRegion) : flags.union(.hasRegion)
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
        if flags.contains(.hasLTRToken) { ltrToken = try reader.u64() }
        if flags.contains(.hasRegion) {
            let x = Double(try reader.u16()) / 65535, y = Double(try reader.u16()) / 65535
            let width = Double(try reader.u16()) / 65535, height = Double(try reader.u16()) / 65535
            region = RemoteDesktopRegion(x: x, y: y, width: width, height: height)
        }
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
    /// 这一帧解出来了，且它是长期参考帧。
    var ltrToken: UInt64? = nil

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: 25)
        writer.u32(sequence)
        writer.u64(captureNanos)
        writer.u32(decodeMicros)
        writer.u8((failed ? 1 : 0) | (ltrToken != nil ? 2 : 0))
        if let ltrToken { writer.u64(ltrToken) }
        return writer.data
    }

    init(sequence: UInt32, captureNanos: UInt64, decodeMicros: UInt32, failed: Bool = false, ltrToken: UInt64? = nil) {
        self.sequence = sequence
        self.captureNanos = captureNanos
        self.decodeMicros = decodeMicros
        self.failed = failed
        self.ltrToken = ltrToken
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        sequence = try reader.u32()
        captureNanos = try reader.u64()
        decodeMicros = try reader.u32()
        let flags = try reader.u8()
        failed = flags & 1 == 1
        if flags & 2 != 0 { ltrToken = try reader.u64() }
    }
}

/// 手机 → Mac：这些视频帧放弃了（`desktopVideoLost`）。`[u16 个数]{[u32 视频序号]}`。
nonisolated struct RemoteDesktopVideoLost: Equatable, Sendable {
    var videoSequences: [UInt32]

    func encoded() -> Data {
        let limited = videoSequences.prefix(1024)
        var writer = RemoteByteWriter(capacity: 2 + limited.count * 4)
        writer.u16(UInt16(limited.count))
        for sequence in limited { writer.u32(sequence) }
        return writer.data
    }

    init(videoSequences: [UInt32]) {
        self.videoSequences = videoSequences
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        let count = try reader.u16()
        var list: [UInt32] = []
        for _ in 0..<count { list.append(try reader.u32()) }
        videoSequences = list
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

/// 手机 → Mac：把手机上的一张图片或一段文字粘贴进 Mac 当前的前台 app（`desktopPaste`）。
/// Mac 写进系统剪贴板后替用户按一下 ⌘V，所以只在手机有控制权时生效。`[u8 类型][内容]`。
///
/// 整条消息要放进一帧（`RemoteConstants.maxFrameBytes` 4 MiB），内容上限留出余量；
/// 图片超了由手机端先压（见 `RemoteDesktopPasteSource`）。Mac 认得分块时大内容走 `RemoteDesktopPasteChunk`。
nonisolated enum RemoteDesktopPaste: Equatable, Sendable {
    static let maxContentBytes = 3_800_000

    case text(String)
    case png(Data)
    case jpeg(Data)

    private enum Tag: UInt8 {
        case text = 1, png = 2, jpeg = 3
    }

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: 1)
        switch self {
        case .text(let text):
            writer.u8(Tag.text.rawValue)
            writer.bytes(Data(text.utf8))
        case .png(let data):
            writer.u8(Tag.png.rawValue)
            writer.bytes(data)
        case .jpeg(let data):
            writer.u8(Tag.jpeg.rawValue)
            writer.bytes(data)
        }
        return writer.data
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        guard let tag = Tag(rawValue: try reader.u8()) else { throw RemoteProtocolError.malformedMessage }
        let content = reader.rest()
        guard !content.isEmpty, content.count <= Self.maxContentBytes else { throw RemoteProtocolError.malformedMessage }
        switch tag {
        case .text:
            guard let text = String(data: content, encoding: .utf8) else { throw RemoteProtocolError.malformedMessage }
            self = .text(text)
        case .png:
            self = .png(content)
        case .jpeg:
            self = .jpeg(content)
        }
    }
}

/// Mac → 手机：手机控制桌面时 Mac 剪贴板里新拷贝的文字（`desktopClipboard`），手机放进自己的剪贴板。
/// `[u8 类型][内容]`：文字是 UTF-8；太大没回传时只带原文字节数（`u32`），让手机提示一句。
///
/// 只发给 `features` 带 `desktop-clipboard` 的手机。先只做文字：图片等别的内容不回传。
nonisolated enum RemoteDesktopClipboard: Equatable, Sendable {
    /// 文字上限（UTF-8 字节）。超了发 `.tooLarge`，不截断：拷贝的半截代码粘出来比没有更糟。
    static let maxTextBytes = 1_000_000

    case text(String)
    case tooLarge(bytes: Int)

    private enum Tag: UInt8 {
        case text = 1, tooLarge = 2
    }

    /// 剪贴板里的一段文字该发什么：空文字不发（nil），超上限只报大小。
    static func message(for text: String) -> RemoteDesktopClipboard? {
        let bytes = text.utf8.count
        guard bytes > 0 else { return nil }
        return bytes <= maxTextBytes ? .text(text) : .tooLarge(bytes: bytes)
    }

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: 5)
        switch self {
        case .text(let text):
            writer.u8(Tag.text.rawValue)
            writer.bytes(Data(text.utf8))
        case .tooLarge(let bytes):
            writer.u8(Tag.tooLarge.rawValue)
            writer.u32(UInt32(clamping: bytes))
        }
        return writer.data
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        guard let tag = Tag(rawValue: try reader.u8()) else { throw RemoteProtocolError.malformedMessage }
        switch tag {
        case .text:
            let content = reader.rest()
            guard !content.isEmpty, content.count <= Self.maxTextBytes,
                  let text = String(data: content, encoding: .utf8) else { throw RemoteProtocolError.malformedMessage }
            self = .text(text)
        case .tooLarge:
            self = .tooLarge(bytes: Int(try reader.u32()))
        }
    }
}

/// 大内容粘贴的一块：`[u32 编号][u32 偏移][u32 总长][内容]`。拼起来是 `RemoteDesktopPaste.encoded()`。
nonisolated struct RemoteDesktopPasteChunk: Equatable, Sendable {
    static let headerBytes = 12
    /// 拼完不能超过这么多：一个字节的类型加内容上限。
    static let maxTotalBytes = RemoteDesktopPaste.maxContentBytes + 1

    var pasteID: UInt32
    var offset: UInt32
    var total: UInt32
    var bytes: Data

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: Self.headerBytes + bytes.count)
        writer.u32(pasteID)
        writer.u32(offset)
        writer.u32(total)
        writer.bytes(bytes)
        return writer.data
    }

    init(pasteID: UInt32, offset: UInt32, total: UInt32, bytes: Data) {
        self.pasteID = pasteID
        self.offset = offset
        self.total = total
        self.bytes = bytes
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        pasteID = try reader.u32()
        offset = try reader.u32()
        total = try reader.u32()
        bytes = reader.rest()
    }
}

/// Mac 这边把分块拼回一次粘贴。链路可靠有序，所以偏移必须正好接上；接不上就是对端出错，整个扔掉。
nonisolated struct RemoteDesktopPasteAssembler {
    private var pasteID: UInt32?
    private var total = 0
    private var buffer = Data()

    /// 拼完了返回内容。
    mutating func receive(_ chunk: RemoteDesktopPasteChunk) -> RemoteDesktopPaste? {
        if chunk.offset == 0 {
            // 新的一次粘贴顶掉没传完的那次。
            guard chunk.total > 0, chunk.total <= UInt32(RemoteDesktopPasteChunk.maxTotalBytes) else {
                reset()
                return nil
            }
            pasteID = chunk.pasteID
            total = Int(chunk.total)
            buffer = Data()
        }
        guard chunk.pasteID == pasteID, Int(chunk.total) == total, Int(chunk.offset) == buffer.count,
              buffer.count + chunk.bytes.count <= total else {
            reset()
            return nil
        }
        buffer.append(chunk.bytes)
        guard buffer.count == total else { return nil }
        defer { reset() }
        return try? RemoteDesktopPaste(decoding: buffer)
    }

    private mutating func reset() {
        pasteID = nil
        total = 0
        buffer = Data()
    }
}

/// 主控端 → Mac：把主控端上的一个文件（视频）传过去，贴进 Mac 当前的前台 app（`desktopPasteFile`）。
/// `[u32 编号][u64 偏移][u64 总长][u16 文件名长度][文件名][内容]`。
///
/// 文件比图片大得多，不能像 `RemoteDesktopPaste` 那样整份放在内存里拼：一块一块发，Mac 边收边写进文件
///（`RemotePastedFileReceiver`），收齐后把文件放进剪贴板、按 ⌘V。文件名每块都带（就几十个字节），接收端只认第一块的。
nonisolated struct RemoteDesktopPasteFileChunk: Equatable, Sendable {
    /// 一个文件最多这么大。
    static let maxTotalBytes: UInt64 = 4 << 30
    static let maxNameBytes = 255

    var pasteID: UInt32
    var offset: UInt64
    var total: UInt64
    var name: String
    var bytes: Data

    func encoded() -> Data {
        let name = Data(self.name.utf8.prefix(Self.maxNameBytes))
        var writer = RemoteByteWriter(capacity: 22 + name.count + bytes.count)
        writer.u32(pasteID)
        writer.u64(offset)
        writer.u64(total)
        writer.u16(UInt16(name.count))
        writer.bytes(name)
        writer.bytes(bytes)
        return writer.data
    }

    init(pasteID: UInt32, offset: UInt64, total: UInt64, name: String, bytes: Data) {
        self.pasteID = pasteID
        self.offset = offset
        self.total = total
        self.name = name
        self.bytes = bytes
    }

    init(decoding payload: Data) throws {
        var reader = RemoteByteReader(payload)
        pasteID = try reader.u32()
        offset = try reader.u64()
        total = try reader.u64()
        let length = Int(try reader.u16())
        guard length <= Self.maxNameBytes else { throw RemoteProtocolError.malformedMessage }
        // 文件名在 UTF-8 的字节上截过，末尾可能是半个字：按容错解。
        name = String(decoding: try reader.bytes(length), as: UTF8.self)
        bytes = reader.rest()
    }
}

/// 要粘贴到 Mac 的一样东西：图片 / 文字（整份在内存里），或一个文件（视频，按路径边读边传）。
nonisolated enum RemoteDesktopPasteItem: Equatable, Sendable {
    case content(RemoteDesktopPaste)
    case file(url: URL, name: String)
}

nonisolated enum RemoteDesktopPasteFileError: LocalizedError, Equatable {
    case macTooOld
    case unreadable
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .macTooOld: return String(localized: "这台 Mac 上的 uTerm 版本太旧，不能粘贴视频。把 Mac 上的 uTerm 更新到最新版")
        case .unreadable: return String(localized: "无法读取这个视频")
        case .tooLarge: return String(localized: "视频太大，一次最多粘贴 4 GB")
        }
    }
}

/// 手机这边把粘贴内容排着队发出去。大内容切块，发完一块再发下一块，中间按键和确认能插进来。
nonisolated final class RemoteDesktopPasteUploader: @unchecked Sendable {
    static let chunkBytes = 32 * 1024
    /// 同时在途几块。太少的话直连上每个往返只传一块（确认才算完成），太多又把链路占满。
    static let window = 4

    /// 文件一块多大。比图片的块大：视频几十上百 MB，块太小光往返就要很久。
    static let fileChunkBytes = 256 * 1024

    /// 排着队的一条内容和它的回调。只在 `link.queue` 上碰（所以 `@unchecked`）。
    private final class Item: @unchecked Sendable {
        enum Source {
            /// 打好包的图片 / 文字（`RemoteDesktopPaste.encoded()`）。
            case data(Data)
            /// 一个文件，从头顺着读。
            case file(FileHandle, name: String)
        }

        let source: Source
        let total: Int
        let progress: (@Sendable (_ sent: Int, _ total: Int) -> Void)?
        let completion: (@Sendable (Error?) -> Void)?
        private var sent = 0
        private var finished = false

        init(source: Source, total: Int, progress: (@Sendable (Int, Int) -> Void)?,
             completion: (@Sendable (Error?) -> Void)?) {
            self.source = source
            self.total = total
            self.progress = progress
            self.completion = completion
        }

        /// 链路接走了 `bytes` 字节（`error` 非 nil 时是没接走）。
        func handedOff(_ bytes: Int, error: Error?) {
            guard !finished else { return }
            if let error { return finish(error) }
            sent += bytes
            progress?(sent, total)
            if sent >= total { finish(nil) }
        }

        func finish(_ error: Error?) {
            guard !finished else { return }
            finished = true
            completion?(error)
        }
    }

    private let link: RemoteLink
    private let channel: UInt32
    private let supportsChunks: Bool
    private var waiting: [Item] = []
    private var current: Item?
    private var offset = 0
    private var inFlight = 0
    private var nextID: UInt32 = 1
    private var failed = false

    init(link: RemoteLink, channel: UInt32, supportsChunks: Bool) {
        self.link = link
        self.channel = channel
        self.supportsChunks = supportsChunks
    }

    deinit {
        // 还没发完的不能让等着的人一直等。
        let pending = waiting + (current.map { [$0] } ?? [])
        guard !pending.isEmpty else { return }
        link.queue.async { pending.forEach { $0.finish(RemoteProtocolError.closed) } }
    }

    func isFor(link other: RemoteLink, channel otherChannel: UInt32) -> Bool {
        link === other && channel == otherChannel
    }

    /// 排一条内容。打包（几 MB 的拷贝）在链路队列上做，不占调用方的线程。
    /// - Parameters:
    ///   - progress: 链路已接走多少字节 / 总字节数，在 `link.queue` 上调。
    ///   - completion: 全部交给链路后（或发不出去时带着错误）在 `link.queue` 上调一次。
    func enqueue(_ content: RemoteDesktopPaste,
                 progress: (@Sendable (_ sent: Int, _ total: Int) -> Void)? = nil,
                 completion: (@Sendable (Error?) -> Void)? = nil) {
        link.queue.async { [self] in
            guard !failed else {
                completion?(RemoteProtocolError.closed)
                return
            }
            let payload = content.encoded()
            waiting.append(Item(source: .data(payload), total: payload.count, progress: progress, completion: completion))
            pump()
        }
    }

    /// 排一个文件（视频）：边读边发，不整份读进内存。调用前应已确认 Mac 认得 `desktopPasteFile`。
    /// `name`：Mac 上存成的文件名。回调同 `enqueue(_:progress:completion:)`。
    func enqueueFile(at url: URL, name: String,
                     progress: (@Sendable (_ sent: Int, _ total: Int) -> Void)? = nil,
                     completion: (@Sendable (Error?) -> Void)? = nil) {
        link.queue.async { [self] in
            guard !failed else {
                completion?(RemoteProtocolError.closed)
                return
            }
            guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd(), size > 0,
                  (try? handle.seek(toOffset: 0)) != nil else {
                completion?(RemoteDesktopPasteFileError.unreadable)
                return
            }
            guard size <= RemoteDesktopPasteFileChunk.maxTotalBytes else {
                completion?(RemoteDesktopPasteFileError.tooLarge)
                return
            }
            waiting.append(Item(source: .file(handle, name: name), total: Int(size), progress: progress, completion: completion))
            pump()
        }
    }

    /// 一切都在 `link.queue` 上。
    private func pump() {
        while !failed {
            if current == nil {
                guard !waiting.isEmpty else { return }
                let next = waiting.removeFirst()
                if case .data(let payload) = next.source, !(supportsChunks && payload.count > Self.chunkBytes) {
                    // 排在队里的就按序发：小内容不能抢到前面的大内容之前。
                    let count = payload.count
                    link.sendOnQueue(RemoteMessage(.desktopPaste, channel: channel, payload: payload),
                                     completion: { error in next.handedOff(count, error: error) })
                    continue
                }
                current = next
                offset = 0
            }
            guard let item = current else { return }
            var unreadable = false
            while inFlight < Self.window, offset < item.total {
                guard let (message, length) = nextChunk(of: item) else {
                    unreadable = true
                    break
                }
                offset += length
                inFlight += 1
                link.sendOnQueue(message, completion: { [weak self] error in
                    item.handedOff(length, error: error)
                    self?.chunkFinished(error)
                })
            }
            if unreadable {
                // 文件读不下去了（被删了、比开始时短了）：这一条算失败，后面排着的照发。Mac 那边没收齐的半个文件
                // 等下一次粘贴来时扔掉。
                current = nil
                nextID &+= 1
                item.finish(RemoteDesktopPasteFileError.unreadable)
                continue
            }
            guard offset >= item.total else { return }
            current = nil
            nextID &+= 1
        }
    }

    /// `current` 从 `offset` 起的下一块。文件读不出来时返回 nil。
    private func nextChunk(of item: Item) -> (RemoteMessage, Int)? {
        switch item.source {
        case .data(let payload):
            let end = min(payload.count, offset + Self.chunkBytes)
            let chunk = RemoteDesktopPasteChunk(pasteID: nextID, offset: UInt32(offset), total: UInt32(payload.count),
                                                bytes: Data(payload[(payload.startIndex + offset)..<(payload.startIndex + end)]))
            return (RemoteMessage(.desktopPasteChunk, channel: channel, payload: chunk.encoded()), end - offset)
        case .file(let handle, let name):
            let want = min(Self.fileChunkBytes, item.total - offset)
            guard let bytes = try? handle.read(upToCount: want), !bytes.isEmpty else { return nil }
            let chunk = RemoteDesktopPasteFileChunk(pasteID: nextID, offset: UInt64(offset), total: UInt64(item.total),
                                                    name: name, bytes: bytes)
            return (RemoteMessage(.desktopPasteFile, channel: channel, payload: chunk.encoded()), bytes.count)
        }
    }

    private func chunkFinished(_ error: Error?) {
        inFlight -= 1
        if let error {
            failed = true
            let dropped = waiting + (current.map { [$0] } ?? [])
            waiting = []
            current = nil
            dropped.forEach { $0.finish(error) }
            return
        }
        pump()
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
