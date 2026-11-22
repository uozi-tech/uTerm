import CryptoKit
import Foundation
@preconcurrency import Network
import Observation

/// 接入一个终端后，接收它的输出与关闭事件。回调在连接队列上直接触发，不经主线程。
nonisolated final class RemoteChannelSink: @unchecked Sendable {
    let onOutput: @Sendable (Data) -> Void
    /// 终端画面的整屏快照的一段（`terminalSnapshot`）。终端通道用；桌面通道不用。
    let onSnapshot: (@Sendable (_ piece: Data, _ isFirst: Bool, _ isLast: Bool) -> Void)?
    /// `sessionEnded` = Mac 明确结束了这个终端（关闭 / 断开 / 被别的设备接管）；
    /// false = 只是连接断了，可以重连再接入。
    let onClosed: @Sendable (_ reason: String, _ sessionEnded: Bool) -> Void
    /// 桌面通道的视频帧、光标与剪贴板（`desktopFrame` / `desktopCursor` / `desktopClipboard`）原样交给它，连同它来自的那条连接
    ///（接收端要在同一条连接上回确认，而这时开流的调用可能还没返回）。终端通道不用。
    let onMessage: (@Sendable (RemoteMessage, RemoteLink) -> Void)?

    init(onOutput: @escaping @Sendable (Data) -> Void,
         onSnapshot: (@Sendable (_ piece: Data, _ isFirst: Bool, _ isLast: Bool) -> Void)? = nil,
         onClosed: @escaping @Sendable (_ reason: String, _ sessionEnded: Bool) -> Void,
         onMessage: (@Sendable (RemoteMessage, RemoteLink) -> Void)? = nil) {
        self.onOutput = onOutput
        self.onSnapshot = onSnapshot
        self.onClosed = onClosed
        self.onMessage = onMessage
    }
}

/// 拨公网时交给 `RemoteMacClient.InternetDialer` 的东西。
nonisolated struct RemoteDialContext: Sendable {
    /// 还没用掉的邀请令牌：带着它打招呼，还不认识本机的被控端才肯回应（见 `RemoteInvitationSignal`）。
    var pairingToken: Data?
    /// 这次建连的时间线，拨号的每一步记进去。
    var trace: RemoteConnectTrace
}

/// 一次接入：往哪条连接、哪个通道发输入与尺寸。
nonisolated struct RemoteAttachment: Sendable {
    let link: RemoteLink
    let channel: UInt32
}

nonisolated enum RemoteAttachError: LocalizedError {
    /// Mac 拒绝接入（终端已关闭等），重试也没用。
    case rejected(String)
    /// 连不上 Mac（睡着了、Wi-Fi 断了、uTerm 正在重启），过一会儿可能就好了。
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message), .unreachable(let message): return message
        }
    }
}

/// 通道表：连接队列上查（转发输出），主线程上增删。
///
/// 接入时先按会话 ID 登记接收方；收到 `attached` 的那一刻就在连接队列上把通道号绑上去。
/// 数据流里 `attached` 总在快照之前，在队列上同步绑定才不会丢掉第一帧。
nonisolated final class RemoteChannelTable: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: RemoteChannelSink] = [:]
    private var sinks: [UInt32: RemoteChannelSink] = [:]

    func expect(sessionID: UUID, sink: RemoteChannelSink) {
        lock.lock(); pending[sessionID] = sink; lock.unlock()
    }

    func bind(sessionID: UUID, channel: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if let sink = pending.removeValue(forKey: sessionID) { sinks[channel] = sink }
    }

    func cancel(sessionID: UUID) {
        lock.lock(); pending.removeValue(forKey: sessionID); lock.unlock()
    }

    func sink(_ channel: UInt32) -> RemoteChannelSink? {
        lock.lock(); defer { lock.unlock() }
        return sinks[channel]
    }

    func remove(_ channel: UInt32) -> RemoteChannelSink? {
        lock.lock(); defer { lock.unlock() }
        return sinks.removeValue(forKey: channel)
    }

    func removeAll() -> [RemoteChannelSink] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(sinks.values)
        sinks.removeAll()
        pending.removeAll()
        return all
    }
}

/// 手机这一侧与一台 Mac 的远控连接：握手、配对、会话列表、接入。同一台 Mac 的所有远控标签
/// 共用这一条连接（多路复用），断了由各个 `RemoteTerminalBackend` 发起重连。
@MainActor
@Observable
final class RemoteMacClient: Identifiable {
    enum State: Equatable {
        case idle
        case connecting
        /// 首次配对：等 Mac 上的人点「允许」。附带 6 位核对码，应与 Mac 上显示的一致。
        case awaitingApproval(String)
        case connected
        case failed(String)
    }

    nonisolated var id: String { macName }
    nonisolated let macName: String
    private(set) var state: State = .idle
    private(set) var sessions: [RemoteSessionInfo] = []
    /// 这条连接上最新收到的终端列表；还没收到（刚连上、断开了）时为 nil。那时 `sessions` 也是空的，
    /// 但不代表 Mac 上没有终端。
    private(set) var listedSessionIDs: [UUID]?
    /// Mac 上的人拒绝了配对（或没有确认）。再连只会再弹一次审批，自动重连到此为止。
    private(set) var pairingRefused = false
    /// 握手后才知道的 Mac 设备 ID（「忘记这台 Mac」要用）。
    private(set) var macDeviceID: UUID?
    /// 这条连接走的路，以及最近一次测到的往返时间（毫秒）。
    private(set) var path: RemoteLinkPath?
    private(set) var roundTripMillis: Int?
    /// 这台 Mac 报的可选能力（握手后才有；老版本 Mac 为空）。
    private(set) var macFeatures: [String] = []
    /// 正在连接时走到了哪一步（界面显示进度）。不在连接时为 nil。
    private(set) var connectStage: RemoteConnectStage?
    /// 上次失败时在什么网络、停在哪一步，如「蜂窝网络 · 经中继联系 Mac」。和 `state` 的失败原因分开放，
    /// 原因的文字保持稳定（测试与重试判断都按它）。
    private(set) var failureContext: String?
    /// 失败后正在自动重试（`connectInteractively`）：界面不显示失败页，显示「正在重试」。
    private(set) var isAutoRetrying = false

    /// 一次建连（不含等 Mac 上的人审批配对）最多多久。超过就判失败、说明停在哪一步。测试里调短。
    @ObservationIgnored var connectDeadline: Duration = .seconds(25)
    /// 还有公网可走时，局域网这一步最多等多久。局域网通的时候 0.1 秒内就握完手了；
    /// 等久了的多半是 Bonjour 结果过时（刚关了 Wi-Fi）。
    @ObservationIgnored var localNetworkLimit: Duration = .seconds(3)
    /// 用户打开时（`connectInteractively`）失败后自动再试几次、隔多久。
    nonisolated static let interactiveRetryDelays: [Duration] = [.milliseconds(500), .seconds(2)]

