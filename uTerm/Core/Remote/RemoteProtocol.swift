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
    /// 镜像快照里带多少行回滚（`ShadowTerminal.snapshot(scrollbackLines:)`，引擎按页裁，实际略少）。整段回滚 3000 行
    /// 逐字换色的历史一张 2.7 MB、10 万行几十 MB，积压上限只有 1 MB，窄链路上追不上。holder 检查点不受它限制、带全量。
    static let snapshotScrollback = 1000
    /// 接入时第一张镜像快照最多等终端按对端尺寸钉好多久（`TerminalMirrorTap.subscribe(firstSnapshotWhen:)`）。
    static let attachGridSettleTimeout: TimeInterval = 1
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
                                          RemoteFeature.desktopUnlockOutcomes,
                                          RemoteFeature.desktopPause, RemoteFeature.linkFlow, RemoteFeature.desktopAudio,
                                          RemoteFeature.desktopAudioLossless, RemoteFeature.programStatus,
                                          RemoteFeature.files, RemoteFeature.deviceVouch,
                                          RemoteFeature.siblingRevoke, RemoteFeature.desktopWindows,
                                          RemoteFeature.desktopRegion, RemoteFeature.desktopPasteFiles,
                                          RemoteFeature.desktopWindowFront, RemoteFeature.desktopWindowRefit,
                                          RemoteFeature.desktopWindowInput, RemoteFeature.desktopAuthPrompt,
                                          RemoteFeature.arrangeSessions, RemoteFeature.terminalReplay]
    /// 文件服务的请求与应答都走这个通道。终端和桌面的通道号从 1 往上数，碰不到它；单独一个通道是为了让
    /// 链路排队（`RemoteLinkFlow`）把文件数据和按键、终端输出轮着发，传大文件时打字不卡。
    static let fileChannel: UInt32 = 0xFFFF_F11E
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
    /// 手机：回前台时本机已经这么久没发出任何东西，Mac 一定已经断开了（它每 `peerSilenceLimit / 3` 查一次，
    /// 最晚 `peerSilenceLimit × 4/3` 动手，再留 2 秒余量），不用探测，直接重连。
    var resumeDropLimit: TimeInterval = 42
    /// 手机：链路一直有数据在走（开着屏幕、终端在刷）时也隔这么久 ping 一次，好让往返读数不断档。
    /// 只按「安静了才 ping」的话，流不停就永远测不到往返。
    var roundTripRefresh: TimeInterval = 15
    /// 手机：开着远程桌面（数据本该一直在走）时，安静这么久就 ping。
    var activeQuietPing: TimeInterval = 1
    /// 手机：开着远程桌面时，ping 发出后这么久一个字节都没收到就判死。实测往返长时按 3 倍往返放宽，
    /// 拥塞但还活着的中继（往返十几秒）不会被误判。
    var activeReplyLimit: TimeInterval = 2.5
    /// 开着远程桌面时检查得勤一点（平时约 1.7 秒一拍）。
    var activeTick: TimeInterval = 0.5

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
    /// 认得解锁结果里的 `inputBlocked`。老手机不认（整条结果解不开、等到超时），Mac 只对声明了的发，
    /// 对老手机退回 `stillLocked`。
    static let desktopUnlockOutcomes = "desktop-unlock-outcomes"
    /// 手机退到后台时让 Mac 暂停推流、回前台再接上：认得 `desktopPause`。老 Mac 不认这个类型（收到会当未知消息
    /// 断开整条连接），所以手机只对声明了这一项的 Mac 发；老 Mac 照旧推流，手机退回「照收照确认、不解码」。
    static let desktopPause = "desktop-pause"
    /// 远程桌面的声音：认得 `desktopAudio` / `desktopAudioFormat` / `desktopAudioFrame`。两端都要声明：
    /// 手机只对声明了的 Mac 发开关，Mac 只给声明了的手机送声音。
    static let desktopAudio = "desktop-audio"
    /// 声音的无损档（ALAC）：认得 `RemoteAudioCodec.alac`。老 Mac 解手机的编码列表时遇到不认识的值会整条请求
    /// 解不开，所以手机只对声明了这一项的 Mac 列无损；Mac 只在手机列了时才用。
    static let desktopAudioLossless = "desktop-audio-lossless"
    /// 终端里程序（Claude Code、Codex……）的状态：认得 `programStatus`。Mac 只给声明了的设备推；
    /// 老 Mac 不推，设备上的标签照旧只显示连接状态。
    static let programStatus = "program-status"
    /// 两端终端引擎的快照格式不互认时，镜像快照改成回放流（`RemoteTerminalReplay`）：设备认得它、按本机引擎重画；
    /// Mac 会对这样的设备改发。两端都要声明，缺一边就照旧拒绝镜像（老设备收到回放流会当二进制快照，解不开）。
    static let terminalReplay = "terminal-replay"
    /// 链路层的端到端计量与分片（见 `RemoteLinkFlow`）：认得 `linkAck` / `linkFragment`。两端都声明才启用，
    /// 否则照旧整条消息直接交给 TCP。
    static let linkFlow = "link-flow"
    /// 文件服务：认得 `fileRequest` / `fileReply`（列目录、读写、搜索、跑命令，见 `RemoteFileWire`）。
    /// 老 Mac 收到 `fileRequest` 会当未知消息断开整条连接，所以主控端只对声明了这一项的 Mac 发。
    static let files = "files"
    /// 反过来的文件服务：主控端（Mac）答被控 Mac 发来的 `fileRequest`，范围限在主控端共享出去的文件夹里。
    /// 只有主控端声明；被控的 Mac 只对声明了这一项的设备发（手机、老版本的 Mac 收到会当未知消息处理）。
    static let fileSharing = "file-sharing"
    /// 认得 `vouchDevice`：已配对的设备可以请这台 Mac 记下同一个人的另一台设备（见 `RemoteVouch.swift`）。
    /// 能力只说明认得这条消息；Mac 上关掉了「允许担保」时照样回 `notAllowed`。
    static let deviceVouch = "device-vouch"
    /// 认得 `revokeSibling`：同一组（经担保添加的）设备可以请这台 Mac 撤销其中丢了的那台。
    static let siblingRevoke = "sibling-revoke"
    /// 远程桌面只看一个窗口：认得 `desktopWindows` / `desktopWindowList` / `desktopGeometry`，开流请求里的
    /// `windowID` 生效。老 Mac 不认 `windowID`（照旧给整块显示器）、收到 `desktopWindows` 会断开整条连接，
    /// 所以主控端只对声明了这一项的 Mac 列窗口、按窗口开流；Mac 只在按窗口开的流上发 `desktopGeometry`。
    static let desktopWindows = "desktop-windows"
    /// 远程桌面放大后按看得见的那块重新取画面：Mac 认得 `desktopRegion`，主控端认得视频帧头里的区域
    ///（`RemoteDesktopFrame.Flags.hasRegion`）。老 Mac 收到 `desktopRegion` 会断开整条连接，所以主控端只对声明了的
    /// Mac 发；Mac 只在收到过 `desktopRegion` 的流上发带区域的帧（老主控端不发，也就收不到）。
    static let desktopRegion = "desktop-region"
    /// 远程桌面里把主控端的一个文件（视频）贴过来：Mac 认得 `desktopPasteFile`，边收边写进文件，收齐后把文件放进
    /// 剪贴板、按 ⌘V。老 Mac 收到会断开整条连接，所以主控端只对声明了的 Mac 发。
    static let desktopPasteFiles = "desktop-paste-files"
    /// 远程桌面只看一个窗口时能把它保持在最前：开流请求里的 `windowKeepFront` 生效。老 Mac 不认这个键
    /// （什么都不做），主控端据此决定显不显示那个开关。
    static let desktopWindowFront = "desktop-window-front"
    /// 只看一个窗口时能不停流原地换尺寸：Mac 认得 `desktopWindowRefit`（改窗口大小、改采集参数、按新尺寸重建编码器，
    /// 同一条流接着出画面），并在 `desktopGeometry` 里带上新的视频像素数。老 Mac 收到这条消息会断开整条连接，
    /// 主控端只对声明了它的 Mac 发，否则照旧停流再按新尺寸开。
    static let desktopWindowRefit = "desktop-window-refit"
    /// 只看一个窗口时输入能直接投给窗口所在的进程（不动 Mac 上的指针）：开流请求里的 `windowIndependentInput` 生效。
    /// 老 Mac 不认这个键（照旧走全局输入通道），主控端据此决定显不显示那个开关。
    static let desktopWindowInput = "desktop-window-input"
    /// 远程桌面里过 Mac 上的系统验证框（Touch ID / 密码）：Mac 在 `desktopScreenState` 里带 `authPrompt`、
    /// 认得 `desktopAuthPrompt`；主控端认得 `authPrompt` 与 `desktopAuthPromptResult`。老 Mac 收到
    /// `desktopAuthPrompt` 会断开整条连接，所以主控端只对声明了的 Mac 发；Mac 只给声明了的主控端报框。
    static let desktopAuthPrompt = "desktop-auth-prompt"
    /// 设备上亲手排过这台 Mac 的标签，Mac 跟着排：Mac 认得 `arrangeSessions`。老 Mac 收到会断开整条连接，
    /// 所以主控端只对声明了的 Mac 发；老 Mac 照旧只是设备这边自己排。
    static let arrangeSessions = "arrange-sessions"
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
        /// 大消息的一片（`[u8 标志（bit0 = 最后一片）][u32 原消息的通道][片]`，通道 0）。拼齐后按原消息交给上层。只在两端都声明 `link-flow` 时发。
        case linkFragment = 43

        // 之后的编号与声音、链路层无关
        /// 暂停 / 恢复推流（桌面通道）。负载 = `RemoteDesktopPauseRequest`（JSON）。手机退到后台时发「暂停」，
        /// 回前台发「恢复」——恢复同时就是关键帧请求。只发给 `features` 带 `desktop-pause` 的 Mac。
        case desktopPause = 44
        /// Mac 上光标的形状（桌面通道）：形状变了才发。负载 = `RemoteDesktopCursorImage`（JSON）。
        /// 只在开流请求带 `cursorImages` 时才发，老客户端不认这个类型。
        case desktopCursorImage = 45
        /// 各终端里程序的状态（通道 0）。负载 = `RemoteProgramStatusUpdate`（JSON）。订阅会话列表后先发一份
        /// 全量快照，之后只发变了的会话。中途接入的设备看不到早先的 OSC 7501，所以状态由 Mac 记着、推过来，
        /// 不靠设备自己解析镜像字节。只发给 `features` 带 `program-status` 的设备。
        case programStatus = 46
        /// 终端画面的整屏快照（终端通道，Mac → 设备）：接入时、改尺寸后、对端积压过多时发，之后的 `output` 接着它。
        /// 负载 = 1 字节标志（`RemoteTerminalSnapshotPiece`）+ 影子终端二进制快照的一段。快照可以很大，切成多条发。
        /// 两端引擎的快照格式互认（握手里的 `terminalEngine`）时发二进制快照；不互认、两端又都声明了 `terminal-replay`
        /// 时，拼齐的那一张换成回放流（`RemoteTerminalReplay`，开头有自己的标记）。别的情况不接入。
        case terminalSnapshot = 47
        /// 反方向也用这一对：被控的 Mac → 声明了 `file-sharing` 的主控端发请求，主控端回应答。
        /// 主控端 → Mac：一条文件请求（`RemoteConstants.fileChannel`）。负载是 `RemoteFileCodec` 打包的
        /// `RemoteFileRequest` 加正文。只发给 `features` 带 `files` 的 Mac。
        case fileRequest = 48
        /// Mac → 主控端：对应的应答（同一通道）。负载是打包的 `RemoteFileReply` 加正文，按请求号对上。
        case fileReply = 49
        /// 主控端 → Mac：请 Mac 记下同一个人的另一台设备（通道 0）。负载 = `RemoteVouchRequest`（JSON）。
        /// 只发给 `features` 带 `device-vouch` 的 Mac。
        case vouchDevice = 50
        /// Mac → 主控端：担保的结果（通道 0）。负载 = `RemoteVouchResult`（JSON）。
        case vouchResult = 51
        /// 主控端 → Mac：撤销同一组里丢了的那台设备（通道 0）。负载 = `RemoteSiblingRevokeRequest`（JSON）。
        /// 只发给 `features` 带 `sibling-revoke` 的 Mac。
        case revokeSibling = 52
        /// Mac → 主控端：撤销的结果（通道 0）。负载 = `RemoteSiblingRevokeResult`（JSON）。
        case revokeSiblingResult = 53
        /// 主控端 → Mac：要此刻能单独看的窗口（通道 0）。负载 = `RemoteDesktopWindowListRequest`（JSON）。
        /// 只发给 `features` 带 `desktop-windows` 的 Mac。
        case desktopWindows = 54
        /// Mac → 主控端：窗口列表（通道 0）。负载 = `RemoteDesktopWindowList`（JSON）。
        case desktopWindowList = 55
        /// Mac → 主控端：只看一个窗口时，画面对应的范围变了（桌面通道）。负载 = `RemoteDesktopGeometryUpdate`（JSON）。
        /// 窗口改了大小、弹出的菜单伸出窗口时发；只在按窗口开的流上发。
        case desktopGeometry = 56
        /// 主控端 → Mac：画面放大了，此刻只看得见这一块（桌面通道）。负载 = `RemoteDesktopRegionRequest`（JSON）。
        /// Mac 改成只取这一块（加一圈余量）、按原生像素出，帧头里带上取的是哪一块。只发给带 `desktop-region` 的 Mac。
        case desktopRegion = 57
        /// 粘贴文件的一块（桌面通道）。负载 = `RemoteDesktopPasteFileChunk`。只发给 `features` 带
        /// `desktop-paste-files` 的 Mac。
        case desktopPasteFile = 58
        /// 主控端 → Mac：正在看的这个窗口按新尺寸重调（负载是 `RemoteDesktopFit`，点），不停流。
        case desktopWindowRefit = 59
        /// 主控端 → Mac：回应屏上的系统验证框（桌面通道）。负载 = `RemoteDesktopAuthPromptRequest`（JSON）。
        /// 只发给 `features` 带 `desktop-auth-prompt` 的 Mac。
        case desktopAuthPrompt = 60
        /// Mac → 主控端：回应验证框的结果（桌面通道）。负载 = `RemoteDesktopAuthPromptResult`（JSON）。
        case desktopAuthPromptResult = 61
        /// 主控端 → Mac：设备上亲手排过这台 Mac 的标签（通道 0）。负载 = `RemoteArrangeSessionsRequest`（JSON）。
        /// Mac 的每个标签组照它排，只在组里这些标签原来的位置之间换（不跨组、不跨窗口、不换前台），排完照常推新的列表。
        /// 只发给 `features` 带 `arrange-sessions` 的 Mac。
        case arrangeSessions = 62
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
        case .malformedMessage: return String(localized: "远程控制消息格式无效")
        case .unknownMessage(let kind): return String(localized: "未知的远程控制消息类型 \(String(kind))")
        case .frameTooLarge(let bytes): return String(localized: "远程控制数据帧过大（\(bytes) 字节）")
        case .versionMismatch(let version):
            return String(localized: "远程控制协议版本不兼容（对端 \(String(version))，本机 \(String(RemoteConstants.protocolVersion))），把两端的 uTerm 更新到同一版本")
        case .handshakeFailed(let reason): return String(localized: "远程控制握手失败：\(reason)")
        case .decryptionFailed: return String(localized: "远程控制数据校验失败，连接已断开")
        case .peerIdentityChanged: return String(localized: "这台 Mac 的身份与配对时不一致，已拒绝连接。若重装过 uTerm，在手机上移除这台 Mac 后重新配对")
        case .notPaired: return String(localized: "这台设备尚未配对")
        case .pairingRejected: return String(localized: "Mac 拒绝了配对请求")
        case .timeout: return String(localized: "远程控制连接超时")
        case .closed: return String(localized: "远程控制已断开")
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
    /// 在 Mac 上的排位（0 起）：窗口按打开先后，窗口里的组从左到右、从上到下，组里按标签顺序。列表本身也按它排。
    /// 老版本 Mac 不发这个键，那时设备上的标签保持原来的顺序。
    var order: Int? = nil

    var displayTitle: String { tabTitle ?? title }
}

