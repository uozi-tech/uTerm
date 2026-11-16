import Foundation

/// App 与远控进程（`uTermRemoteHost.app`，包内的沙盒 LaunchAgent）之间的约定。
///
/// 远控进程持有被控端的全部网络与采集：监听、中继、打洞、`RemoteLink`、桌面、文件。App 更新、崩溃、被强制结束时
/// 它不受影响，已建立的远控连接不断；终端字节仍由 App 提供，经这条 XPC 连接转过去（方案见
/// `docs/remote-control-daemon-plan.md`）。
///
/// **只加不改**：远控进程会跨越 App 的版本运行（App 更新后旧的远控进程可能还在服务），所以 XPC 方法只能加、不能改签名；
/// JSON 负载只加可选字段，枚举只加 case，解不开的一律忽略。
nonisolated enum RemoteHostAgent {
    /// launchd 任务名，也是 `MachServices` 里的服务名（App 的 entitlement 里有对应的 mach-lookup 例外）。
    static let machServiceName = "com.uozi.uTerm.RemoteHost"
    /// `Contents/Library/LaunchAgents/` 下的 plist 文件名（`SMAppService.agent(plistName:)`）。
    static let plistName = "com.uozi.uTerm.RemoteHost.plist"
    static let bundleIdentifier = "com.uozi.uTerm.RemoteHost"
    /// 这一版说的协议版本。只在不兼容时加一（加方法、加字段不算）。
    static let protocolVersion = 1

    /// 远控进程只接受同团队签名的 uTerm 主程序来连。
    static let appRequirement =
        "anchor apple generic and identifier \"com.uozi.uTerm\" and certificate leaf[subject.OU] = \"ABCDE12345\""
    /// App 只认同团队签名的远控进程。
    static let agentRequirement =
        "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"ABCDE12345\""

    /// App 不在时还对外服务多久（崩溃、被强制结束）。
    static let defaultGrace: Duration = .seconds(120)
    /// App 说自己要更新时的宽限期（Sparkle 下载完、替换、重启要更久）。新 App 一连上、版本对不上，远控进程就退出换新。
    static let updateGrace: Duration = .seconds(300)
    /// App 连续这么多次连上远控进程却等不到握手回话，就注销再注册它（换掉核不过签名的旧进程）。
    static let unansweredHelloLimit = 3
    /// 发出握手后最多等多久。正常冷启动约 1 秒；launchd 拉不起进程时连接不会断，靠它算作一次不回话。
    static let helloTimeout: Duration = .seconds(10)
    /// App 不在期间，开本机终端这类要 App 办的请求最多等多久。
    static let appRequestWait: Duration = .seconds(15)
    /// 每个终端接入的信用窗口：App 最多先送这么多字节，远控进程交给链路多少再补多少。
    static let terminalCreditWindow = 512 * 1024
}

// MARK: - XPC 接口

/// 远控进程导出、App 调用。
@objc nonisolated protocol RemoteHostAgentXPC {
    /// 第一条消息：App 的身份、秘密、设置、会话（`RemoteHostAgentHello`）。回 `RemoteHostAgentInfo`。
    func hello(_ payload: Data, reply: @escaping @Sendable (Data) -> Void)
    /// 设置变了（`RemoteHostAgentSettings`）。
    func configure(_ payload: Data)
    /// 会话目录变了（`RemoteHostAgentSessions`）。
    func updateSessions(_ payload: Data)
    /// 远控进程发起的接入（`terminalAttach`）的结果。`error` 为 nil 表示成功。
    func terminalAttached(_ attachment: String, error: String?)
    /// 一段终端数据（`RemoteHostTerminalChunkKind`）。
    func terminalChunk(_ attachment: String, kind: Int, data: Data)
    /// Mac 上主动断开了这个接入（标签上的「断开」），或会话没了。
    func terminalEnded(_ attachment: String, reason: String)
    /// 设置页、命令行转来的操作（`RemoteHostAgentCommand`）。回 `RemoteHostAgentCommandReply`。
    func command(_ payload: Data, reply: @escaping @Sendable (Data) -> Void)
    /// App 要走了（`RemoteHostAgentDeparture` 的原始值）。回复之后 App 才退出。
    func depart(_ reason: String, reply: @escaping @Sendable () -> Void)
}