    /// Mac 认不认桌面消息。老版本 Mac 收到桌面消息会当作未知消息断开整条连接，所以发之前必须先看这个。
    var supportsDesktop: Bool { macFeatures.contains(RemoteFeature.desktop) }
    /// 远程桌面里能不能粘贴手机的图片 / 文字（老 Mac 收到 `desktopPaste` 会断开整条连接）。
    var supportsDesktopPaste: Bool { macFeatures.contains(RemoteFeature.desktopPaste) }
    var supportsDesktopPasteChunks: Bool { macFeatures.contains(RemoteFeature.desktopPasteChunks) }
    /// 远程桌面里能不能把文件（视频）贴过去（老 Mac 收到 `desktopPasteFile` 会断开整条连接）。
    var supportsDesktopPasteFiles: Bool { macFeatures.contains(RemoteFeature.desktopPasteFiles) }
    /// 只看一个窗口时那台 Mac 能不能把它保持在最前。
    var supportsDesktopWindowFront: Bool { macFeatures.contains(RemoteFeature.desktopWindowFront) }
    /// 只看一个窗口时那台 Mac 能不能不停流原地换尺寸。
    var supportsDesktopWindowRefit: Bool { macFeatures.contains(RemoteFeature.desktopWindowRefit) }
    /// 那台 Mac 在只看一个窗口时能把输入直接投给窗口所在的进程（不动 Mac 上的指针）。
    var supportsDesktopWindowInput: Bool { macFeatures.contains(RemoteFeature.desktopWindowInput) }
    /// Mac 支持远程解锁 / 帘幕（会发 `desktopScreenState`、认得 `desktopUnlock`）。
    var supportsUnlock: Bool { macFeatures.contains(RemoteFeature.desktopUnlock) }
    /// Mac 会报屏上的系统验证框、认得 `desktopAuthPrompt`（老 Mac 收到会断开整条连接）。
    var supportsAuthPrompt: Bool { macFeatures.contains(RemoteFeature.desktopAuthPrompt) }
    /// Mac 认得 `desktopPause`：手机退到后台时能让它停止推流（老 Mac 收到会断开整条连接）。
    var supportsDesktopPause: Bool { macFeatures.contains(RemoteFeature.desktopPause) }
    /// Mac 能把声音传过来（认得 `desktopAudio`）。
    var supportsDesktopAudio: Bool { macFeatures.contains(RemoteFeature.desktopAudio) }
    var supportsDesktopAudioLossless: Bool { macFeatures.contains(RemoteFeature.desktopAudioLossless) }
    /// Mac 会推终端里程序的状态（`programStatus`）。老 Mac 不推，标签只显示连接状态。
    var supportsProgramStatus: Bool { macFeatures.contains(RemoteFeature.programStatus) }
    /// 各会话的程序状态。要在单枚标签自己的 body 里读（同 `TerminalSession.programStatus`）。
    private(set) var programStatusBook = RemoteProgramStatusBook()

    /// 标签上显示的程序状态：`idle` 与在这台设备上看过的结果不显示。
    func programStatus(for sessionID: UUID) -> ProgramStatusRecord? {
        programStatusBook.display(for: sessionID)
    }

    /// 含 `idle`：那个终端的前台是在报告状态的程序（Agent），不是 shell。
    func programReport(for sessionID: UUID) -> ProgramStatusRecord? {
        programStatusBook.report(for: sessionID)
    }

    /// 用户在这台设备上看过了这个终端的结果。
    func acknowledgeProgramStatus(for sessionID: UUID) {
        programStatusBook.acknowledge(sessionID)
    }

    /// 问「用户此刻正看着这个终端吗」的入口，由显示它的标签登记（nil = 撤掉）。状态到达时问一次：
    /// 正看着，结果一到就算看过（同本机终端在收到报告那一刻按 `isLooking` 处理）。没看着的结果留到
    /// 标签再被看见时由它调 `acknowledgeProgramStatus`。
    func setProgramStatusLooker(_ sessionID: UUID, _ isLooking: (@MainActor () -> Bool)?) {
        programStatusLookers[sessionID] = isLooking
    }

    func receiveProgramStatus(_ update: RemoteProgramStatusUpdate) {
        programStatusBook.apply(update)
        for entry in update.entries where programStatusLookers[entry.sessionID]?() == true {
            programStatusBook.acknowledge(entry.sessionID)
        }
    }

    @ObservationIgnored private var programStatusLookers: [UUID: @MainActor () -> Bool] = [:]

    /// 局域网里能找到它时的地址；nil = 此刻局域网里没有。
    @ObservationIgnored private var endpoint: NWEndpoint?
    /// 跨公网连它的办法（配了中继、知道它的公钥才有）。
    typealias InternetDialer = @Sendable (_ context: RemoteDialContext) async throws -> RemoteDialedPath
    @ObservationIgnored private var internetDialer: InternetDialer?
    /// 先试局域网时顺手把公网那路的准备做了（连上中继的控制连接）：局域网不通再走公网时少等几个往返。
    @ObservationIgnored var prewarmInternet: (@Sendable () -> Void)?
    /// Mac 发来的中继配置交给谁存。
    @ObservationIgnored var onRelayConfig: (@MainActor (RemoteRelayConfig) -> Void)?
    /// 这次连接让本机新记住了这台 Mac（局域网审批通过、或第一次连邀请里的 Mac）：目录据此把它挪进「已配对」。
    @ObservationIgnored var onPaired: (@MainActor () -> Void)?
    @ObservationIgnored private let identity: RemoteIdentityStore
    /// 要连的是哪台 Mac（设备 ID + 长期公钥，来自本机配对记录或邀请）。握手出来对不上就拒绝。nil = 还没配对
    /// （局域网里发现的新 Mac、调试直连），按「认识就核对、不认识就等 Mac 审批」处理。
    @ObservationIgnored private let expectedPeer: RemotePeer?
    /// 扫码拿到的一次性令牌：下一次握手带上凭据，Mac 核对通过就直接信任这台手机。配上后清掉。
    @ObservationIgnored var pairingToken: Data?
    @ObservationIgnored private let table = RemoteChannelTable()
    @ObservationIgnored private var link: RemoteLink?
    /// 当前连接启用了链路排队（`link-flow`）。诊断和测试用。
    var usesLinkFlow: Bool {
        guard let link else { return false }
        return link.queue.sync { link.usesLinkFlow }
    }
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var outcomeWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var attachWaiters: [UUID: CheckedContinuation<UInt32, Error>] = [:]
    @ObservationIgnored private var desktopWaiters: [UUID: CheckedContinuation<(UInt32, RemoteDesktopInfo), Error>] = [:]
    @ObservationIgnored private var localShellWaiters: [UUID: CheckedContinuation<UUID, Error>] = [:]
    @ObservationIgnored private var workspaceWaiters: [UUID: CheckedContinuation<RemoteLocalWorkspaces?, Never>] = [:]
    @ObservationIgnored private var imageWaiters: [UUID: CheckedContinuation<RemoteTerminalImageResult, Error>] = [:]
    @ObservationIgnored private var vouchWaiters: [UUID: CheckedContinuation<RemoteVouchResult, Error>] = [:]
    @ObservationIgnored private var windowListWaiters: [UUID: CheckedContinuation<RemoteDesktopWindowList, Error>] = [:]
    @ObservationIgnored private var revokeWaiters: [UUID: CheckedContinuation<RemoteSiblingRevokeResult, Error>] = [:]
    /// 等文件应答的请求。应答在连接队列上直接交付，不经主线程（传文件时一秒几十条）。
    @ObservationIgnored nonisolated let fileWaiters = RemoteFileWaiters()
    /// 被控的 Mac 反过来读写本机文件时的门禁与执行。nil = 本机不提供文件（手机；握手时也不声明 `file-sharing`）。
    /// 要在连接之前设好。
    @ObservationIgnored var fileSharing: RemoteFileSharingAccess?
    /// 握手里报的本机身份。nil = 真实的设备 ID 与电脑名；测试里一个进程要扮几台设备时才设。
    @ObservationIgnored var localDeviceOverride: (id: UUID, name: String)?
    @ObservationIgnored private var peer: RemoteHello?
    @ObservationIgnored private let heartbeat: RemoteHeartbeat
    /// 各个标签与桌面流的退避等待都挂在这里，网络恢复、回到前台时一起叫醒。
    nonisolated let retryGate = RemoteRetryGate()

