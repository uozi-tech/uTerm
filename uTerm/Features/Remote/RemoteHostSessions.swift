import Foundation

/// 被控端（`RemoteHostServer`）眼里的终端会话：只有远控用得到的那几样，不直接碰 `TerminalSession`。
///
/// 两个实现：`RemoteRegistrySessions`（App 进程内，直接读 `TerminalSessionRegistry`）与 `RemoteForwardedSessions`
///（远控进程里，会话在 App 里，经 XPC 转过来）。远控进程不链接终端引擎，所以这里只用 Foundation 与远控线协议里的类型。
@MainActor
protocol RemoteHostSessions: AnyObject {
    /// 会话列表，按 Mac 上的标签顺序。
    func orderedSessions() -> [RemoteHostSessionEntry]
    /// 终端引擎版本（`TerminalEngineVersion.current`）：快照是引擎的二进制格式，握手时报给对端、接入前核对。
    /// 远控进程里是 App 最近一次报来的版本（App 升级后可能和远控进程编译时的不同）。
    var terminalEngine: String { get }
    /// 开始把变化报给 `observer`（覆盖之前的）。
    func observe(_ observer: RemoteHostSessionObserver)
    func stopObserving()
    /// 接管一个会话：钉尺寸并订阅输出。结果出来前连接照常收发（远控进程里要等 App 回话）。
    func attach(_ request: RemoteHostAttachRequest) async -> Result<any RemoteHostTerminalAttachment, RemoteHostAttachError>
    /// 关掉 Mac 上的一个会话（对端在设备上关了标签）。
    func requestClose(sessionID: UUID) async -> Bool
    /// 对端在设备上排过这台 Mac 的标签：每个标签组照 `order` 排（`TerminalSessionRegistry.arrangeTabs`）。
    func requestArrange(order: [UUID]) async
    /// Mac 刚重启、本机终端还没接回来时要等：手机不能看到一份缺了它们的列表，也不能把接入回成「已关闭」。
    func waitUntilRestored() async
}

/// 会话变化的回调。都在主线程上调。
@MainActor
struct RemoteHostSessionObserver {
    /// 会话增减（`alive` = 此刻还在的会话）。
    var sessionsChanged: (_ alive: Set<UUID>) -> Void
    /// 标签名变了（可能很频繁，服务端自己节流）。
    var titlesChanged: () -> Void
    /// 程序状态变了。
    var programStatusChanged: () -> Void
    /// 标签先后变了。
    var orderChanged: () -> Void
}

/// 一条会话的远控视图。
nonisolated struct RemoteHostSessionEntry: Codable, Equatable, Sendable {
    var id: UUID
    var serverID: UUID
    var serverName: String
    var title: String
    var windowKind: String
    var connectedAt: Date?
    /// Mac 标签上此刻显示的名字。
    var tabTitle: String
    var program: ProgramStatusRecord?
}

nonisolated struct RemoteHostAttachRequest: Sendable {
    var sessionID: UUID
    var cols: Int
    var rows: Int
    /// 接管它的设备名（终端上显示「由 ×× 控制」）。
    var controller: String
    /// 首张快照等终端按对端尺寸钉好的时限。
    var settleTimeout: TimeInterval
    /// 镜像快照发哪种（`RemoteTerminalEngine.snapshotFormat`）。
    var snapshotFormat: RemoteTerminalSnapshotFormat = .binary
    /// 有数据可取（在任意线程上调）。
    var onReadable: @Sendable () -> Void
}

nonisolated enum RemoteHostAttachError: Error, Equatable, Sendable {
    /// 会话不在或已断开。
    case unavailable
    /// App 不在（远控进程里，宽限期内没回来）。
    case appUnavailable

    var message: String {
        switch self {
        case .unavailable: String(localized: "这个终端已经关闭或断开")
        case .appUnavailable: String(localized: "Mac 上的 uTerm 正在重启，请稍后再试")
        }
    }
}

/// 一个接入：输出从 `feed` 取（链路队列上），输入、尺寸、贴图交回会话。
@MainActor
protocol RemoteHostTerminalAttachment: AnyObject {
    nonisolated var feed: any RemoteTerminalFeed { get }
    func write(_ data: Data)
    func resize(cols: Int, rows: Int, controller: String)
    /// 结束接入。这条接入还钉着会话尺寸（后面没有别的设备接管）时，把尺寸还给 Mac。
    func detach()
    /// Mac 上主动断开了这个会话的远控（标签上的「断开」）。
    var onRemoteDisconnect: (@MainActor () -> Void)? { get set }
    /// 对端送来的图片交给会话的后端。成功回终端里可用的路径（本机 shell 走剪贴板时为 nil）。
    func deliverImage(_ image: TerminalImage) async -> Result<String?, RemoteHostImageError>
}

nonisolated struct RemoteHostImageError: Error, Equatable, Sendable {
    var message: String
}

/// 一个接入的输出：快照分片与之后的原样字节。`take` 在链路队列上调，要线程安全。
nonisolated protocol RemoteTerminalFeed: AnyObject, Sendable {
    func take(maxBytes: Int) -> RemoteTerminalChunk?
}

/// 发给对端的一段终端数据。
nonisolated enum RemoteTerminalChunk: Equatable, Sendable {
    /// 快照的一段。`isFirst`：一张新快照的开头（接收端丢掉手上没收完的那张）；`isLast`：收齐了，可以还原。
    case snapshot(Data, isFirst: Bool, isLast: Bool)
    /// 快照之后的原样字节。
    case output(Data)

    var byteCount: Int {
        switch self {
        case .snapshot(let data, _, _), .output(let data): data.count
        }
    }
}
