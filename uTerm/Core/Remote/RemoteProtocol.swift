import Foundation

/// 远控（手机接入 Mac 上的终端）协议常量。两端共用。
///
/// 服务类型必须同时写进两端 Info.plist 的 `NSBonjourServices`，否则 iOS 的浏览收不到结果、
/// macOS 沙盒里的广播也会被拒。
nonisolated enum RemoteConstants {
    static let serviceType = "_uterm-remote._tcp"
    /// 握手里双方都要带；不一致直接拒绝，不做降级。
    static let protocolVersion = 1
    /// 单帧上限。一帧最大的内容是快照（1000 行彩色历史约 65 KB）与一次合并的输出（≤256 KB），
    /// 留足余量；超过即视为对端出错。
    static let maxFrameBytes = 4 * 1024 * 1024
    /// 一次输出帧最多合并多少字节。太大会拉高首字节延迟，太小则帧头与加密开销占比上升。
    static let maxOutputChunkBytes = 256 * 1024
    /// 每个订阅者在 Mac 端最多积压多少未发出的输出；超过就丢弃积压、改发快照（见 `TerminalMirrorTap`）。
    static let maxPendingOutputBytes = 1024 * 1024
    /// 已交给网络栈但还没发出去的字节上限。超过就暂停取新输出，交给积压上限去兜底。
    static let maxInflightBytes = 512 * 1024
    static let handshakeTimeout: Duration = .seconds(10)
    /// 配对时等 Mac 上的人点「允许」的时长。
    static let pairingTimeout: Duration = .seconds(120)
    /// 快照里带多少行历史。
    static let snapshotScrollback = 1000
    /// 本机支持的可选能力，握手时放进 `RemoteHello.features`。协议版本号不变：老版本对端
    /// 解码时忽略这个键，新版本据此判断对端能不能做某件事（例如老 Mac 不认桌面消息，
    /// 收到会当作未知消息断开整条连接，所以手机必须先看能力再发）。
    static let localFeatures: [String] = [RemoteFeature.desktop, RemoteFeature.desktopPaste, RemoteFeature.localShell]
    /// Mac 本机 shell 在会话列表里的 `serverID`：不对应任何 `ServerProfile`，手机见到它就知道是「这台 Mac
    /// 自己」，不去自己的主机列表里找。
    static let localShellServerID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
}

nonisolated enum RemoteFeature {
    /// 远程桌面（P2）：认得 `desktop*` 消息。
    static let desktop = "desktop"
    /// 远程桌面里粘贴手机的图片 / 文字：认得 `desktopPaste`。
    static let desktopPaste = "desktop-paste"
    /// 能在 Mac 上开一个本机 shell：认得 `openLocalShell`。
    static let localShell = "local-shell"
}