/// App 导出、远控进程调用（同一条连接的反方向）。
@objc nonisolated protocol RemoteHostAppXPC {
    /// 远控进程的状态（`RemoteHostAgentState`），设置页、横幅、命令行读它。
    func state(_ payload: Data)
    /// 接管一个会话（`RemoteHostAgentAttach`）。App 回 `terminalAttached`。
    func terminalAttach(_ attachment: String, request: Data)
    /// 链路接走了 `bytes` 字节，可以再送这么多。
    func terminalCredit(_ attachment: String, bytes: Int)
    func terminalInput(_ attachment: String, data: Data)
    func terminalResize(_ attachment: String, cols: Int, rows: Int, controller: String)
    func terminalDetach(_ attachment: String)
    /// 要 App 办的事（`RemoteHostAppRequest`）。回 `RemoteHostAppReply`。
    func request(_ payload: Data, reply: @escaping @Sendable (Data) -> Void)
}

// MARK: - 负载

nonisolated enum RemoteHostTerminalChunkKind: Int, Sendable {
    case output = 0
    case snapshot = 1
    case snapshotFirst = 2
    case snapshotLast = 3
    case snapshotWhole = 4

    init(_ chunk: RemoteTerminalChunk) {
        switch chunk {
        case .output: self = .output
        case .snapshot(_, let first, let last):
            self = first ? (last ? .snapshotWhole : .snapshotFirst) : (last ? .snapshotLast : .snapshot)
        }
    }

    func chunk(_ data: Data) -> RemoteTerminalChunk {
        switch self {
        case .output: .output(data)
        case .snapshot: .snapshot(data, isFirst: false, isLast: false)
        case .snapshotFirst: .snapshot(data, isFirst: true, isLast: false)
        case .snapshotLast: .snapshot(data, isFirst: false, isLast: true)
        case .snapshotWhole: .snapshot(data, isFirst: true, isLast: true)
        }
    }
}

/// App 走的原因。
nonisolated enum RemoteHostAgentDeparture: String, Sendable {
    /// Sparkle 更新：替换完会重新打开，宽限期取长的。
    case update
    /// 用户退出 uTerm：远控随之结束。
    case quit
}

nonisolated struct RemoteHostAgentSettings: Codable, Equatable, Sendable {
    var enabled = false
    var desktopEnabled = false
    var unlockEnabled = false
    var audioEnabled = false
    var localShellEnabled = false
    var internetEnabled = false
    var internetDevices: [UUID] = []
    var keepAwakeForInternet = false
    /// 允许担保。可选：老 App 交来的设置没有这个键，按默认（开）算。
    var deviceVouching: Bool?
}

nonisolated struct RemoteHostAgentSessions: Codable, Equatable, Sendable {
    var entries: [RemoteHostSessionEntry]
    var terminalEngine: String
    /// 重启后本机终端已经接回来了（之前列表不全，远控进程照旧用上一份）。
    var restored: Bool
    /// 手机新开本机终端时可选的目录（不允许打开本机终端时为空）。
    var workspaces: [String]?
}

nonisolated struct RemoteHostAgentHello: Codable, Sendable {
    var protocolVersion = RemoteHostAgent.protocolVersion
    /// App 的构建号（`CFBundleVersion`），远控进程据此判断要不要被替换。
    var appBuild: String
    var localName: String
    var localID: UUID
    /// 远控身份存储里的全部条目（`RemoteIdentityStore` 的账号 → 原始数据）。远控进程只放内存。
    var secrets: [String: Data]
    /// 中继配置（`RemoteRelayConfigStore` 里那份，JSON）。
    var relayConfig: Data?
    /// App 里还没确认的中继证书吊销（`RemoteRelayRevocations` 的原始表），远控进程合并进自己那份。
    var revocations: Data?
    /// 不注册中继的原因（`RemoteRelayRegistrationBlock` 的原始值）。
    var relayRegistrationBlock: String?
    var settings: RemoteHostAgentSettings
    var sessions: RemoteHostAgentSessions
}

nonisolated struct RemoteHostAgentInfo: Codable, Sendable {
    var protocolVersion: Int
    var build: String
    var pid: Int32
    /// 此刻通过认证的连接数（App 判断能不能马上替换远控进程）。
    var authorizedConnections: Int
}