    /// - Parameters:
    ///   - macName: 显示用（Bonjour 服务名，即 Mac 的电脑名）。
    ///   - endpoint: Bonjour 发现的服务端点；测试里直接给 127.0.0.1 的端口。
    init(macName: String, endpoint: NWEndpoint, identity: RemoteIdentityStore, expectedPeer: RemotePeer? = nil,
         heartbeat: RemoteHeartbeat = .standard) {
        self.macName = macName
        self.endpoint = endpoint
        // 主控端只往「本机控制的主机」那张表里记。记进被控端那张，这台 Mac 就能反过来免审批控制本机。
        precondition(identity.role == .hosts, "主控端必须用 hosts 方向的信任表")
        self.identity = identity
        self.expectedPeer = expectedPeer
        self.heartbeat = heartbeat
    }

    /// 网络变了。没网：现在的连接肯定不行了，马上断开。有网：现在的连接可能已经走不通（换了 Wi-Fi），
    /// 问一声；正在退避等待重连的，马上再试一次。
    func networkChanged(isSatisfied: Bool) {
        guard isSatisfied else {
            link?.close(RemoteProtocolError.closed)
            return
        }
        link?.probe(replyLimit: heartbeat.probeReplyLimit)
        retryGate.kick()
    }

    /// 同上，带着变化后的网卡：连接走的网卡已经不在了（关了 Wi-Fi 改走蜂窝），不用等探测超时，直接断开重连。
    func networkChanged(_ snapshot: RemoteNetworkSnapshot) {
        currentTrace?.event(String(localized: "网络变化：\(snapshot.label)（\(snapshot.interfaces.joined(separator: ","))）"))
        if snapshot.isSatisfied, let link, let name = link.interfaceName, !snapshot.interfaces.contains(name) {
            AppLogger.notice("远控连接走的网卡 \(name) 没了，断开重连", category: RemoteLog.category)
            link.close(RemoteProtocolError.closed)
            retryGate.kick()
            return
        }
        networkChanged(isSatisfied: snapshot.isSatisfied)
    }

    /// App 回到前台：挂起期间连接可能已经死了，问一声；正在退避等待重连的，马上再试一次。
    func returnedToForeground() {
        link?.probe(replyLimit: heartbeat.probeReplyLimit)
        retryGate.kick()
    }