/// 加密信道里的一条消息：`[u8 类型][u32 通道（大端）][负载]`。
///
/// 通道 0 是控制通道（会话列表、配对状态、心跳）；每次接入一个终端分配一个非 0 通道，
/// 该终端的输入、输出、尺寸都走它。终端字节原样放进负载，不做任何编码。
nonisolated struct RemoteMessage: Equatable, Sendable {
    enum Kind: UInt8, Sendable {
        // 手机 → Mac
        /// 订阅会话列表。Mac 立即回一份 `.sessions`，之后每次变化再推一份。
        case subscribeSessions = 1
        /// 接入终端。负载 = `RemoteAttachRequest`（JSON）。
        case attach = 2
        /// 键盘输入：原始字节，Mac 原样写进该会话的后端。
        case input = 3
        /// 手机终端的行列数变了。负载 = `RemoteGridSize`（4 字节）。
        case resize = 4
        case detach = 5
        case ping = 6
        /// 在 Mac 上开一个本机 shell（通道 0）。负载 = `RemoteOpenLocalShellRequest`（JSON）。Mac 开出终端窗口、
        /// 会话登记好之后回 `.localShellOpened`，手机再按会话 id 走正常的 `.attach`。只发给 `features` 带
        /// `local-shell` 的 Mac。
        case openLocalShell = 7
        /// 开始看桌面（通道 0）。负载 = `RemoteDesktopStartRequest`（JSON）。只发给 `features` 带
        /// `desktop` 的 Mac。
        case desktopStart = 10
        /// 结束桌面流（桌面通道）。
        case desktopStop = 11
        /// 鼠标 / 键盘输入（桌面通道）。负载 = `RemoteDesktopInput`（二进制）。
        case desktopInput = 12
        /// 一帧解码完毕的确认（桌面通道）。负载 = `RemoteDesktopAck`。Mac 靠它做端到端背压与码率控制。
        case desktopAck = 13
        /// 请求关键帧（桌面通道）：解码出错、重连、回到前台时。
        case desktopKeyframe = 14
        /// 把手机上的图片 / 文字粘贴到 Mac（桌面通道）。负载 = `RemoteDesktopPaste`（二进制）。
        /// 只发给 `features` 带 `desktop-paste` 的 Mac。
        case desktopPaste = 15

        // Mac → 手机
        /// 会话列表。负载 = `[RemoteSessionInfo]`（JSON）。
        case sessions = 20
        /// 接入结果。负载 = `RemoteAttachResult`（JSON）。
        case attached = 21
        /// 终端字节：快照（以 RIS 开头）或之后的输出，接收端一律直接喂给终端。
        case output = 22
        /// 该通道的会话结束（远端退出、窗格关闭、被别的设备接管）。负载 = UTF-8 原因。
        case closed = 23
        case pong = 24
        /// 桌面流开始（或被拒）。通道 = 分配给这条桌面流的通道。负载 = `RemoteDesktopInfo`（JSON）。
        /// 桌面流结束复用 `.closed`。
        case desktopStarted = 25
        /// 一帧视频。负载 = `RemoteDesktopFrame`（二进制）。
        case desktopFrame = 26
        /// Mac 上的光标位置（归一化）。负载 = `RemoteDesktopCursor`。
        case desktopCursor = 27
        /// 本机 shell 开好了（或没开成）。负载 = `RemoteOpenLocalShellResult`（JSON）。
        case localShellOpened = 28
        /// 配对状态（只在通道 0）。负载 = `RemotePairingState` 的 rawValue（1 字节）。
        case pairing = 30
    }

    var kind: Kind
    var channel: UInt32
    var payload: Data

    init(_ kind: Kind, channel: UInt32 = 0, payload: Data = Data()) {
        self.kind = kind
        self.channel = channel
        self.payload = payload
    }

    static let headerSize = 5

    func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(kind.rawValue)
        data.append(contentsOf: [UInt8(truncatingIfNeeded: channel >> 24), UInt8(truncatingIfNeeded: channel >> 16),
                                 UInt8(truncatingIfNeeded: channel >> 8), UInt8(truncatingIfNeeded: channel)])
        data.append(payload)
        return data
    }

    init(decoding data: Data) throws {
        guard data.count >= Self.headerSize else { throw RemoteProtocolError.malformedMessage }
        let base = data.startIndex
        guard let kind = Kind(rawValue: data[base]) else { throw RemoteProtocolError.unknownMessage(data[base]) }
        self.kind = kind
        channel = data[(base + 1)..<(base + 5)].reduce(0) { $0 << 8 | UInt32($1) }
        payload = data.count > Self.headerSize ? Data(data[(base + 5)...]) : Data()
    }
}

nonisolated enum RemoteProtocolError: LocalizedError, Equatable {
    case malformedMessage
    case unknownMessage(UInt8)
    case frameTooLarge(Int)
    case versionMismatch(Int)
    case handshakeFailed(String)
    case decryptionFailed
    case peerIdentityChanged
    case notPaired
    case pairingRejected
    case timeout
    case closed

    var errorDescription: String? {
        switch self {
        case .malformedMessage: return "远控消息格式无效"
        case .unknownMessage(let kind): return "未知的远控消息类型 \(kind)"
        case .frameTooLarge(let bytes): return "远控数据帧过大（\(bytes) 字节）"
        case .versionMismatch(let version): return "远控协议版本不兼容（对端 \(version)，本机 \(RemoteConstants.protocolVersion)），请把两端更新到同一版本"
        case .handshakeFailed(let reason): return "远控握手失败：\(reason)"
        case .decryptionFailed: return "远控数据校验失败，连接已断开"
        case .peerIdentityChanged: return "这台 Mac 的身份与配对时不一致，已拒绝连接。若重装过 uTerm，请在手机上移除后重新配对"
        case .notPaired: return "这台设备尚未配对"
        case .pairingRejected: return "Mac 拒绝了配对请求"
        case .timeout: return "远控连接超时"
        case .closed: return "远控连接已断开"
        }
    }
}

/// 低频控制消息（会话列表、接入请求 / 结果）的 JSON 编解码。两端必须用同一套设置。
nonisolated enum RemoteJSON {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RemoteProtocolError.malformedMessage
        }
    }
}

/// 配对状态（Mac → 手机，通道 0）。
nonisolated enum RemotePairingState: UInt8, Sendable {
    /// 已信任，可以直接用。
    case trusted = 1
    /// 首次连接：Mac 正在等人点「允许」，手机此时应显示核对码。
    case awaitingApproval = 2
    case approved = 3
    case rejected = 4
}