extension Array where Element == RemoteSessionInfo {
    /// Mac 上的标签顺序；有哪一条没带排位（老版本 Mac）就是 nil，设备上的标签别跟着动。
    nonisolated var macTabOrder: [UUID]? {
        let ranked = compactMap { info in info.order.map { (rank: $0, id: info.id) } }
        guard !isEmpty, ranked.count == count else { return nil }
        return ranked.sorted { $0.rank < $1.rank }.map(\.id)
    }
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

nonisolated struct RemoteArrangeSessionsRequest: Codable, Equatable, Sendable {
    /// 设备上这台 Mac 的标签此刻的先后（会话 id）。只带用户刚排过的那一格里的，别的格里的标签 Mac 不动它们的相对先后。
    var order: [UUID]
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
    /// 失败是暂时的（Mac 上的 uTerm 正在重启，远控进程替它撑着）：手机按退避再试，不要结束标签。
    /// 老版本 Mac 不发（nil），老版本手机不认，各自照旧把失败当成会话结束。
    var retryable: Bool? = nil
}

/// 明文握手消息（加密信道建立之前双方各发一条）。整段字节进入握手记录哈希，
/// 所以任何一个字段被篡改，两端算出的会话密钥就不一样，第一帧密文即校验失败。
/// `terminalSnapshot` 负载开头的那个字节。
nonisolated enum RemoteTerminalSnapshotPiece {
    /// 一张新快照的第一段：接收端丢掉手上没收完的那张。
    static let first: UInt8 = 1
    /// 最后一段：收齐了，可以还原。
    static let last: UInt8 = 2

    static func encode(_ data: Data, isFirst: Bool, isLast: Bool) -> Data {
        var payload = Data(capacity: data.count + 1)
        payload.append((isFirst ? first : 0) | (isLast ? last : 0))
        payload.append(data)
        return payload
    }

    static func decode(_ payload: Data) -> (data: Data, isFirst: Bool, isLast: Bool)? {
        guard let flags = payload.first else { return nil }
        // 切片，不拷贝（快照一段可达几百 KB）。
        return (payload.dropFirst(), flags & first != 0, flags & last != 0)
    }
}

/// 两端终端引擎版本不同时怎么镜像：快照格式互认就照常发二进制快照；不互认但两端都认得回放流，就改发回放流；
/// 都不行才拒绝。
nonisolated enum RemoteTerminalEngine {
    static var mismatchMessage: String { String(localized: "两端的终端引擎版本不同，没法镜像终端。把两端的 uTerm 更新到同一版本") }

    /// 对端握手里报的引擎版本和本机的快照互认才行（同一个版本，或者只差渲染补丁，见
    /// `TerminalEngineVersion.sameSnapshotFormat`）；老版本不报，同样不行。远控进程里 `local` 是 App 报来的版本。
    static func matches(_ remote: String?, local: String = TerminalEngineVersion.current) -> Bool {
        guard let remote else { return false }
        return TerminalEngineVersion.snapshotsCompatible(remote, local)
    }

    /// 接入这台对端时快照用哪种格式；nil = 不能接入。`replayBothWays`：两端都声明了 `terminal-replay`。
    static func snapshotFormat(peer remote: String?, replayBothWays: Bool,
                               local: String = TerminalEngineVersion.current) -> RemoteTerminalSnapshotFormat? {
        if matches(remote, local: local) { return .binary }
        return replayBothWays ? .replay : nil
    }
}

/// 镜像快照的两种格式。原始值走 XPC（`RemoteHostAgentAttach.snapshotFormat`），已有的值不改。
nonisolated enum RemoteTerminalSnapshotFormat: String, Codable, Sendable {
    /// 影子终端的二进制快照（`ShadowTerminal.snapshot`），对端引擎的快照格式和本机互认才解得开。
    case binary
    /// 回放流（`RemoteTerminalReplay`）：哪个版本的引擎都吃得下。
    case replay
}

/// 快照格式不互认时代替二进制快照发的那一张：`[标记][u16 列][u16 行][回放流]`，回放流是按这个网格重画这一屏的 VT 字节
/// （`ShadowTerminal.replayStream`，最近 `RemoteConstants.snapshotScrollback` 行回滚）。设备收齐后按带来的尺寸在本机
/// 引擎里重画、再拍一张自己的快照，之后照常还原。代价同 holder 检查点的回放流：命令标记这类引擎内部的状态不在里面；
/// 二进制快照能带着没走完的半个转义序列，回放流不能，快照恰好拍在序列中间时接下来几个字节可能显示成乱码。
/// 远控进程不链接引擎，这里只有编解码。
nonisolated enum RemoteTerminalReplay {
    /// 二进制快照的开头是引擎自己的标记，不会是这一串。
    private static let magic = Array("uTermRP\u{1}".utf8)

    static func encode(cols: UInt16, rows: UInt16, stream: Data) -> Data {
        var data = Data(capacity: magic.count + 4 + stream.count)
        data.append(contentsOf: magic)
        data.append(contentsOf: [UInt8(cols >> 8), UInt8(cols & 0xFF), UInt8(rows >> 8), UInt8(rows & 0xFF)])
        data.append(stream)
        return data
    }

    /// 不是回放流（二进制快照）返回 nil。
    static func decode(_ data: Data) -> (cols: UInt16, rows: UInt16, stream: Data)? {
        guard data.count >= magic.count + 4, data.starts(with: magic) else { return nil }
        let start = data.startIndex + magic.count
        let cols = UInt16(data[start]) << 8 | UInt16(data[start + 1])
        let rows = UInt16(data[start + 2]) << 8 | UInt16(data[start + 3])
        return (cols, rows, Data(data[(start + 4)...]))
    }
}

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
    /// 终端引擎的版本（`TerminalEngineVersion.current`）。终端镜像的快照是引擎的二进制格式，两端不同就不接入终端
    /// （见 `RemoteTerminalEngine`）；远程桌面不受影响。
    var terminalEngine: String? = nil

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