    func updateEndpoint(_ endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    /// 更新能走的路。已经连着的不受影响，下次连接或重连时按新的走。
    ///
    /// 多出一条路（局域网又找到了它、刚配好中继）是 Mac 可能连得上了的迹象：正在退避的标签马上重试。
    /// 没人看的标签在 Mac 长时间离线后最长一分钟才试一次（`RemoteReconnectPolicy`），靠这里不让 Mac 回来时干等。
    func updateRoutes(endpoint: NWEndpoint?, internetDialer: InternetDialer?) {
        let gainedRoute = (self.endpoint == nil && endpoint != nil) || (self.internetDialer == nil && internetDialer != nil)
        self.endpoint = endpoint
        self.internetDialer = internetDialer
        if gainedRoute { retryGate.kick() }
    }

    /// 中继上一次报的这台 Mac 在不在线（只有界面在显示在线状态时才会去问，见 `RemoteMacDirectory`）。
    @ObservationIgnored private var seenOnRelay = false

    /// 中继报的在线情况。从不在变成在：Mac 醒了或刚打开公网接入，正在退避的标签马上重试。
    /// 只用作叫醒的信号，不拿它拦建连：这份结果可能是十几秒前的，Mac 不在时建连自己会很快失败。
    func relayPresenceChanged(_ isOnRelay: Bool) {
        let cameOnline = isOnRelay && !seenOnRelay
        seenOnRelay = isOnRelay
        if cameOnline { retryGate.kick() }
    }

    /// 连接断了、可以不打扰任何人地自动连回去。
    var canAutoReconnect: Bool {
        switch state {
        case .idle: return true
        case .failed: return !pairingRefused && !failureIsPermanent
        case .connecting, .awaitingApproval, .connected: return false
        }
    }

    // MARK: - 连接与配对

    /// 确保已连上并通过配对。首次配对时会一直等到 Mac 上的人作出决定（或超时）。
    func connect() async {
        if state == .connected { return }
        if connectTask == nil {
            connectTask = Task { await runConnect() }
        }
        await connectTask?.value
    }

    /// 用户主动打开时（Mac 详情、远程桌面）：网络问题导致的失败自动再试两次，期间界面显示「正在重试」，
    /// 不让人对着失败页自己反复点。永久性失败（拒绝配对、身份变了）不重试。
    func connectInteractively() async {
        var delays = Self.interactiveRetryDelays[...]
        while true {
            await connect()
            guard isFailed, canAutoReconnect, let delay = delays.popFirst(), !Task.isCancelled else { break }
            isAutoRetrying = true
            AppLogger.notice("连接 \(self.macName) 失败，\(Self.secondsText(delay)) 后自动重试", category: RemoteLog.category)
            _ = await retryGate.wait(delay)
            guard !Task.isCancelled, isFailed else { break }
        }
        isAutoRetrying = false
    }

    nonisolated private static func secondsText(_ duration: Duration) -> String {
        String(format: "%.1f s", Double(RemoteConnectTrace.millis(duration)) / 1000)
    }

    /// 正在进行的这次建连（网络变化等事件记进去）。
    @ObservationIgnored private var currentTrace: RemoteConnectTrace?
    @ObservationIgnored private var connectAttempts = 0
    /// 这次建连的握手完成了没有（局域网时限只管握手之前）。
    @ObservationIgnored private var handshakeDone = false

    private func runConnect() async {
        defer { connectTask = nil }
        state = .connecting
        failureContext = nil
        connectAttempts = isAutoRetrying ? connectAttempts + 1 : 1
        let trace = RemoteConnectTrace(kind: .connect, macName: macName, attempt: connectAttempts) { [weak self] stage in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stageChanged(stage) } }
        }
        currentTrace = trace
        let network = await RemoteNetworkLabel.current()
        trace.setNetwork(network)
        let deadline = ContinuousClock.now + connectDeadline
        let watchdog = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.connectDeadlinePassed(trace)
        }
        defer {
            watchdog.cancel()
            finishTrace(trace, network: network)
        }
        // 局域网优先。Bonjour 的结果可能已经过时，局域网连不上时再走公网。
        if endpoint != nil, internetDialer != nil { prewarmInternet?() }
        if let endpoint {
            let dialed = RemoteDialedPath(
                transport: RemoteNWTransport(connection: NWConnection(to: endpoint, using: RemoteLink.parameters())),
                handshakeKeys: nil, path: .localNetwork)
            await attempt(dialed, trace: trace,
                          establishLimit: internetDialer != nil ? localNetworkLimit : nil)
            guard isFailed, !failureIsPermanent, internetDialer != nil, !deadlinePassed(trace) else { return }
            state = .connecting
        }
        guard let internetDialer else {
            if endpoint == nil { state = .failed(String(localized: "Mac 不在线")) }
            return
        }
        let context = RemoteDialContext(pairingToken: pairingToken, trace: trace)
        do {
            let remaining = deadline - ContinuousClock.now
            let dialed = try await RemoteDeadline.run(remaining, timeoutError: RemoteProtocolError.timeout,
                                                      discard: { $0.transport.cancel() }) {
                try await internetDialer(context)
            }
            await attempt(dialed, trace: trace, establishLimit: nil)
        } catch {
            if case RemoteProtocolError.timeout = error, ContinuousClock.now >= deadline {
                connectDeadlinePassed(trace)
            }
            if deadlinePassed(trace) { return }
            failureIsPermanent = (error as? RemoteProtocolError)?.isPermanent ?? false
            state = .failed(error.localizedDescription)
        }
    }

    private func stageChanged(_ stage: RemoteConnectStage) {
        guard state == .connecting else { return }
        connectStage = stage
    }

    /// 总时限到了，还没连上也不在等人审批：判失败，说明停在哪一步。
    @ObservationIgnored private var expiredTraceID: String?

    private func deadlinePassed(_ trace: RemoteConnectTrace) -> Bool { expiredTraceID == trace.id }

    private func connectDeadlinePassed(_ trace: RemoteConnectTrace) {
        guard currentTrace === trace, state == .connecting else { return }
        expiredTraceID = trace.id
        let stage = connectStage?.label ?? "?"
        trace.event(String(localized: "总时限 \(Self.secondsText(connectDeadline)) 到了，停在「\(stage)」"))
        failureIsPermanent = false
        state = .failed(String(localized: "连接超时（停在「\(stage)」）"))
        link?.close(RemoteProtocolError.timeout)
        link = nil
        resumeOutcome()
    }

    private func finishTrace(_ trace: RemoteConnectTrace, network: String) {
        defer {
            if currentTrace === trace { currentTrace = nil }
            connectStage = nil
        }
        switch state {
        case .connected:
            trace.finish(ok: true, outcome: path?.label ?? "")
        case .awaitingApproval:
            trace.finish(ok: true, outcome: String(localized: "等 Mac 上确认配对"))
        case .failed(let message):
            failureContext = connectStage.map { String(localized: "\(network)，停在「\($0.label)」") } ?? network
            trace.finish(ok: false, outcome: message)
        case .idle, .connecting:
            trace.finish(ok: false, outcome: String(localized: "已取消"))
        }
    }

    private func attempt(_ dialed: RemoteDialedPath, trace: RemoteConnectTrace, establishLimit: Duration?) async {
        let link = RemoteLink(transport: dialed.transport)
        self.link = link
        path = dialed.path
        roundTripMillis = nil
        handshakeDone = false
        let stepIndex = trace.begin(dialed.path == .localNetwork ? .localNetwork : .handshake,
                                    detail: dialed.path == .localNetwork ? nil : dialed.path.label)
        var stepOpen = true
        func endStep(ok: Bool, detail: String? = nil) {
            guard stepOpen else { return }
            stepOpen = false
            trace.end(stepIndex, ok: ok, detail: detail ?? (ok ? link.interfaceName : nil))
        }
        if let establishLimit {
            Task { [weak self, weak link] in
                try? await Task.sleep(for: establishLimit)
                guard let self, let link, self.link === link, !self.handshakeDone else { return }
                link.close(RemoteProtocolError.timeout)
            }
        }
        let table = self.table
        link.setHandlers(
            onMessage: { [weak self, weak link] message in
                guard let link else { return }
                // 读数：配对结果到了链路（还没回主线程）。和「等待配对结果」这一步的结束对照，看是路上慢还是主线程慢。
                if message.kind == .pairing { trace.event(String(localized: "配对结果到了链路")) }
                Self.route(message, link: link, table: table, client: self)
            },
            onClose: { [weak self] error in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.linkClosed(link, error: error) } }
            }
        )
        do {
            let staticKey = try identity.localIdentity()
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let phoneKey = staticKey.publicKey.rawRepresentation
            var proof: Data?
            if let pairingToken, let expectedPeer {
                proof = RemotePairingInvitation.proof(token: pairingToken, phoneKey: phoneKey, macKey: expectedPeer.publicKey)
            }
            let hello = RemoteHello(version: RemoteConstants.protocolVersion,
                                    deviceID: localDeviceOverride?.id ?? RemoteLocalDevice.id(),
                                    deviceName: localDeviceOverride?.name ?? LANSyncCoordinator.localDeviceName(),
                                    ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                    staticKey: phoneKey,
                                    features: RemoteConstants.localFeatures
                                        + (fileSharing == nil ? [] : [RemoteFeature.fileSharing]),
                                    pairingProof: proof,
                                    deviceModel: RemoteDeviceModel.current(),
                                    platform: RemoteDevicePlatform.current.rawValue,
                                    terminalEngine: TerminalEngineVersion.current)
            let established = try await link.establish(role: .initiator, hello: hello, staticKey: staticKey,
                                                       ephemeralKey: ephemeral, handshakeKeys: dialed.handshakeKeys)
            // 连上的不是要找的那台（同一地址上换了台机器，或有人冒充）：不往下走。
            if let expectedPeer, expectedPeer.id != established.peer.deviceID
                || expectedPeer.publicKey != established.peer.staticKey {
                throw RemoteProtocolError.peerIdentityChanged
            }
            // 配对过的 Mac 换了长期密钥：可能是冒充，也可能是重装过 uTerm。宁可拒绝，让用户手动忘记重配。
            // 给了 `expectedPeer` 时以它为准（上面已经核对过）：扫到的新邀请替换本机记的旧公钥。
            if expectedPeer == nil, let known = identity.peer(id: established.peer.deviceID),
               known.publicKey != established.peer.staticKey {
                throw RemoteProtocolError.peerIdentityChanged
            }
            handshakeDone = true
            endStep(ok: true)
            peer = established.peer
            macDeviceID = established.peer.deviceID
            macFeatures = established.peer.features ?? []
            // 等 Mac 告诉我们配对结果（已信任 / 等审批 / 同意 / 拒绝）。核对码先备着，等审批时显示。
            pendingCode = established.verificationCode
            // 配对结果要等 Mac 认定身份之后才来，所以先证明身份。
            if established.peer.supports(RemoteFeature.keyConfirmation) {
                link.send(RemoteMessage(.keyConfirm))
            }
            let pairingStep = trace.begin(.pairing)
            await withCheckedContinuation { continuation in
                if state == .connected || isFailed {
                    continuation.resume()
                } else {
                    outcomeWaiter = continuation
                }
            }
            trace.end(pairingStep, ok: state == .connected)
            if state == .connected {
                link.send(RemoteMessage(.subscribeSessions))
            }
        } catch {
            endStep(ok: false, detail: error.localizedDescription)
            if deadlinePassed(trace) { return }
            failureIsPermanent = (error as? RemoteProtocolError)?.isPermanent ?? false
            state = .failed(error.localizedDescription)
            link.close(error)
            if self.link === link { self.link = nil }
        }
    }

    @ObservationIgnored private var pendingCode = ""
    /// 网络诊断在等的那一个 pong（毫秒；超时为 nil）与它的编号，超时和 pong 谁先到谁收。
    @ObservationIgnored private var pongWaiter: (token: Int, continuation: CheckedContinuation<Double?, Never>)?
    @ObservationIgnored private var pongToken = 0

    /// 网络诊断：连着的时候逐个发 ping、等 pong，返回每次往返（毫秒）与丢了几次。
    /// 每次最多等 `timeout`；心跳只在链路安静时才发，这里一直在发，不会和它抢。
    func measureRoundTrips(count: Int, interval: Duration = .milliseconds(50),
                           timeout: Duration = .seconds(1)) async -> (millis: [Double], lost: Int) {
        var millis: [Double] = []
        var lost = 0
        for _ in 0..<count {
            guard let link, state == .connected, !Task.isCancelled else {
                lost += 1
                continue
            }
            pongToken += 1
            let token = pongToken
            let trip = await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
                pongWaiter = (token, continuation)
                link.send(RemoteMessage(.ping))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finishPong(token: token, millis: nil)
                }
            }
            if let trip { millis.append(trip) } else { lost += 1 }
            try? await Task.sleep(for: interval)
        }
        return (millis, lost)
    }

    private func finishPong(token: Int?, millis: Double?) {
        guard let waiter = pongWaiter, token == nil || waiter.token == token else { return }
        pongWaiter = nil
        waiter.continuation.resume(returning: millis)
    }
    /// `state == .failed` 时这次失败是否重试也没用。false = 网络问题，调用方可以退避重试。
    @ObservationIgnored private var failureIsPermanent = false

    /// 连接没成功时该抛给调用方的错误。
    private var connectionFailure: Error {
        guard case .failed(let message) = state else { return RemoteProtocolError.closed }
        return failureIsPermanent ? RemoteAttachError.rejected(message) : RemoteAttachError.unreachable(message)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func handlePairing(_ pairing: RemotePairingState) {
        // 这边已经判了失败（比如连上的不是要找的那台 Mac）：Mac 在那之前发出的配对结果还在路上，不能把状态改回去。
        guard !isFailed else { return }
        switch pairing {
        case .trusted, .approved:
            if let peer {
                // 第一次见到这台 Mac（或手机这边忘过）：记住它的长期公钥，之后每次握手都核对。
                // 早就记着的：只跟着更新名字与机型，本机起的别名与配对时间不动。
                let known = identity.peer(id: peer.deviceID).flatMap { $0.publicKey == peer.staticKey ? $0 : nil }
                var updated = known ?? RemotePeer(id: peer.deviceID, name: peer.deviceName, publicKey: peer.staticKey,
                                                  pairedAt: Date())
                updated.name = peer.deviceName
                if let model = peer.deviceModel { updated.model = model }
                if let platform = peer.platform { updated.platform = platform }
                if updated != known { try? identity.trust(updated) }
                if known == nil { onPaired?() }
            }
            pairingToken = nil
            pairingRefused = false
            state = .connected
            link?.startHeartbeat(heartbeat)
            resumeOutcome()
            // 一个标签把连接接回来了：同一台 Mac 的其它标签与桌面流还睡在各自的退避里（没人看的最长一分钟），
            // 叫醒它们在这条现成的连接上接入，不必各自再等、再建连。
            retryGate.kick()
        case .awaitingApproval:
            state = .awaitingApproval(pendingCode)
        case .rejected:
            pairingRefused = true
            failureIsPermanent = true
            state = .failed(RemoteProtocolError.pairingRejected.localizedDescription)
            resumeOutcome()
        }
    }

    private func resumeOutcome() {
        outcomeWaiter?.resume()
        outcomeWaiter = nil
    }

    func disconnect() {
        link?.close()
    }

    /// 忘记这台 Mac：下次连接重新配对。
    func forget() {
        if let macDeviceID { try? identity.revoke(id: macDeviceID) }
        disconnect()
    }

    private func linkClosed(_ closedLink: RemoteLink, error: Error?) {
        guard closedLink === link else { return }
        link = nil
        path = nil
        roundTripMillis = nil
        sessions = []
        listedSessionIDs = nil
        programStatusBook.removeAllReports()
        if state == .connected || state == .connecting {
            failureIsPermanent = false
            state = error.map { .failed($0.localizedDescription) } ?? .idle
        } else if case .awaitingApproval = state {
            pairingRefused = true
            failureIsPermanent = true
            state = .failed(error?.localizedDescription ?? String(localized: "Mac 没有确认配对"))
        }
        resumeOutcome()
        for (_, waiter) in attachWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        attachWaiters.removeAll()
        for (_, waiter) in desktopWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        desktopWaiters.removeAll()
        for (_, waiter) in localShellWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        localShellWaiters.removeAll()
        for (_, waiter) in workspaceWaiters { waiter.resume(returning: nil) }
        workspaceWaiters.removeAll()
        for (_, waiter) in imageWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        imageWaiters.removeAll()
        for (_, waiter) in vouchWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        vouchWaiters.removeAll()
        for (_, waiter) in windowListWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        windowListWaiters.removeAll()
        for (_, waiter) in revokeWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        revokeWaiters.removeAll()
        let closedReason = String(localized: "与 Mac 的连接已断开")
        fileWaiters.failAll(RemoteFileError(.unreachable, closedReason))
        for sink in table.removeAll() { sink.onClosed(closedReason, false) }
    }

    // MARK: - 收消息

    /// 在连接队列上分发：终端字节直接交给通道的接收方；控制消息跳回主线程。
    private nonisolated static func route(_ message: RemoteMessage, link: RemoteLink, table: RemoteChannelTable,
                                          client: RemoteMacClient?) {
        switch message.kind {
        case .output:
            table.sink(message.channel)?.onOutput(message.payload)
        case .terminalSnapshot:
            if let piece = RemoteTerminalSnapshotPiece.decode(message.payload) {
                table.sink(message.channel)?.onSnapshot?(piece.data, piece.isFirst, piece.isLast)
            }
        case .desktopFrame, .desktopCursor, .desktopClipboard, .desktopLatency, .desktopScreenState, .desktopUnlockResult,
             .desktopCursorImage, .desktopAudioFormat, .desktopAudioFrame, .desktopGeometry, .desktopAuthPromptResult:
            table.sink(message.channel)?.onMessage?(message, link)
        case .desktopStarted:
            // 同 `attached`：在队列上先绑定通道，紧随其后的第一帧（关键帧）才不会丢。
            if let info = try? RemoteJSON.decode(RemoteDesktopInfo.self, from: message.payload), info.failure == nil {
                table.bind(sessionID: info.requestID, channel: message.channel)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { client?.handleControl(message) } }
        case .closed:
            table.remove(message.channel)?.onClosed(String(decoding: message.payload, as: UTF8.self), true)
        case .attached:
            if let result = try? RemoteJSON.decode(RemoteAttachResult.self, from: message.payload), result.error == nil {
                table.bind(sessionID: result.sessionID, channel: message.channel)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { client?.handleControl(message) } }
        case .fileReply:
            client?.fileWaiters.deliver(message.payload)
        case .fileRequest:
            DispatchQueue.main.async { MainActor.assumeIsolated { client?.handleSharedFileRequest(message.payload, link: link) } }
        case .pong:
            let precise = link.latestRoundTrip.map { $0 * 1000 }
            let millis = precise.map { Int($0.rounded()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    client?.roundTripMillis = millis
                    client?.finishPong(token: nil, millis: precise)
                }
            }
        default:
            DispatchQueue.main.async { MainActor.assumeIsolated { client?.handleControl(message) } }
        }
    }

    /// 标签名变化时列表每秒都可能来一次。id 没变就不写 `listedSessionIDs`，不让跟随逻辑白跑。
    func receiveSessions(_ list: [RemoteSessionInfo]) {
        if sessions != list { sessions = list }
        let ids = list.map(\.id)
        if listedSessionIDs != ids {
            listedSessionIDs = ids
            programStatusBook.retain(Set(ids))
        }
    }

    private func handleControl(_ message: RemoteMessage) {
        switch message.kind {
        case .pairing:
            if let raw = message.payload.first, let pairing = RemotePairingState(rawValue: raw) {
                handlePairing(pairing)
            }
        case .relayConfig:
            if let config = RemoteRelayConfig(importing: message.payload) { onRelayConfig?(config) }
        case .sessions:
            if let list = try? RemoteJSON.decode([RemoteSessionInfo].self, from: message.payload) {
                receiveSessions(list)
            }
        case .attached:
            guard let result = try? RemoteJSON.decode(RemoteAttachResult.self, from: message.payload),
                  let waiter = attachWaiters.removeValue(forKey: result.sessionID) else { return }
            if let error = result.error {
                table.cancel(sessionID: result.sessionID)
                waiter.resume(throwing: RemoteAttachError.rejected(error))
            } else {
                waiter.resume(returning: message.channel)
            }
        case .desktopStarted:
            guard let info = try? RemoteJSON.decode(RemoteDesktopInfo.self, from: message.payload),
                  let waiter = desktopWaiters.removeValue(forKey: info.requestID) else { return }
            if info.failure != nil { table.cancel(sessionID: info.requestID) }
            waiter.resume(returning: (message.channel, info))
        case .localShellOpened:
            guard let result = try? RemoteJSON.decode(RemoteOpenLocalShellResult.self, from: message.payload),
                  let waiter = localShellWaiters.removeValue(forKey: result.requestID) else { return }
            if let sessionID = result.sessionID {
                waiter.resume(returning: sessionID)
            } else {
                waiter.resume(throwing: RemoteAttachError.rejected(result.error ?? String(localized: "Mac 无法打开本机终端")))
            }
        case .localWorkspaces:
            guard let workspaces = try? RemoteJSON.decode(RemoteLocalWorkspaces.self, from: message.payload),
                  let waiter = workspaceWaiters.removeValue(forKey: workspaces.requestID) else { return }
            waiter.resume(returning: workspaces)
        case .programStatus:
            if let update = try? RemoteJSON.decode(RemoteProgramStatusUpdate.self, from: message.payload) {
                receiveProgramStatus(update)
            }
        case .terminalImageResult:
            guard let result = try? RemoteJSON.decode(RemoteTerminalImageResult.self, from: message.payload),
                  let waiter = imageWaiters.removeValue(forKey: result.requestID) else { return }
            waiter.resume(returning: result)
        case .vouchResult:
            guard let result = try? RemoteJSON.decode(RemoteVouchResult.self, from: message.payload),
                  let waiter = vouchWaiters.removeValue(forKey: result.requestID) else { return }
            waiter.resume(returning: result)
        case .desktopWindowList:
            guard let list = try? RemoteJSON.decode(RemoteDesktopWindowList.self, from: message.payload),
                  let waiter = windowListWaiters.removeValue(forKey: list.requestID) else { return }
            waiter.resume(returning: list)
        case .revokeSiblingResult:
            guard let result = try? RemoteJSON.decode(RemoteSiblingRevokeResult.self, from: message.payload),
                  let waiter = revokeWaiters.removeValue(forKey: result.requestID) else { return }
            waiter.resume(returning: result)
        default:
            break
        }
    }

    // MARK: - 接入

    /// 接入 Mac 上的一个终端。返回后输出开始经 `sink` 流入（第一帧是快照）。
    func attach(sessionID: UUID, size: RemoteGridSize, sink: RemoteChannelSink) async throws -> RemoteAttachment {
        await connect()
        guard state == .connected, let link else {
            throw connectionFailure
        }
        // 那台 Mac 的终端引擎和本机不是同一个版本：它发来的快照解不开，不接入（Mac 那边也会拒绝）。
        guard RemoteTerminalEngine.matches(peer?.terminalEngine) else {
            throw RemoteAttachError.rejected(RemoteTerminalEngine.mismatchMessage)
        }
        table.expect(sessionID: sessionID, sink: sink)
        let channel = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt32, Error>) in
            attachWaiters.removeValue(forKey: sessionID)?.resume(throwing: RemoteProtocolError.closed)
            attachWaiters[sessionID] = continuation
            link.send(RemoteMessage(.attach, payload: RemoteJSON.encode(
                RemoteAttachRequest(sessionID: sessionID, cols: size.cols, rows: size.rows))))
        }
        return RemoteAttachment(link: link, channel: channel)
    }

    func detach(_ attachment: RemoteAttachment) {
        attachment.link.send(RemoteMessage(.detach, channel: attachment.channel))
        _ = table.remove(attachment.channel)
    }

    /// 这台 Mac 能不能开本机终端（老 Mac 收到 `openLocalShell` 会断开整条连接）。
    var supportsLocalShell: Bool { macFeatures.contains(RemoteFeature.localShell) }

    /// 这台 Mac 认不认担保（老 Mac 收到 `vouchDevice` 会断开整条连接）。连上之后才知道。
    var supportsDeviceVouch: Bool { macFeatures.contains(RemoteFeature.deviceVouch) }

    /// 这台 Mac 认不认撤销同组设备。
    var supportsSiblingRevoke: Bool { macFeatures.contains(RemoteFeature.siblingRevoke) }

    /// 请 Mac 撤销同一组里丢了的那台设备。Mac 版本太旧抛 `RemoteAttachError.rejected`；Mac 不肯撤看结果。
    func revokeSibling(_ deviceID: UUID, publicKey: Data) async throws -> RemoteSiblingRevokeResult {
        await connect()
        guard state == .connected, let link else {
            throw connectionFailure
        }
        guard supportsSiblingRevoke else {
            throw RemoteAttachError.rejected(String(localized: "这台 Mac 上的 uTerm 版本太旧，不能替你撤销。把 Mac 上的 uTerm 更新到最新版，或到那台 Mac 上撤销"))
        }
        let request = RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: deviceID, publicKey: publicKey)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteSiblingRevokeResult, Error>) in
            revokeWaiters[request.requestID] = continuation
            link.send(RemoteMessage(.revokeSibling, payload: RemoteJSON.encode(request)))
        }
    }

    /// 请 Mac 记下同一个人的另一台设备（和本机同在一个设备组里）。Mac 版本太旧抛 `RemoteAttachError.rejected`；
    /// 连不上照常抛连接失败。Mac 不肯记不算错误，看结果里的 `outcome`。
    func vouch(for device: RemoteGroupDevice) async throws -> RemoteVouchResult {
        await connect()
        guard state == .connected, let link else {
            throw connectionFailure
        }
        guard supportsDeviceVouch else {
            throw RemoteAttachError.rejected(String(localized: "这台 Mac 上的 uTerm 版本太旧，不能替别的设备开通。把 Mac 上的 uTerm 更新到最新版，或在那台设备上单独配对"))
        }
        let request = RemoteVouchRequest(requestID: UUID(), deviceID: device.id, name: device.name, model: device.model,
                                         platform: device.platform, publicKey: device.publicKey)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteVouchResult, Error>) in
            vouchWaiters[request.requestID] = continuation
            link.send(RemoteMessage(.vouchDevice, payload: RemoteJSON.encode(request)))
        }
    }

    /// 远程桌面放大后能不能按看得见的那块重新取画面（老 Mac 收到 `desktopRegion` 会断开整条连接）。
    var supportsDesktopRegion: Bool { macFeatures.contains(RemoteFeature.desktopRegion) }

    /// 远程桌面能不能只看一个窗口（老 Mac 不认开流请求里的 `windowID`，收到 `desktopWindows` 会断开整条连接）。
    var supportsDesktopWindows: Bool { macFeatures.contains(RemoteFeature.desktopWindows) }

    /// 那台 Mac 上此刻能单独看的窗口，最前面的在前。Mac 版本太旧抛 `RemoteAttachError.rejected`；列不出来
    ///（没开远程桌面、没授权）不算错误，看结果里的 `message`。
    func desktopWindows() async throws -> RemoteDesktopWindowList {
        await connect()
        guard state == .connected, let link else {
            throw connectionFailure
        }
        guard supportsDesktopWindows else {
            throw RemoteAttachError.rejected(String(localized: "这台 Mac 上的 uTerm 版本太旧，不支持窗口模式。把 Mac 上的 uTerm 更新到最新版"))
        }
        let request = RemoteDesktopWindowListRequest(requestID: UUID())
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteDesktopWindowList, Error>) in
            windowListWaiters[request.requestID] = continuation
            link.send(RemoteMessage(.desktopWindows, payload: RemoteJSON.encode(request)))
        }
    }

    /// 关远控标签时能不能连 Mac 上的终端一起关（老 Mac 收到 `closeSession` 会断开整条连接）。
    var supportsCloseSession: Bool { macFeatures.contains(RemoteFeature.closeSession) }

    /// 请 Mac 关掉它上面的一条会话（所在标签连同连接 / shell）。只发不等：手机这边随后照常关自己的标签，
    /// Mac 关掉以后会话列表会推来新的一份。没连着或 Mac 不支持时什么也不做。
    func closeSessionOnMac(_ sessionID: UUID) {
        guard state == .connected, let link, supportsCloseSession else { return }
        link.send(RemoteMessage(.closeSession, payload: RemoteJSON.encode(RemoteCloseSessionRequest(sessionID: sessionID))))
    }

    /// 远控终端里能不能贴图片（老 Mac 收到 `terminalImage` 会断开整条连接）。
    var supportsTerminalImage: Bool { macFeatures.contains(RemoteFeature.terminalImage) }

    /// 贴图等 Mac 回复的上限：SSH 会话要先把图片传到服务器上。
    private static let terminalImageTimeout = Duration.seconds(60)

    /// 把一张图片交给接入的终端，等 Mac 处理完：本机 shell 放进 Mac 剪贴板并按了 Ctrl+V（`.clipboard`），
    /// SSH 会话传成了服务器上的文件（`.file`，路径由调用方粘进终端）。
    func sendTerminalImage(_ image: TerminalImage, over attachment: RemoteAttachment) async throws -> TerminalImageDelivery {
        guard supportsTerminalImage else {
            throw TerminalImageError.unsupported(String(localized: "这台 Mac 上的 uTerm 版本太旧，不支持往终端里贴图片。把 Mac 上的 uTerm 更新到最新版后再试"))
        }
        guard image.data.count <= RemoteTerminalImageRequest.maxImageBytes else {
            throw TerminalImageError.unsupported(String(localized: "图片太大"))
        }
        // 重连的空档里调用方手上可能还是旧连接的接入：发出去不会有回音，断开时也不会被收尾（只认当前连接）。
        guard attachment.link === link else { throw RemoteProtocolError.closed }
        let request = RemoteTerminalImageRequest(requestID: UUID(), image: image)
        let requestID = request.requestID
        // 整张图是一条消息，量不出发了多少：发出去之前停在「发送」的起点，链路接走之后进「等对方处理」。
        // 进度的接收方要在这个任务里取，下面的回调在链路队列上。
        let progress = PasteProgressReporter.sink
        progress?(PasteProgress(.sending))
        let result = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RemoteTerminalImageResult, Error>) in
            imageWaiters[requestID] = continuation
            let link = attachment.link, channel = attachment.channel
            link.queue.async {
                // 几 MB 的拼装不放主线程。
                link.sendOnQueue(RemoteMessage(.terminalImage, channel: channel, payload: request.encoded())) { error in
                    if error == nil { progress?(PasteProgress(.finishing)) }
                }
            }
            // Mac 一直不回（处理途中出错、旧版本丢了请求）也不能让贴图一直转圈。
            Task { [weak self] in
                try? await Task.sleep(for: Self.terminalImageTimeout)
                self?.imageWaiters.removeValue(forKey: requestID)?.resume(throwing: RemoteProtocolError.timeout)
            }
        }
        if let error = result.error { throw TerminalImageError.unsupported(error) }
        return result.path.map { .file(path: $0) } ?? .clipboard
    }

    /// 请 Mac 开一个本机 shell（Mac 上同时弹出它的终端窗口），返回会话 id；之后照常 `attach`。
    /// Mac 上没开「允许打开本机终端」、辅助程序没授权等情况抛 `RemoteAttachError.rejected`，带给人看的原因；
    /// 连不上 Mac 抛 `.unreachable`。
    func openLocalShell(directory: String? = nil) async throws -> UUID {
        await connect()
        guard state == .connected, let link else {
            throw connectionFailure
        }
        guard supportsLocalShell else {
            throw RemoteAttachError.rejected(String(localized: "这台 Mac 上的 uTerm 版本太旧，不能新建本机终端。把 Mac 上的 uTerm 更新到最新版后再试"))
        }
        let requestID = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, Error>) in
            localShellWaiters[requestID] = continuation
            link.send(RemoteMessage(.openLocalShell, payload: RemoteJSON.encode(RemoteOpenLocalShellRequest(requestID: requestID, directory: directory))))
        }
    }

    /// 问 Mac 最近的工作区，给「开在哪」用。连不上、老 Mac、Mac 没开本机终端都回 nil 或空列表：这时不用问，
    /// 直接走 `openLocalShell()`，开不了的原因由它报。
    func localWorkspaces() async -> RemoteLocalWorkspaces? {
        await connect()
        guard state == .connected, let link, macFeatures.contains(RemoteFeature.localWorkspaces) else { return nil }
        let requestID = UUID()
        return await withCheckedContinuation { continuation in
            workspaceWaiters[requestID] = continuation
            link.send(RemoteMessage(.listLocalWorkspaces, payload: RemoteJSON.encode(RemoteLocalWorkspacesRequest(requestID: requestID))))
        }
    }
}