/// Mac 上一条可接入的终端会话（手机端会话列表的一行）。
nonisolated struct RemoteSessionInfo: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    /// 对应的 `ServerProfile.id`。手机按它在本机找同一台主机来开标签（主机经 iCloud / 局域网同步过来）。
    var serverID: UUID
    var serverName: String
    var title: String
    /// `workspace` / `terminal`，同 `TerminalWindowKind`。
    var windowKind: String
    var connectedAt: Date?
    /// 当前被哪台设备接管（设备名），没有则为 nil。
    var controlledBy: String?
}

nonisolated struct RemoteGridSize: Equatable, Sendable {
    var cols: UInt16
    var rows: UInt16

    func encoded() -> Data {
        Data([UInt8(cols >> 8), UInt8(cols & 0xFF), UInt8(rows >> 8), UInt8(rows & 0xFF)])
    }

    init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }

    init(decoding data: Data) throws {
        guard data.count == 4 else { throw RemoteProtocolError.malformedMessage }
        let b = [UInt8](data)
        cols = UInt16(b[0]) << 8 | UInt16(b[1])
        rows = UInt16(b[2]) << 8 | UInt16(b[3])
        guard cols > 0, rows > 0 else { throw RemoteProtocolError.malformedMessage }
    }
}

nonisolated struct RemoteAttachRequest: Codable, Equatable, Sendable {
    var sessionID: UUID
    /// 手机终端此刻的行列数：Mac 先按它调整尺寸再拍快照，接入的第一帧就是对的。
    var cols: UInt16
    var rows: UInt16
}

nonisolated struct RemoteOpenLocalShellRequest: Codable, Equatable, Sendable {
    /// 回复里原样带回，手机据此认出是哪一次请求。
    var requestID: UUID
}

nonisolated struct RemoteOpenLocalShellResult: Codable, Equatable, Sendable {
    var requestID: UUID
    /// 开好的会话（之后按它 `.attach`）；失败时 nil。
    var sessionID: UUID?
    /// 失败原因（给人看的），成功时 nil。
    var error: String?
}

nonisolated struct RemoteAttachResult: Codable, Equatable, Sendable {
    var sessionID: UUID
    /// nil = 成功。
    var error: String?
}

/// 明文握手消息（加密信道建立之前双方各发一条）。整段字节进入握手记录哈希，
/// 所以任何一个字段被篡改，两端算出的会话密钥就不一样，第一帧密文即校验失败。
nonisolated struct RemoteHello: Codable, Equatable, Sendable {
    var version: Int
    var deviceID: UUID
    var deviceName: String
    /// 本次连接的临时公钥（X25519 原始 32 字节）。
    var ephemeralKey: Data
    /// 设备的长期公钥（X25519 原始 32 字节）。
    var staticKey: Data
    /// 可选能力（见 `RemoteFeature`）。P1 的版本不带这个键，解出来是 nil。
    var features: [String]? = nil

    func supports(_ feature: String) -> Bool {
        features?.contains(feature) ?? false
    }
}

/// 长度前缀分帧：`[u32 大端长度][帧内容]`。
///
/// 远控连接是长连接，所以和 `LANSyncFrameBuffer` 不同，这里**不设累计上限**，只限单帧；
/// 缓冲用读偏移推进、攒够一半再整体前移，避免每取一帧都把剩余字节整段拷贝一遍
/// （`cat` 大文件时每秒几十 MB 过这里）。
nonisolated struct RemoteFrameBuffer {
    private var buffer = Data()
    private var readOffset = 0

    init() {}

    var bufferedBytes: Int { buffer.count - readOffset }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        if readOffset > 0 && readOffset >= buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + readOffset))
            readOffset = 0
        }
        buffer.append(data)
    }

    /// 取下一帧；不够一帧返回 nil，长度非法抛错（连接应立即断开）。
    mutating func nextFrame() throws -> Data? {
        guard bufferedBytes >= 4 else { return nil }
        let start = buffer.startIndex + readOffset
        let length = buffer[start..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= RemoteConstants.maxFrameBytes else {
            throw RemoteProtocolError.frameTooLarge(length)
        }
        guard bufferedBytes >= 4 + length else { return nil }
        let frame = Data(buffer[(start + 4)..<(start + 4 + length)])
        readOffset += 4 + length
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        }
        return frame
    }

    static func frame(_ content: Data) throws -> Data {
        guard !content.isEmpty, content.count <= RemoteConstants.maxFrameBytes else {
            throw RemoteProtocolError.frameTooLarge(content.count)
        }
        let length = UInt32(content.count)
        var framed = Data(capacity: 4 + content.count)
        framed.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 0xFF),
                                   UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        framed.append(content)
        return framed
    }
}
