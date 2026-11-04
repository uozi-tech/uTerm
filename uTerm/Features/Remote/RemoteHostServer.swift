import Foundation
@preconcurrency import Network
import Observation

/// Mac 端远控服务：让配对过的手机接入这台 Mac 上已打开的终端。
///
/// `RemoteControlSettings` 打开时监听（Bonjour `_uterm-remote._tcp`），关闭时连广播一起撤掉。
/// 每台连上来的设备一个 `RemoteHostConnection`。同一个终端同一时刻只给一台设备接管尺寸：
/// 后来的设备接入时，前一台收到「已被接管」并断开该终端。
@MainActor
@Observable
final class RemoteHostServer {
    enum Status: Equatable {
        case stopped
        case listening
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "未开启"
            case .listening: return "等待设备连接"
            case .failed(let message): return "出错：\(message)"
            }
        }
    }

    /// 等 Mac 上的人点「允许」的配对请求。
    struct PairingRequest: Identifiable, Equatable {
        let id: UUID
        let deviceName: String
        /// 6 位核对码，应与手机上显示的相同。
        let code: String
    }

    private(set) var status: Status = .stopped
    /// 已通过认证、正连着的设备名。
    private(set) var connectedDevices: [String] = []
    private(set) var trustedPeers: [RemotePeer] = []
    /// 排队中的配对请求；审批面板只显示第一个。
    private(set) var pairingRequests: [PairingRequest] = []
    /// 监听端口（测试用：不广播时客户端直接连这个端口）。
    private(set) var port: UInt16?

    /// 正在看（或控制）这台 Mac 屏幕的设备。同一时刻只有一路桌面流，后来的设备接管。
    struct DesktopViewer: Equatable {
        let connection: UUID
        let channel: UInt32
        let deviceName: String
        let canControl: Bool
        /// 收到过输入：从「查看」升级成「控制」（Mac 上的指示据此改字）。
        var isControlling = false
    }

    private(set) var desktopViewer: DesktopViewer?
    /// 远程桌面依赖的外部能力（采集、注入、授权、开关）。测试里换成合成的。
    @ObservationIgnored var desktopEnvironment: RemoteDesktopEnvironment
    /// 手机要的「新建本机终端」：开窗口、等会话登记好，回会话 id。测试里换成假的。
    @ObservationIgnored var localShellOpener: RemoteLocalShellOpener = .unavailable
    /// 手机看会话列表、接入之前要等它：Mac 刚重启时本机终端还没接回来。
    @ObservationIgnored var sessionRestoration: (@MainActor () async -> Void)?

    @ObservationIgnored let registry: TerminalSessionRegistry
    @ObservationIgnored let identity: RemoteIdentityStore
    @ObservationIgnored let localName: String
    @ObservationIgnored let localID: UUID
    /// 握手时报给手机的可选能力。测试里传空数组，模拟 P1 版本的 Mac。
    @ObservationIgnored let localFeatures: [String]
    /// 声明支持心跳的手机这么久无声就断开。
    @ObservationIgnored let peerSilenceLimit: TimeInterval
    @ObservationIgnored private let advertises: Bool
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: RemoteHostConnection] = [:]
    @ObservationIgnored private var pairingWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// 会话 → 正在接管它的连接与通道。
    @ObservationIgnored private var controllers: [UUID: (connection: UUID, channel: UInt32)] = [:]
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var activityOptions: ProcessInfo.ActivityOptions = []
    @ObservationIgnored private var lastRemoteInput: Date?
    @ObservationIgnored private var lastRemoteOutput: Date?
    @ObservationIgnored private var activityRecheck: Task<Void, Never>?

    init(registry: TerminalSessionRegistry,
         identity: RemoteIdentityStore = RemoteIdentityStore(),
         localName: String = LANSyncCoordinator.localDeviceName(),
         localID: UUID = RemoteLocalDevice.id(),
         advertises: Bool = true,
         localFeatures: [String] = RemoteConstants.localFeatures,
         peerSilenceLimit: TimeInterval = RemoteHeartbeat.standard.peerSilenceLimit,
         desktopEnvironment: RemoteDesktopEnvironment = .disabled) {
        self.localFeatures = localFeatures
        self.peerSilenceLimit = peerSilenceLimit
        self.registry = registry
        self.desktopEnvironment = desktopEnvironment
        self.identity = identity
        self.localName = localName
        self.localID = localID
        self.advertises = advertises
        self.trustedPeers = identity.trustedPeers()
    }

    // MARK: - 起停

    func start() {
        guard listener == nil else { return }
        do {
            // 先把本机长期密钥备好：钥匙串出错时在设置页里直接显示，而不是等到第一台设备连上来。
            _ = try identity.localIdentity()
            let listener = try NWListener(using: RemoteLink.parameters(), on: .any)
            if advertises {
                listener.service = NWListener.Service(name: localName, type: RemoteConstants.serviceType)
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerStateChanged(state) } }
            }
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(connection) } }
            }
            listener.start(queue: DispatchQueue(label: "com.uozi.uTerm.remote.listener"))
            self.listener = listener
            observeRegistry()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        for connection in connections.values { connection.close() }
        for id in Array(pairingWaiters.keys) { resolvePairing(id, approved: false) }
        status = .stopped
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = .listening
            port = listener?.port?.rawValue
        case .failed(let error):
            status = .failed(Self.describe(error))
            listener?.cancel()
            listener = nil
        case .cancelled:
            if status == .listening { status = .stopped }
        default:
            break
        }
    }

    /// 把监听失败翻成用户能照着做的话。最常见的是 macOS 拒绝了「本地网络」权限：
    /// Bonjour 广播注册报 NoAuth（-65555），手机就发现不了这台 Mac。
    private static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_NoAuth) {
            return "macOS 没有允许 uTerm 使用本地网络。请在 系统设置 › 隐私与安全性 › 本地网络 里打开 uTerm，再重新打开这个开关"
        }
        return error.localizedDescription
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        let host = RemoteHostConnection(link: RemoteLink(connection: connection), server: self)
        connections[host.id] = host
        host.start()
    }

    // MARK: - 连接回调

    func connectionAuthorized(_ connection: RemoteHostConnection) {
        refreshConnectedDevices()
    }

    func connectionClosed(_ connection: RemoteHostConnection) {
        connections.removeValue(forKey: connection.id)
        resolvePairing(connection.id, approved: false)
        refreshConnectedDevices()
    }

    private func refreshConnectedDevices() {
        connectedDevices = connections.values.filter(\.isAuthorized).map(\.peerName).sorted()
    }

    // MARK: - 配对

    /// 把配对请求交给 Mac 上的人决定。超时按拒绝处理。
    func requestApproval(connectionID: UUID, deviceName: String, code: String) async -> Bool {
        await withCheckedContinuation { continuation in
            pairingWaiters[connectionID] = continuation
            pairingRequests.append(PairingRequest(id: connectionID, deviceName: deviceName, code: code))
            Task { [weak self] in
                try? await Task.sleep(for: RemoteConstants.pairingTimeout)
                self?.resolvePairing(connectionID, approved: false)
            }
        }
    }

    func approvePairing(_ id: UUID) { resolvePairing(id, approved: true) }
    func rejectPairing(_ id: UUID) { resolvePairing(id, approved: false) }

    private func resolvePairing(_ id: UUID, approved: Bool) {
        pairingRequests.removeAll { $0.id == id }
        pairingWaiters.removeValue(forKey: id)?.resume(returning: approved)
    }

    func trust(_ peer: RemotePeer) throws {
        try identity.trust(peer)
        trustedPeers = identity.trustedPeers()
    }

    /// 撤销信任：已连着的这台设备立即断开，之后再连要重新配对。
    func revoke(_ peerID: UUID) {
        try? identity.revoke(id: peerID)
        trustedPeers = identity.trustedPeers()
        for connection in connections.values where connection.peerID == peerID {
            connection.close()
        }
    }

    // MARK: - 会话与接管

    func sessionInfos() -> [RemoteSessionInfo] {
        registry.entries.map { entry in
            RemoteSessionInfo(id: entry.id, serverID: entry.serverID, serverName: entry.serverName, title: entry.title,
                              windowKind: entry.windowKind, connectedAt: entry.connectedAt,
                              controlledBy: controllers[entry.id].flatMap { connections[$0.connection]?.peerName })
        }
    }

    /// 某个连接接管一个会话。之前接管它的另一个连接收到「已被接管」并断开该终端。
    func claim(sessionID: UUID, connection: RemoteHostConnection, channel: UInt32) {
        if let previous = controllers[sessionID],
           previous.connection != connection.id || previous.channel != channel,
           let holder = connections[previous.connection] {
            holder.detach(channel: previous.channel, notify: true, reason: "已被 \(connection.peerName) 接管")
        }
        controllers[sessionID] = (connection.id, channel)
        lastRemoteInput = Date()
        controllersChanged()
    }

    func isController(sessionID: UUID, connection: RemoteHostConnection, channel: UInt32) -> Bool {
        guard let current = controllers[sessionID] else { return false }
        return current.connection == connection.id && current.channel == channel
    }

    func release(sessionID: UUID, connection: RemoteHostConnection, channel: UInt32) {
        guard isController(sessionID: sessionID, connection: connection, channel: channel) else { return }
        controllers.removeValue(forKey: sessionID)
        controllersChanged()
    }

    private func controllersChanged() {
        updateActivity()
        for connection in connections.values { connection.sendSessions() }
    }

    /// 手机发来了输入，或刚接入一个终端。
    func noteRemoteInput() {
        lastRemoteInput = Date()
        updateActivity()
    }

    /// 手机正在收输出。可能很频繁，所以调用方应当节流。
    func noteRemoteOutput() {
        lastRemoteOutput = Date()
        updateActivity()
    }

    /// 有人在用终端时别让 Mac 闲置睡眠，不然手机那头会突然断掉（规则见 `RemoteSleepPolicy`）；有人在看屏幕时
    /// 连显示器也不让熄（熄屏后 ScreenCaptureKit 不出帧，手机上就是一张冻住的画面）。
    private func updateActivity() {
        var options: ProcessInfo.ActivityOptions = []
        let now = Date()
        if !controllers.isEmpty,
           RemoteSleepPolicy.holdsAwake(now: now, lastInput: lastRemoteInput, lastOutput: lastRemoteOutput) {
            options.insert(.idleSystemSleepDisabled)
            scheduleActivityRecheck(now: now)
        }
        if desktopViewer != nil { options.formUnion([.idleSystemSleepDisabled, .idleDisplaySleepDisabled]) }
        guard options != activityOptions else { return }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        activityOptions = options
        if !options.isEmpty {
            activity = ProcessInfo.processInfo.beginActivity(
                options: options, reason: desktopViewer != nil ? "手机正在远程查看屏幕" : "手机正在远程控制终端")
        }
    }

    /// 不用了不会有人来通知，到点自己重算一次。
    private func scheduleActivityRecheck(now: Date) {
        guard activityRecheck == nil else { return }
        let expiry = RemoteSleepPolicy.expiry(lastInput: lastRemoteInput, lastOutput: lastRemoteOutput)
        let delay = max(1, (expiry ?? now).timeIntervalSince(now))
        activityRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.activityRecheck = nil
            self.updateActivity()
        }
    }

    // MARK: - 桌面

    /// 某个连接开了桌面流：之前在看的另一台设备收到「已被接管」并结束它的桌面流。
    func claimDesktop(connection: RemoteHostConnection, channel: UInt32, canControl: Bool) {
        if let previous = desktopViewer,
           previous.connection != connection.id || previous.channel != channel,
           let holder = connections[previous.connection] {
            holder.stopDesktop(channel: previous.channel, notify: true, reason: "已被 \(connection.peerName) 接管")
        }
        desktopViewer = DesktopViewer(connection: connection.id, channel: channel, deviceName: connection.peerName,
                                      canControl: canControl)
        updateActivity()
    }

    func releaseDesktop(connection: RemoteHostConnection, channel: UInt32) {
        guard let viewer = desktopViewer, viewer.connection == connection.id, viewer.channel == channel else { return }
        desktopViewer = nil
        updateActivity()
    }

    func desktopInputStarted(connection: RemoteHostConnection, channel: UInt32) {
        guard let viewer = desktopViewer, viewer.connection == connection.id, viewer.channel == channel,
              !viewer.isControlling else { return }
        desktopViewer?.isControlling = true
    }

    /// 在 Mac 上结束桌面流（指示条上的「断开」、关掉开关）。
    func endDesktop(reason: String) {
        guard let viewer = desktopViewer, let holder = connections[viewer.connection] else {
            desktopViewer = nil
            updateActivity()
            return
        }
        holder.stopDesktop(channel: viewer.channel, notify: true, reason: reason)
    }

    /// 当前桌面流的发送端读数（探针用）。
    var desktopStats: RemoteDesktopStreamerStats? {
        guard let viewer = desktopViewer else { return nil }
        return connections[viewer.connection]?.desktopStats
    }

    private func observeRegistry() {
        withObservationTracking {
            _ = registry.entries
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.listener != nil else { return }
                    let alive = Set(self.registry.entries.map(\.id))
                    for connection in self.connections.values { connection.sessionsChanged(alive: alive) }
                    self.observeRegistry()
                }
            }
        }
    }
}