// MARK: - 文件

extension RemoteMacClient {
    /// 这台 Mac 认得文件请求（老 Mac 收到 `fileRequest` 会断开整条连接）。
    var supportsFiles: Bool { macFeatures.contains(RemoteFeature.files) }

    /// 发一条文件请求，等应答。打包、压缩、解包都不在主线程上做。被控端回了错误就抛 `RemoteFileError`。
    nonisolated func performFile(_ request: RemoteFileRequest, body: Data = Data(),
                                 timeout: Duration? = nil) async throws -> (reply: RemoteFileReply, body: Data) {
        var request = request
        request.acceptsCompression = true
        let payload = RemoteFileCodec.packRequest(request, body: body, compress: true)
        let raw = try await sendFile(payload, id: request.id, timeout: timeout ?? RemoteFileTimeouts.limit(for: request))
        let (reply, data) = try RemoteFileCodec.unpackReply(raw)
        if let error = reply.error { throw error }
        return (reply, data)
    }

    private func sendFile(_ payload: Data, id: UUID, timeout: Duration) async throws -> Data {
        await connect()
        guard state == .connected, let link else {
            let reason: String
            if case .failed(let message) = state { reason = message } else { reason = String(localized: "没有连上 Mac") }
            throw RemoteFileError(.unreachable, reason)
        }
        guard supportsFiles else {
            throw RemoteFileError(.unsupported, String(localized: "这台 Mac 上的 uTerm 版本太旧，不支持远程访问文件。把 Mac 上的 uTerm 更新到最新版后再试"))
        }
        return try await fileWaiters.exchange(payload, id: id, timeout: timeout, peer: "Mac") { payload in
            link.send(RemoteMessage(.fileRequest, channel: RemoteConstants.fileChannel, payload: payload))
        }
    }

