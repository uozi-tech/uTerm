import Foundation

/// 远控（手机接入 Mac 上的终端）协议常量。两端共用。
///
/// 服务类型必须同时写进两端 Info.plist 的 `NSBonjourServices`，否则 iOS 的浏览收不到结果、
/// macOS 沙盒里的广播也会被拒。
nonisolated enum RemoteConstants {
    static let serviceType = "_uterm-remote._tcp"
    /// Bonjour TXT 记录里放 Mac 设备 ID 的键：手机按它认 Mac，不按电脑名。
    static let deviceIDKey = "id"
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
    /// 扫码配对邀请的有效期。
    static let invitationLifetime: Duration = .seconds(600)
    /// Mac 把标签名的变化推给手机的最短间隔。
    static let tabTitlePushInterval: Duration = .seconds(1)
    /// 快照里带多少行历史。
    static let snapshotScrollback = 1000
    /// 本机支持的可选能力，握手时放进 `RemoteHello.features`。协议版本号不变：老版本对端
    /// 解码时忽略这个键，新版本据此判断对端能不能做某件事（例如老 Mac 不认桌面消息，
    /// 收到会当作未知消息断开整条连接，所以手机必须先看能力再发）。
    static let localFeatures: [String] = [RemoteFeature.desktop, RemoteFeature.desktopPaste,
                                          RemoteFeature.desktopClipboard, RemoteFeature.desktopPasteChunks,
                                          RemoteFeature.localShell,
                                          RemoteFeature.localWorkspaces,
                                          RemoteFeature.closeSession, RemoteFeature.terminalImage,
                                          RemoteFeature.heartbeat, RemoteFeature.keyConfirmation,
                                          RemoteFeature.relayConfig, RemoteFeature.desktopUnlock,
                                          RemoteFeature.desktopPause, RemoteFeature.linkFlow]
    /// Mac 本机 shell 在会话列表里的 `serverID`：不对应任何 `ServerProfile`，手机见到它就知道是「这台 Mac
    /// 自己」，标签用 Mac 的名字。
    static let localShellServerID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
}

/// 链路存活判定的时限。TCP keepalive 只能证明这一段网络通，而且空闲时要约 30 秒才报错，这期间手机上就是一张
/// 冻住的画面。所以手机在链路安静时主动 ping，Mac 也会断开长时间无声的手机。
nonisolated struct RemoteHeartbeat: Sendable {
    /// 手机：两个方向任一方向安静这么久就发 ping。
    var pingInterval: TimeInterval = 5
    /// 手机：这么久没收到任何字节，判定链路已死。
    var replyLimit: TimeInterval = 20
    /// 手机：网络变化或回到前台后探测一次，这么久没回音判定链路已死。
    var probeReplyLimit: TimeInterval = 5
    /// Mac：声明支持心跳的手机这么久无声就断开。
    var peerSilenceLimit: TimeInterval = 30

    static let standard = RemoteHeartbeat()
}