/// 远控进程的状态（App 侧 `RemoteHostServer` 照着它显示）。
nonisolated struct RemoteHostAgentState: Codable, Equatable, Sendable {
    nonisolated enum Status: Codable, Equatable, Sendable {
        case stopped, listening, failed(String)
    }

    nonisolated enum RelayState: Codable, Equatable, Sendable {
        case connecting, registered, failed(String), superseded, stopped
    }

    nonisolated struct PairingRequest: Codable, Equatable, Sendable {
        var id: UUID
        var deviceName: String
        var code: String
    }

    nonisolated struct DesktopViewer: Codable, Equatable, Sendable {
        var connection: UUID
        var channel: UInt32
        var deviceName: String
        var canControl: Bool
        var isControlling: Bool
        var hasAudio: Bool
    }

    nonisolated struct Controller: Codable, Equatable, Sendable {
        var deviceID: UUID
        var name: String
        var platform: String?
        var sharesFiles: Bool
        var sessions: [UUID]
    }

    var status: Status = .stopped
    var port: UInt16?
    var connectedDevices: [String] = []
    var connectedPeerIDs: [UUID] = []
    var pairingRequests: [PairingRequest] = []
    /// 正在出示的邀请（`RemotePairingInvitation.url`）。
    var pairingInvitation: String?
    var desktopViewer: DesktopViewer?
    var relayState: RelayState?
    var relayRunningVersion: String?
    var controllers: [Controller] = []
    /// 会话 → 正在接管它的设备 ID。
    var sessionControllers: [UUID: UUID] = [:]
}

/// App → 远控进程的操作。
nonisolated enum RemoteHostAgentCommand: Codable, Sendable {
    case approvePairing(UUID)
    case rejectPairing(UUID)
    case makePairingInvitation
    case cancelPairingInvitation
    case rename(UUID, String)
    case revoke(UUID)
    /// App 导入或清掉了中继配置（已经存好），远控进程换用这份。
    case relayConfigChanged(Data?)
    case reconnectRelay
    case endDesktop(String)
    case endDesktopAudio(String)
    case desktopSettingsChanged
    /// 命令行反过来读写某台主控端的文件：打包好的请求，回打包好的应答（`RemoteFileCodec`）。
    case performFile(device: UUID, payload: Data, requestID: UUID, timeoutMilliseconds: Int)
    /// 请远控进程停止服务并退出（随后 launchd 会在 App 下一次连接时拉起新版本）。
    case shutdown
    /// 查被控端的系统授权：回 `RemoteHostAgentPermissions`。
    ///
    /// 必须在远控进程里查：屏幕录制由 tccd 归到 uTerm 名下，「辅助功能」（PostEvent）却按远控进程自己的身份
    /// （`com.uozi.uTerm.RemoteHost`，系统设置里叫「uTerm 远程控制」）判，uTerm 的授权替不了它（2026-11-14 实测）。
    case desktopPermissions
    /// 由远控进程申请「辅助功能」：系统设置的列表里登记的是「uTerm 远程控制」。回 `RemoteHostAgentPermissions`。
    case requestPostEvents
    /// 设备组（App 里算的，远控进程不读名册）：把一台组员记成主控端，来路记成这台 Mac 自己
    /// （`RemoteHostServer.groupAddController`）。负载是 `RemoteVouchRequest` 的 JSON，回复的 `data` 是
    /// `RemoteVouchResult` 的 JSON。信任表与担保记录照常经 `persistSecret` 写回 App。
    /// 不认这个操作的旧远控进程回 `ok: false`，App 过一阵再试。
    case groupAddController(Data)
    /// 设备组：组员被移除了，不拉黑地撤掉它（`RemoteHostServer.groupDropController`）。负载是
    /// `RemoteSiblingRevokeRequest` 的 JSON，回复的 `data` 是 `RemoteSiblingRevokeResult` 的 JSON。
    case groupDropController(Data)
}

/// 远控进程此刻的系统授权（本进程内的结果，用户在系统设置里改了之后要重启远控进程才变）。
nonisolated struct RemoteHostAgentPermissions: Codable, Equatable, Sendable {
    var screenCapture: Bool
    var postEvents: Bool
}

nonisolated struct RemoteHostAgentCommandReply: Codable, Sendable {
    var ok = true
    var error: String?
    var data: Data?
}

/// 远控进程 → App 的请求。
nonisolated enum RemoteHostAppRequest: Codable, Sendable {
    case openLocalShell(directory: String?)
    case localWorkspaces
    case closeSession(UUID)
    case deliverImage(attachment: String, image: Data, format: UInt8)
    /// 远控身份存储的一次写入：App 落到钥匙串。
    case persistSecret(account: String, data: Data)
    /// 中继配置的写入（nil = 删除）。
    case persistRelayConfig(Data?)
    /// 凭邀请经公网配上的设备：替它勾上「允许经公网接入」。
    case grantInternetAccess(UUID)
    /// 有设备要用终端了（要会话列表、要接入、或 App 回来时还有暂停着的接入）：请 App 把上次留下的终端接回来，
    /// 接完再报 `restored`。后台唤起的 App 平时不接回（接回要开窗口），等这条请求。
    case restoreSessions
}

nonisolated struct RemoteHostAppReply: Codable, Sendable {
    var error: String?
    var sessionID: UUID?
    var path: String?
    var directories: [String]?
}

nonisolated enum RemoteHostAgentJSON {
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