    /// 被控的 Mac 反过来要读写本机的文件：只在用户给它共享了文件夹时放行，而且只放行那些文件夹里的。
    /// 主程序不解释内容，只为了过门禁和记日志看一眼头。
    fileprivate func handleSharedFileRequest(_ payload: Data, link: RemoteLink) {
        let send: @Sendable (Data) -> Void = { reply in
            link.queue.async {
                link.sendOnQueue(RemoteMessage(.fileReply, channel: RemoteConstants.fileChannel, payload: reply),
                                 countsTowardBackpressure: false)
            }
        }
        func refuse(_ error: RemoteFileError) {
            send(RemoteFileCodec.packReply(.failure(RemoteFileCodec.requestID(of: payload) ?? UUID(), error), compress: false))
        }
        guard let access = fileSharing else {
            refuse(RemoteFileError(.unsupported, String(localized: "那台设备不提供文件")))
            return
        }
        guard let (request, _) = try? RemoteFileCodec.decode(RemoteFileRequest.self, from: payload) else {
            refuse(RemoteFileError(.invalid, String(localized: "请求解不开")))
            return
        }
        let scope = access.scope() ?? RemoteFileScope(roots: [])
        // 什么都没共享时，只有「问共享了什么」照常回（回一个空列表）。
        if scope.roots.isEmpty, request.op != .roots {
            refuse(RemoteFileError(.disabled, String(localized: "那台 Mac 没有给这台 Mac 共享任何文件夹。要读写它上面的文件，得由用户在那台 Mac 的 uTerm「动作 › 我的 Mac」里选中这台 Mac，添加共享文件夹")))
            return
        }
        if request.op.isMutation, request.op != .write {
            AppLogger.info("远控：\(self.macName) 改共享文件夹里的东西 \(request.op.rawValue) \(request.path ?? "")",
                           category: RemoteLog.category)
        }
        Task.detached {
            send(await access.perform(payload, scope))
        }
    }
}