nonisolated enum RemoteFeature {
    /// 手机会定时 ping：Mac 可以放心断开长时间无声的手机。不声明这一项的老手机在空闲时不发任何东西，不能断。
    static let heartbeat = "heartbeat"
    /// 远程桌面（P2）：认得 `desktop*` 消息。
    static let desktop = "desktop"
    /// 远程桌面里粘贴手机的图片 / 文字：认得 `desktopPaste`。
    static let desktopPaste = "desktop-paste"
    /// 远程桌面里 Mac 拷贝的文字回传到手机：手机认得 `desktopClipboard`。Mac 只发给声明了这一项的手机。
    static let desktopClipboard = "desktop-clipboard"
    /// 大内容分块粘贴：认得 `desktopPasteChunk`。
    static let desktopPasteChunks = "desktop-paste-chunks"
    /// 能在 Mac 上开一个本机 shell：认得 `openLocalShell`。
    static let localShell = "local-shell"
    /// 能列出最近的工作区，并在指定目录开本机 shell：认得 `listLocalWorkspaces`。
    static let localWorkspaces = "local-workspaces"
    /// 手机关标签时能连 Mac 上的终端一起关：认得 `closeSession`。
    static let closeSession = "close-session"
    /// 能把手机的图片交给远控终端里的程序：认得 `terminalImage`。
    static let terminalImage = "terminal-image"
    /// 握手后手机先发一帧 `keyConfirm`，Mac 解开它才算认定对方持有长期私钥，再决定信任与授权。
    static let keyConfirmation = "key-confirm"
    /// 认得 `relayConfig` 消息。
    static let relayConfig = "relay-config"
    /// 远程桌面里的锁屏状态、远程解锁与帘幕模式：认得 `desktopScreenState` / `desktopUnlock` /
    /// `desktopUnlockResult` / `desktopCurtain`。两端都要声明，Mac 只给声明了的手机发状态。
    static let desktopUnlock = "desktop-unlock"
    /// 手机退到后台时让 Mac 暂停推流、回前台再接上：认得 `desktopPause`。老 Mac 不认这个类型（收到会当未知消息
    /// 断开整条连接），所以手机只对声明了这一项的 Mac 发；老 Mac 照旧推流，手机退回「照收照确认、不解码」。
    static let desktopPause = "desktop-pause"
    /// 远程桌面的声音：认得 `desktopAudio` / `desktopAudioFormat` / `desktopAudioFrame`。两端都要声明：
    /// 手机只对声明了的 Mac 发开关，Mac 只给声明了的手机送声音。
    static let desktopAudio = "desktop-audio"
    /// 链路层的端到端计量与分片（见 `RemoteLinkFlow`）：认得 `linkAck` / `linkFragment`。两端都声明才启用，
    /// 否则照旧整条消息直接交给 TCP。
    static let linkFlow = "link-flow"
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
        /// 关掉 Mac 上的一条会话（它所在的标签连同连接 / shell）（通道 0）。负载 = `RemoteCloseSessionRequest`
        ///（JSON）。手机关远控标签时选了「同时关闭 Mac 上的终端」才发；只发给 `features` 带 `close-session` 的 Mac。
        case closeSession = 8
        /// 把一张图片交给接入的终端（终端通道）。负载 = `RemoteTerminalImageRequest`（二进制）。Mac 按会话的类型
        /// 处理：本机 shell 放进剪贴板并按 Ctrl+V，SSH 会话传成服务器 `/tmp` 下的文件；回 `.terminalImageResult`。
        /// 只发给 `features` 带 `terminal-image` 的 Mac。
        case terminalImage = 9
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
        /// 要 Mac 最近的工作区（通道 0）。负载 = `RemoteLocalWorkspacesRequest`（JSON）。Mac 回 `.localWorkspaces`。
        /// 只发给 `features` 带 `local-workspaces` 的 Mac。
        case listLocalWorkspaces = 16
        /// 握手后的第一帧（通道 0，无负载）。会话密钥绑定了双方的长期私钥，能发出 Mac 解得开的密文就证明了身份。
        /// 只发给 `features` 带 `key-confirm` 的 Mac。
        case keyConfirm = 17
        /// 这些视频帧等到时限也没收齐，放弃了（桌面通道）。负载 = `RemoteDesktopVideoLost`。Mac 据此释放在途计数，
        /// 发一个恢复帧。只在开流时协商了 `videoDatagrams` 才会发。
        case desktopVideoLost = 18
        /// 大内容粘贴的一块（桌面通道）。负载 = `RemoteDesktopPasteChunk`。公网上一张图要传十几秒，
        /// 整条发的话按键和确认都得排在它后面。只发给 `features` 带 `desktop-paste-chunks` 的 Mac。
        case desktopPasteChunk = 19

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
        /// 图片交好了（或没成）（通道 0）。负载 = `RemoteTerminalImageResult`（JSON）。
        case terminalImageResult = 29
        /// 配对状态（只在通道 0）。负载 = `RemotePairingState` 的 rawValue（1 字节）。
        case pairing = 30
        /// 最近的工作区。负载 = `RemoteLocalWorkspaces`（JSON）。
        case localWorkspaces = 31
        /// 手机控制桌面时 Mac 上新拷贝的文字（桌面通道）。负载 = `RemoteDesktopClipboard`（二进制）。
        /// 只发给 `features` 带 `desktop-clipboard` 的手机。
        case desktopClipboard = 32
        /// 中继配置（通道 0）。负载 = `RemoteRelayConfig`（JSON）。只发给 Mac 上勾选过公网接入、且 `features` 带
        /// `relay-config` 的设备，扫码配对、不共用 iCloud 钥匙串的手机靠它拿到配置。
        case relayConfig = 33
        /// 画面往返（桌面通道）。负载 = `RemoteDesktopLatency`（JSON）。只在开流时 `latencyStats` 为 true 才发，
        /// 老手机不认这个类型（解析会当成坏消息），所以必须先要后发。
        case desktopLatency = 34
        /// Mac 的锁屏 / 帘幕状态（桌面通道）。负载 = `RemoteDesktopScreenState`（JSON）。开流后发一次，变化时再发。
        /// 只发给 `features` 带 `desktop-unlock` 的手机。
        case desktopScreenState = 35
        /// 解锁结果（桌面通道）。负载 = `RemoteDesktopUnlockResult`（JSON）。
        case desktopUnlockResult = 36

        // 手机 → Mac（20–34 已被 Mac → 手机占满，新的接着往后编）
        /// 用密码解锁 Mac 的锁屏（桌面通道）。负载 = `RemoteDesktopUnlockRequest`（JSON）。只发给 `features` 带
        /// `desktop-unlock` 的 Mac。
        case desktopUnlock = 37
        /// 打开 / 关闭帘幕模式（桌面通道）。负载 = `RemoteDesktopCurtainRequest`（JSON）。
        case desktopCurtain = 38
        /// 打开 / 关闭声音（桌面通道）。负载 = `RemoteDesktopAudioRequest`（JSON）。只发给 `features` 带
        /// `desktop-audio` 的 Mac。
        case desktopAudio = 39

        // Mac → 手机（续）
        /// 声音流的格式（桌面通道）。负载 = `RemoteDesktopAudioFormat`（JSON）。只发给声明了 `desktop-audio` 的手机。
        case desktopAudioFormat = 40
        /// 一包声音（桌面通道）。负载 = `RemoteDesktopAudioFrame`（二进制）。
        case desktopAudioFrame = 41

        // 两个方向（链路层，`RemoteLink` 自己收发，不交给上层）
        /// 累计收到多少链路字节（`[u64]`，通道 0）。只在两端都声明 `link-flow` 时发。
        case linkAck = 42
        /// 大消息的一片（`[u8 标志][u8 队列][片]`，通道 0）。拼齐后按原消息交给上层。只在两端都声明 `link-flow` 时发。
        case linkFragment = 43

        // 之后的编号与声音、链路层无关
        /// 暂停 / 恢复推流（桌面通道）。负载 = `RemoteDesktopPauseRequest`（JSON）。手机退到后台时发「暂停」，
        /// 回前台发「恢复」——恢复同时就是关键帧请求。只发给 `features` 带 `desktop-pause` 的 Mac。
        case desktopPause = 44
        /// Mac 上光标的形状（桌面通道）：形状变了才发。负载 = `RemoteDesktopCursorImage`（JSON）。
        /// 只在开流请求带 `cursorImages` 时才发，老客户端不认这个类型。
        case desktopCursorImage = 45
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
        case .malformedMessage: return "远程控制消息格式无效"
        case .unknownMessage(let kind): return "未知的远程控制消息类型 \(kind)"
        case .frameTooLarge(let bytes): return "远程控制数据帧过大（\(bytes) 字节）"
        case .versionMismatch(let version): return "远程控制协议版本不兼容（对端 \(version)，本机 \(RemoteConstants.protocolVersion)），把两端的 uTerm 更新到同一版本"
        case .handshakeFailed(let reason): return "远程控制握手失败：\(reason)"
        case .decryptionFailed: return "远程控制数据校验失败，连接已断开"
        case .peerIdentityChanged: return "这台 Mac 的身份与配对时不一致，已拒绝连接。若重装过 uTerm，在手机上移除这台 Mac 后重新配对"
        case .notPaired: return "这台设备尚未配对"
        case .pairingRejected: return "Mac 拒绝了配对请求"
        case .timeout: return "远程控制连接超时"
        case .closed: return "远程控制已断开"
        }
    }

    /// 重试也没用的错误（配对被拒、身份变了、协议版本不兼容）。其余都按网络问题对待，可以重试。
    var isPermanent: Bool {
        switch self {
        case .versionMismatch, .peerIdentityChanged, .notPaired, .pairingRejected:
            return true
        case .malformedMessage, .unknownMessage, .frameTooLarge, .handshakeFailed, .decryptionFailed, .timeout, .closed:
            return false
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
    /// 对应的 `ServerProfile.id`；Mac 本机 shell 是 `localShellServerID`。手机不要求这台主机已同步过来。
    var serverID: UUID
    var serverName: String
    /// 标签打开时定下的稳定名字（`zsh 2`、服务器名）。
    var title: String
    /// `workspace` / `terminal`，同 `TerminalWindowKind`。
    var windowKind: String
    var connectedAt: Date?
    /// 当前被哪台设备接管（设备名），没有则为 nil。
    var controlledBy: String?
    /// Mac 标签上此刻显示的名字，跟着程序设的标题变。老版本 Mac 不发这个键。
    var tabTitle: String? = nil

    var displayTitle: String { tabTitle ?? title }
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

nonisolated struct RemoteCloseSessionRequest: Codable, Equatable, Sendable {
    var sessionID: UUID
}

/// 手机 → Mac：`[16 字节请求 id][u8 格式][图片字节]`。整条要放进一帧，图片超了由手机先压。
nonisolated struct RemoteTerminalImageRequest: Equatable, Sendable {
    static let maxImageBytes = RemoteDesktopPaste.maxContentBytes

    var requestID: UUID
    var image: TerminalImage

    func encoded() -> Data {
        var writer = RemoteByteWriter(capacity: 17 + image.data.count)
        withUnsafeBytes(of: requestID.uuid) { writer.bytes(Data($0)) }
        writer.u8(image.format.rawValue)
        writer.bytes(image.data)
        return writer.data
    }

    init(requestID: UUID, image: TerminalImage) {
        self.requestID = requestID
        self.image = image
    }

    init(decoding payload: Data) throws {
        guard payload.count > 17 else { throw RemoteProtocolError.malformedMessage }
        let bytes = [UInt8](payload.prefix(16))
        requestID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        guard let format = TerminalImage.Format(rawValue: payload[payload.startIndex + 16]) else {
            throw RemoteProtocolError.malformedMessage
        }
        let data = Data(payload.dropFirst(17))
        guard data.count <= Self.maxImageBytes else { throw RemoteProtocolError.malformedMessage }
        image = TerminalImage(format: format, data: data)
    }
}

nonisolated struct RemoteTerminalImageResult: Codable, Equatable, Sendable {
    var requestID: UUID
    /// 传成了文件时的路径（手机把它粘进终端）；放进剪贴板时 nil。
    var path: String?
    /// 失败原因（给人看的），成功时 nil。
    var error: String?

    init(requestID: UUID, path: String? = nil, error: String? = nil) {
        self.requestID = requestID
        self.path = path
        self.error = error
    }
}

nonisolated struct RemoteOpenLocalShellRequest: Codable, Equatable, Sendable {
    /// 回复里原样带回，手机据此认出是哪一次请求。
    var requestID: UUID
    /// Mac 上的工作目录，nil = 主目录。老 Mac 不读这个键，所以只在对端声明 `local-workspaces` 时才有可选的目录。
    var directory: String? = nil
}

nonisolated struct RemoteLocalWorkspacesRequest: Codable, Equatable, Sendable {
    var requestID: UUID
}

nonisolated struct RemoteLocalWorkspaces: Codable, Equatable, Sendable {
    var requestID: UUID
    /// Mac 上的主目录，显示路径时缩写成 `~`。
    var home: String
    /// 绝对路径，最相关的在前。不含主目录。
    var directories: [String]

    /// `~/Workspace/uTerm` 这种给人看的写法。两端的菜单都用它。
    nonisolated static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
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
    /// 手机扫码配对后第一次连接时带上的凭据（见 `RemotePairingInvitation.proof`）。握手消息整段进密钥推导，
    /// 中途改不了。
    var pairingProof: Data? = nil
    /// 机型的商品名（如「iPhone 16 Pro」，见 `RemoteDeviceModel`）。只作展示；老版本不带这个键。
    /// 握手按收到的原始字节做转录，多出来的键不影响老版本对端认证。
    var deviceModel: String? = nil
    /// 对端是什么设备（`RemoteDevicePlatform` 的原始值），只作展示。用字符串不用枚举：以后多一种取值，
    /// 老版本解不出整条握手消息。老版本不带这个键。
    var platform: String? = nil

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