// MARK: - 桌面

extension RemoteMacClient {
    /// 开一条桌面流。返回 Mac 的回复：`info.failure != nil` 表示被拒（没开开关、没授权……），
    /// 此时没有通道可用。成功后视频帧与光标经 `sink.onMessage` 在连接队列上流入（第一帧是关键帧）。
    ///
    /// 调用前应已确认 `supportsDesktop`；这里再挡一次，老 Mac 收到桌面消息会断开整条连接。
    /// `prepareVideo`：这条连接能从数据报通道收视频时调用，要在开流之前挂好接收端（第一帧可能比回复先到）。
    func startDesktop(_ request: RemoteDesktopStartRequest, sink: RemoteChannelSink,
                      prepareVideo: ((any RemoteVideoDatagramChannel, RemoteLink) -> Void)? = nil) async throws
        -> (attachment: RemoteAttachment, info: RemoteDesktopInfo) {
        await connect()
        guard state == .connected, let link else {
            throw connectionFailure
        }
        guard supportsDesktop else { throw RemoteDesktopError.macTooOld }
        var request = request
        if let video = link.videoChannel, let prepareVideo {
            prepareVideo(video, link)
            request.videoDatagrams = true
        }
        let startRequest = request
        table.expect(sessionID: request.requestID, sink: sink)
        let (channel, info) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(UInt32, RemoteDesktopInfo), Error>) in
            desktopWaiters.removeValue(forKey: request.requestID)?.resume(throwing: RemoteProtocolError.closed)
            desktopWaiters[request.requestID] = continuation
            link.send(RemoteMessage(.desktopStart, payload: RemoteJSON.encode(startRequest)))
        }
        return (RemoteAttachment(link: link, channel: channel), info)
    }

    func stopDesktop(_ attachment: RemoteAttachment) {
        attachment.link.send(RemoteMessage(.desktopStop, channel: attachment.channel))
        _ = table.remove(attachment.channel)
    }
}

nonisolated enum RemoteDesktopError: LocalizedError, Equatable {
    /// Mac 上的 uTerm 是 P1 的版本，不认桌面消息。
    case macTooOld

    var errorDescription: String? {
        switch self {
        case .macTooOld: return String(localized: "这台 Mac 上的 uTerm 版本太旧，不支持远程桌面。把 Mac 上的 uTerm 更新到最新版后再试")
        }
    }
}
