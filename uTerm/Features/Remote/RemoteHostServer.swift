import CryptoKit
import Foundation
@preconcurrency import Network
import Observation

/// Mac 端远控服务：让配对过的设备（手机或另一台 Mac）接入这台 Mac 上已打开的终端。
///
/// `RemoteControlSettings` 打开时监听（Bonjour `_uterm-remote._tcp`，TXT 带本机设备 ID），关闭时连广播一起撤掉。
///
/// 谁能直接接入：本机配对过的设备，或带着本机正在出示的邀请凭据来的设备（`pairingInvitation`）。都不是的，
/// 退回到在 Mac 上核对 6 位码、点「允许」。同一 Apple ID 不算数：每对设备都要配对一次。
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
    /// 已通过握手的连接对应的对端 `deviceID`。设置页按它判「在线」——按名字判会错：握手报的设备名
    /// 和配对时存进 `trustedPeers` 的名字可能不同（改过设备名、或 iCloud 配对记的是另一个名字）。
    private(set) var connectedPeerIDs: Set<UUID> = []
    private(set) var trustedPeers: [RemotePeer] = []
    /// 排队中的配对请求；审批面板只显示第一个。
    private(set) var pairingRequests: [PairingRequest] = []
    /// 正在出示的扫码配对邀请。一次性：有设备用它配上、过期、或关掉配对面板都作废。
    private(set) var pairingInvitation: RemotePairingInvitation?
    /// 监听端口（测试用：不广播时客户端直接连这个端口）。
    private(set) var port: UInt16?

    /// 正在看（或控制）这台 Mac 屏幕的设备。同一时刻只有一路桌面流，后来的设备接管。
    struct DesktopViewer: Equatable {
        let connection: UUID
        let channel: UInt32
        var deviceName: String
        let canControl: Bool
        /// 收到过输入：从「查看」升级成「控制」（Mac 上的指示据此改字）。
        var isControlling = false
        /// 正在把声音传给它（指示条上加一个扬声器）。
        var hasAudio = false
    }

    private(set) var desktopViewer: DesktopViewer?
    /// 在中继上的注册（打开公网接入且导入过配置时才有）。
    private(set) var relayLink: RemoteRelayHostLink?
    /// 这个进程为什么不注册中继（nil = 照常注册）。开发构建与测试宿主和正式版同身份，注册了就会把它顶掉。
    let relayRegistrationBlock: RemoteRelayRegistrationBlock?
    /// 被顶替后的退避（测试里调短）。
    @ObservationIgnored var relaySupersededBackoff = RemoteRelaySupersededBackoff.standard
    /// 存中继配置的地方。测试与测试宿主里为 nil：不读写真实的 iCloud 钥匙串。
    @ObservationIgnored private let relayStore: RemoteRelayConfigStore?
    /// 中继版本与新版本提醒。
    let relayUpdates: RemoteRelayUpdateMonitor
    /// 上次 `updateInternetAccess` 的「保持唤醒」，命令行换配置后重连时沿用。
    @ObservationIgnored private var keepsAwakeForInternet = false
    @ObservationIgnored private var internetActivity: NSObjectProtocol?
    /// 远程桌面依赖的外部能力（采集、注入、授权、开关）。测试里换成合成的。
    @ObservationIgnored var desktopEnvironment: RemoteDesktopEnvironment
    /// 这台 Mac 的屏幕控制（锁屏状态、唤醒、远程解锁、帘幕），全连接共用一个。环境没提供则为 nil（不支持远程解锁）。
    @ObservationIgnored private var _screenController: (any RemoteScreenController)?
    var screenController: (any RemoteScreenController)? {
        if _screenController == nil { _screenController = desktopEnvironment.makeScreenController?() }
        return _screenController
    }
    /// 手机要的「新建本机终端」：开窗口、等会话登记好，回会话 id。测试里换成假的。
    @ObservationIgnored var localShellOpener: RemoteLocalShellOpener = .unavailable
    /// 设备要的「让 Mac 代开一台保存着的主机」：开终端窗口、等会话登记好，回会话 id。测试里换成假的。
    @ObservationIgnored var hostOpener: RemoteHostOpener = .unavailable
    /// 手机看会话列表、接入之前要等它：Mac 刚重启时本机终端还没接回来。
    @ObservationIgnored var sessionRestoration: (@MainActor () async -> Void)?

    @ObservationIgnored let registry: TerminalSessionRegistry
    @ObservationIgnored let identity: RemoteIdentityStore
    @ObservationIgnored private var invitationExpiry: Task<Void, Never>?
    @ObservationIgnored let localName: String
    @ObservationIgnored let localID: UUID
    /// 握手时报给手机的可选能力。测试里传空数组，模拟 P1 版本的 Mac。
    @ObservationIgnored let localFeatures: [String]
    /// 声明支持心跳的手机这么久无声就断开。
    @ObservationIgnored let peerSilenceLimit: TimeInterval
    /// 等手机发来 `keyConfirm` 的时限。
    @ObservationIgnored let keyConfirmationTimeout: Duration
    @ObservationIgnored private let advertises: Bool
    @ObservationIgnored private var listener: NWListener?
    /// 服务开着。不看 `listener`：局域网监听失败时公网接入照常工作，会话推送也要继续。
    @ObservationIgnored private var isRunning = false
    /// 经公网接入的规则，由设置决定。默认谁都不行。
    @ObservationIgnored var internetAccessPolicy: (UUID) -> Bool = { _ in false }
    /// 凭邀请经公网配上的设备：替它勾上「允许经公网接入」。邀请是本机的人主动发出去的，配上了还要再去设置里
    /// 勾一次的话，对方第一次连就会被断开。
    @ObservationIgnored var grantInternetAccess: (UUID) -> Void = { _ in }
    /// 当前的中继配置。可观察：命令行导入后设置页要跟着变。交给别的设备的是 `relayConfig(forPeer:)`。
    var relayConfig: RemoteRelayConfig?
    /// 要吊销、中继还没确认的成员证书。
    @ObservationIgnored let relayRevocations: RemoteRelayRevocations
    /// 正在出示的邀请里带的成员证书：邀请用掉就记到那台设备名下，作废了就吊销。
    @ObservationIgnored private var invitationGrant: RemoteRelayConfig?
    @ObservationIgnored private var connections: [UUID: RemoteHostConnection] = [:]
    @ObservationIgnored private var pairingWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// 会话 → 正在接管它的连接与通道。
    @ObservationIgnored private var controllers: [UUID: (connection: UUID, channel: UInt32)] = [:]
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var activityOptions: ProcessInfo.ActivityOptions = []
    @ObservationIgnored private var lastRemoteInput: Date?
    @ObservationIgnored private var lastRemoteOutput: Date?
    @ObservationIgnored private var activityRecheck: Task<Void, Never>?
    @ObservationIgnored private var tabTitlePush: Task<Void, Never>?
    /// 上次推给设备的程序状态（含 `idle`）。变化推送拿它比出哪些会话变了。
    @ObservationIgnored private var pushedProgramReports: [UUID: ProgramStatusRecord] = [:]
    /// 上次发出去的会话列表里的先后。重排之后跟它不同才重发列表：新开、关掉标签时列表已经随之发过了。
    @ObservationIgnored private var listedTabOrder: [UUID] = []

    init(registry: TerminalSessionRegistry,
         identity: RemoteIdentityStore = RemoteIdentityStore(role: .controllers),
         localName: String = LANSyncCoordinator.localDeviceName(),
         localID: UUID = RemoteLocalDevice.id(),
         advertises: Bool = true,
         localFeatures: [String] = RemoteConstants.localFeatures,
         peerSilenceLimit: TimeInterval = RemoteHeartbeat.standard.peerSilenceLimit,
         keyConfirmationTimeout: Duration = RemoteConstants.handshakeTimeout,
         relayStore: RemoteRelayConfigStore? = nil,
         relayUpdates: RemoteRelayUpdateMonitor = .inert(),
         relayRevocations: RemoteRelayRevocations = RemoteRelayRevocations(defaults: RemoteLocalState.defaults),
         desktopEnvironment: RemoteDesktopEnvironment = .disabled,
         relayRegistrationBlock: RemoteRelayRegistrationBlock? = nil) {
        self.relayStore = relayStore
        self.relayRegistrationBlock = relayRegistrationBlock
        self.relayRevocations = relayRevocations
        self.relayUpdates = relayUpdates
        self.localFeatures = localFeatures
        self.peerSilenceLimit = peerSilenceLimit
        self.keyConfirmationTimeout = keyConfirmationTimeout
        self.registry = registry
        self.desktopEnvironment = desktopEnvironment
        // 被控端只认「允许来控制本机」那张表；传成主控端的表，本机去控制过的主机就能反过来免审批控制本机。
        precondition(identity.role == .controllers, "被控端必须用 controllers 方向的信任表")
        self.identity = identity
        self.localName = localName
        self.localID = localID
        self.advertises = advertises
        self.trustedPeers = identity.trustedPeers()
    }

    // MARK: - 起停

    func start() {
        guard listener == nil else { return }
        isRunning = true
        do {
            // 先把本机长期密钥备好：钥匙串出错时在设置页里直接显示，而不是等到第一台设备连上来。
            _ = try identity.localIdentity()
            let listener = try NWListener(using: RemoteLink.parameters(), on: .any)
            if advertises {
                let txt = NWTXTRecord([RemoteConstants.deviceIDKey: localID.uuidString])
                listener.service = NWListener.Service(name: localName, type: RemoteConstants.serviceType, txtRecord: txt)
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerStateChanged(state) } }
            }
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(connection) } }
            }
            listener.start(queue: DispatchQueue(label: "com.uozi.uTerm.remote.listener"))
            self.listener = listener
            // 监听失败后 listener 置空但 isRunning 仍为真，设置一变又会进来：旧的观察链靠代次作废，
            // 不然每进来一次多挂一条，每次变化推送 N 遍。
            observationGeneration &+= 1
            tabTitlePush?.cancel()
            tabTitlePush = nil
            observeRegistry(generation: observationGeneration)
            observeTabTitles(generation: observationGeneration)
            pushedProgramReports = currentProgramReports()
            observeProgramStatuses(generation: observationGeneration)
            listedTabOrder = registry.orderedEntries().map(\.id)
            observeTabOrder(generation: observationGeneration)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        isRunning = false
        // 连接的关闭是异步的，退出 uTerm 时等不到它们各自收尾：帘幕还挂着就在这里先锁屏、再撤帘幕，
        // 免得进程一退、gamma 一恢复就把已解锁的桌面露出来。
        if let controller = _screenController, controller.isCurtained {
            controller.lockScreen()
            controller.setCurtain(false)
        }
        listener?.cancel()
        listener = nil
        port = nil
        for connection in connections.values { connection.close() }
        for id in Array(pairingWaiters.keys) { resolvePairing(id, approved: false) }
        cancelPairingInvitation()
        relayLink?.stop()
        relayLink = nil
        updateInternetActivity(active: false, keepAwake: false)
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
            return "macOS 没有允许 uTerm 使用本地网络。在「系统设置 › 隐私与安全性 › 本地网络」里打开 uTerm，再重新打开这个开关。"
        }
        return error.localizedDescription
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        accept(transport: RemoteNWTransport(connection: connection))
    }

    /// 接一条已经在路上的连接。不看 `listener`：公网路径不经过它，局域网监听失败也不该连累公网接入。
    func accept(transport: any RemoteTransport, origin: RemoteConnectionOrigin = .localNetwork) {
        if origin.isInternet {
            let unauthenticated = connections.values.filter { $0.origin.isInternet && !$0.isAuthorized }.count
            guard unauthenticated < Self.maxUnauthenticatedInternetConnections else {
                transport.cancel()
                return
            }
        }
        let host = RemoteHostConnection(link: RemoteLink(transport: transport), server: self, origin: origin)
        connections[host.id] = host
        host.start()
    }

    private static let maxUnauthenticatedInternetConnections = 8

    // MARK: - 公网接入

    func allowsInternetAccess(_ id: UUID) -> Bool {
        internetAccessPolicy(id) && !identity.isBlocked(id)
    }

    /// 这个设备 ID 是谁：本机配对过的设备。信令用它决定回不回应。
    func knownPeer(id: UUID) -> RemotePeer? {
        if identity.isBlocked(id) { return nil }
        return identity.peer(id: id)
    }

    /// 能在设置里勾选公网接入的设备：配对过的设备（手机、Mac 都算）。
    var internetAccessCandidates: [RemotePeer] {
        trustedPeers.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// 按设置起停中继注册。配置变了就换一条。
    func updateInternetAccess(enabled: Bool, keepAwake: Bool) {
        keepsAwakeForInternet = keepAwake
        relayConfig = relayStore?.load() ?? relayConfig
        if enabled, let relayConfig, relayRegistrationBlock == nil {
            if relayLink?.config != relayConfig {
                relayLink?.stop()
                let link = RemoteRelayHostLink(config: relayConfig, server: self, supersededBackoff: relaySupersededBackoff)
                relayLink = link
                link.start()
            }
        } else {
            relayLink?.stop()
            relayLink = nil
        }
        updateInternetActivity(active: relayLink != nil, keepAwake: keepAwake)
        internetAccessChanged()
    }

    /// 设置里的「重新连接」：被顶替后不等退避，立刻再注册。
    func reconnectRelay() {
        relayLink?.reconnect()
    }

    /// 钥匙串里当前的中继配置（没有存储的测试里用内存里那份）。
    func loadRelayConfig() -> RemoteRelayConfig? {
        relayStore?.load() ?? relayConfig
    }

    /// 导入中继配置。文件不对、或是别的 Mac 发的成员证书（注册不了主机）时返回 false。
    @discardableResult
    func importRelayConfig(_ config: RemoteRelayConfig) -> Bool {
        guard !config.isCertificate else {
            AppLogger.info("没有导入中继配置：这是别的 Mac 发的成员证书，只能用来连那台 Mac", category: RemoteLog.category)
            return false
        }
        do {
            try relayStore?.save(config)
        } catch {
            AppLogger.info("保存中继配置失败：\(error.localizedDescription)", category: RemoteLog.category)
            return false
        }
        if relayConfig?.relayID != config.relayID { relayUpdates.reset() }
        relayConfig = config
        // 开着公网接入时立刻换到新中继上（设置页之外的入口——命令行——不会再去调 updateInternetAccess）。
        if relayLink != nil { updateInternetAccess(enabled: true, keepAwake: keepsAwakeForInternet) }
        return true
    }

    func clearRelayConfig() {
        relayStore?.clear()
        relayConfig = nil
        relayUpdates.reset()
    }

    /// App Nap 会把心跳拖到几分钟一次，中继就把这台 Mac 摘掉了。只有用户选了「保持唤醒」才阻止闲置睡眠。
    private func updateInternetActivity(active: Bool, keepAwake: Bool) {
        if let internetActivity { ProcessInfo.processInfo.endActivity(internetActivity) }
        internetActivity = nil
        guard active else { return }
        let options: ProcessInfo.ActivityOptions = keepAwake ? .userInitiated : .userInitiatedAllowingIdleSystemSleep
        internetActivity = ProcessInfo.processInfo.beginActivity(options: options, reason: "uTerm 公网接入")
    }

    /// 公网接入的设置变了：断开不再允许的连接，把配置交给新勾选的设备。
    func internetAccessChanged() {
        for connection in connections.values {
            connection.enforceInternetPolicy()
            connection.sendRelayConfigIfAllowed()
        }
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
        let authorized = connections.values.filter(\.isAuthorized)
        connectedDevices = authorized.map(\.peerName).sorted()
        connectedPeerIDs = Set(authorized.compactMap(\.peerID))
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

    /// 出示一张新的扫码邀请（旧的作废），`RemoteConstants.invitationLifetime` 后自动作废。
    @discardableResult
    func makePairingInvitation() throws -> RemotePairingInvitation {
        let key = try identity.localIdentity().publicKey.rawRepresentation
        cancelPairingInvitation()
        // 开着公网接入（已注册到中继）才带上中继：否则对方拿着它也找不到这台 Mac。
        let relay = relayLink.flatMap {
            sharedRelay(from: $0.config, lifetime: RemoteRelayConfig.invitationCertificateLifetime)
        }
        invitationGrant = relay?.isCertificate == true ? relay : nil
        let invitation = RemotePairingInvitation(macID: localID, macName: localName, macKey: key,
                                                 token: RemotePairingInvitation.newToken(), relay: relay)
        pairingInvitation = invitation
        invitationExpiry?.cancel()
        invitationExpiry = Task { [weak self] in
            guard (try? await Task.sleep(for: RemoteConstants.invitationLifetime)) != nil else { return }
            if self?.pairingInvitation == invitation { self?.cancelPairingInvitation() }
        }
        return invitation
    }

    /// 收回正在出示的邀请。没用掉的邀请里带的成员证书一并吊销：链接可能已经发出去了。
    func cancelPairingInvitation() {
        invitationExpiry?.cancel()
        invitationExpiry = nil
        pairingInvitation = nil
        if let grant = invitationGrant { revokeRelayGrant(grant) }
        invitationGrant = nil
    }

    /// 凭邀请配上的结果：邀请里带的成员证书（有的话）记到那台设备名下。
    struct PairingRedemption {
        var relayGrant: RemoteRelayConfig?
    }

    /// 对方带来的邀请凭据对得上正在出示的邀请：用掉它（一次性）。对不上返回 nil。
    func redeemPairingProof(_ proof: Data, phoneKey: Data) -> PairingRedemption? {
        guard let invitation = pairingInvitation,
              RemotePairingInvitation.verify(proof, token: invitation.token, phoneKey: phoneKey,
                                             macKey: invitation.macKey) else { return nil }
        let redemption = PairingRedemption(relayGrant: invitationGrant)
        invitationGrant = nil
        cancelPairingInvitation()
        return redemption
    }

    // MARK: - 中继成员证书

    /// 交给别人的中继：中继认证书（1.3.0 起）时是只能连本机、有到期时间的证书，老中继上是共用的成员密钥，
    /// 还不知道中继版本（没注册上）时不给。
    ///
    /// 同一台设备复用上次那张；签发超过 7 天就续（同一把钥匙、新的到期时间，见 `needsRenewal`）。设备每次连上来
    /// 主机都会把它交过去，平时还会经中继来要（`renewRelayGrant`），所以正常用着的设备感觉不到续期。邀请里那张
    /// 只给 `lifetime`（1 天），配上后第一次就续成一年。
    private func sharedRelay(from root: RemoteRelayConfig, peer: inout RemotePeer?,
                             lifetime: TimeInterval = RemoteRelayConfig.certificateLifetime) -> RemoteRelayConfig? {
        guard !root.isCertificate,
              let supported = RemoteRelayVersion.supportsMemberCertificates(relayUpdates.runningVersion) else { return nil }
        guard supported else { return root }
        if var grant = peer?.relayGrant, grant.relayID == root.relayID {
            if grant.needsRenewal(), let renewed = try? grant.renewed(by: root) { grant = renewed }
            // 中继改了地址或名字就跟着改。
            grant.name = root.name
            grant.host = root.host
            grant.port = root.port
            peer?.relayGrant = grant
            return grant
        }
        guard let grant = try? root.certificate(for: localID, lifetime: lifetime) else { return nil }
        if let old = peer?.relayGrant { revokeRelayGrant(old) }
        peer?.relayGrant = grant
        return grant
    }

    private func sharedRelay(from root: RemoteRelayConfig, lifetime: TimeInterval) -> RemoteRelayConfig? {
        var none: RemotePeer?
        return sharedRelay(from: root, peer: &none, lifetime: lifetime)
    }

    /// 交给这台配对过的设备的中继配置（见 `sharedRelay`）。第一次给它发证书时记到它名下。
    func relayConfig(forPeer peerID: UUID) -> RemoteRelayConfig? {
        guard let root = relayConfig, let known = identity.peer(id: peerID) else { return nil }
        var peer: RemotePeer? = known
        let config = sharedRelay(from: root, peer: &peer)
        if let peer, peer != known { try? trust(peer) }
        return config
    }

    /// 设备经中继来续它手里那张证书：只续自己给这台设备记着的那张（公钥对得上、还没过期），勾选过公网接入
    /// （信令那层已核对）。续了还是同一把钥匙；没到续的时候就原样再给一次。
    func renewRelayGrant(peerID: UUID, member: String) -> RemoteRelayConfig? {
        guard let grant = identity.peer(id: peerID)?.relayGrant, grant.memberPublicKey == member,
              !grant.isExpired() else { return nil }
        let renewed = relayConfig(forPeer: peerID)
        guard renewed?.memberPublicKey == member else { return nil }
        return renewed
    }

    /// 吊销一张发出去的证书：先记下，注册在那台中继上时立刻发，否则下次注册上再补。
    func revokeRelayGrant(_ grant: RemoteRelayConfig) {
        guard let member = grant.memberPublicKey else { return }
        relayRevocations.add(member, relayID: grant.relayID, expires: grant.expires)
        relayLink?.sendRevocations()
    }

    /// 中继注册上了：现在知道它的版本，把中继交给已经连着、勾选过的设备，补发没确认的吊销。
    func relayRegistered() {
        for connection in connections.values { connection.sendRelayConfigIfAllowed() }
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

    /// 在 Mac 上给已配对的设备改名（只存本机，不告诉对方）。传空或与设备报的名字相同 = 恢复跟着设备报的名字走。
    func rename(_ peerID: UUID, to name: String) throws {
        guard let peer = identity.peer(id: peerID) else { return }
        let renamed = peer.renamed(name)
        guard renamed != peer else { return }
        try trust(renamed)
        for connection in connections.values where connection.peerID == peerID {
            connection.peerRenamed(to: renamed.displayName)
        }
        if desktopViewer.map({ connections[$0.connection]?.peerID == peerID }) == true {
            desktopViewer?.deviceName = renamed.displayName
        }
        refreshConnectedDevices()
    }

    /// 撤销信任：已连着的这台设备立即断开，之后再连要重新配对。发给它的中继证书一并吊销。
    func revoke(_ peerID: UUID) {
        if let grant = identity.peer(id: peerID)?.relayGrant { revokeRelayGrant(grant) }
        try? identity.revoke(id: peerID)
        trustedPeers = identity.trustedPeers()
        for connection in connections.values where connection.peerID == peerID {
            connection.close()
        }
    }

    // MARK: - 会话与接管

    /// 会话列表，按 Mac 上的标签顺序排（`TerminalSessionRegistry.orderedEntries`），每条带上排位。
    func sessionInfos() -> [RemoteSessionInfo] {
        let ordered = registry.orderedEntries()
        listedTabOrder = ordered.map(\.id)
        return ordered.enumerated().map { index, entry in
            RemoteSessionInfo(id: entry.id, serverID: entry.serverID, serverName: entry.serverName, title: entry.title,
                              windowKind: entry.windowKind, connectedAt: entry.connectedAt,
                              controlledBy: controllers[entry.id].flatMap { connections[$0.connection]?.peerName },
                              tabTitle: registry.displayTitle(of: entry), order: index)
        }
    }

    /// 此刻有程序状态的会话（订阅时的全量快照）。
    func programStatusSnapshot() -> [RemoteProgramStatusUpdate.Entry] {
        registry.entries.compactMap { entry in
            registry.programReport(of: entry).map {
                RemoteProgramStatusUpdate.Entry(sessionID: entry.id, status: RemoteProgramStatus($0))
            }
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
        desktopEnvironment.displaysInUse(true)
        updateActivity()
    }

    func releaseDesktop(connection: RemoteHostConnection, channel: UInt32) {
        guard let viewer = desktopViewer, viewer.connection == connection.id, viewer.channel == channel else { return }
        desktopViewer = nil
        desktopEnvironment.displaysInUse(false)
        updateActivity()
    }

    func desktopInputStarted(connection: RemoteHostConnection, channel: UInt32) {
        guard let viewer = desktopViewer, viewer.connection == connection.id, viewer.channel == channel,
              !viewer.isControlling else { return }
        desktopViewer?.isControlling = true
    }

    /// 远控设置变了（如打开 / 关闭「允许远程解锁」）：把最新的锁屏状态推给正在看屏幕的手机，解锁入口立刻随之变化。
    func desktopSettingsChanged() {
        guard let viewer = desktopViewer else { return }
        connections[viewer.connection]?.sendScreenState()
    }

    func desktopAudioChanged(connection: RemoteHostConnection, channel: UInt32, on: Bool) {
        guard let viewer = desktopViewer, viewer.connection == connection.id, viewer.channel == channel,
              viewer.hasAudio != on else { return }
        desktopViewer?.hasAudio = on
    }

    /// Mac 上关了「允许传输声音」：正在送的声音停掉（画面不受影响）。
    func endDesktopAudio(reason: String) {
        guard let viewer = desktopViewer, let holder = connections[viewer.connection] else { return }
        holder.stopAudio(notify: reason)
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

    /// 当前这一轮观察链的代次。`start()` 每次挂新链时加一，旧链醒来对不上就自行结束。
    private var observationGeneration = 0

    private func observeRegistry(generation: Int) {
        withObservationTracking {
            _ = registry.entries
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, generation == self.observationGeneration else { return }
                    let alive = Set(self.registry.entries.map(\.id))
                    for connection in self.connections.values { connection.sessionsChanged(alive: alive) }
                    self.observeRegistry(generation: generation)
                }
            }
        }
    }

    /// 程序可能每秒改很多次标题（Claude Code 的转圈动画），所以标签名不走 `observeRegistry` 那条即时通道，
    /// 第一次变化后等一个间隔，把这段时间的变化合成一次推送。
    private func observeTabTitles(generation: Int) {
        withObservationTracking {
            for entry in registry.entries { _ = registry.displayTitle(of: entry) }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleTabTitlePush(generation: generation) }
            }
        }
    }

    /// 程序状态不节流：「等待确认」要马上到手机上。同一轮主线程里的多次变化由观察回调合成一次。
    private func observeProgramStatuses(generation: Int) {
        withObservationTracking {
            for entry in registry.entries { _ = registry.programReport(of: entry) }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, generation == self.observationGeneration else { return }
                    self.pushProgramStatusChanges()
                    self.observeProgramStatuses(generation: generation)
                }
            }
        }
    }

    /// Mac 上重排、拆分、跨组拖动标签：重发会话列表，设备上的标签跟着换顺序。不节流，重排本来就不频繁；
    /// 拖分隔条也会叫醒这里，但先后没变就不发。
    private func observeTabOrder(generation: Int) {
        withObservationTracking {
            _ = registry.orderedEntries()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, generation == self.observationGeneration else { return }
                    if self.registry.orderedEntries().map(\.id) != self.listedTabOrder {
                        for connection in self.connections.values { connection.sendSessions() }
                    }
                    self.observeTabOrder(generation: generation)
                }
            }
        }
    }

    private func currentProgramReports() -> [UUID: ProgramStatusRecord] {
        var reports: [UUID: ProgramStatusRecord] = [:]
        for entry in registry.entries {
            if let report = registry.programReport(of: entry) { reports[entry.id] = report }
        }
        return reports
    }

    private func pushProgramStatusChanges() {
        let current = currentProgramReports()
        let previous = pushedProgramReports
        pushedProgramReports = current
        let changed = Set(current.keys).union(previous.keys).filter { current[$0] != previous[$0] }
        guard !changed.isEmpty else { return }
        let update = RemoteProgramStatusUpdate(replacesAll: false, entries: changed.sorted { $0.uuidString < $1.uuidString }.map {
            RemoteProgramStatusUpdate.Entry(sessionID: $0, status: current[$0].map(RemoteProgramStatus.init))
        })
        for connection in connections.values { connection.sendProgramStatus(update) }
    }

    private func scheduleTabTitlePush(generation: Int) {
        guard isRunning, generation == observationGeneration, tabTitlePush == nil else { return }
        tabTitlePush = Task { [weak self] in
            try? await Task.sleep(for: RemoteConstants.tabTitlePushInterval)
            // 旧代次的任务（start() 已经撤掉它）不碰 tabTitlePush：那里可能已经是新代次的任务。
            guard let self, generation == self.observationGeneration else { return }
            self.tabTitlePush = nil
            guard self.isRunning else { return }
            for connection in self.connections.values { connection.sendSessions() }
            self.observeTabTitles(generation: generation)
        }
    }
}

/// 这个进程不注册中继的原因。
nonisolated enum RemoteRelayRegistrationBlock: Equatable, Sendable {
    /// 不在 /Applications 或 ~/Applications 里的开发构建（启动参数 `-RemoteRelayAllowDevBuild YES` 可放开）。
    case developmentBuild
    /// 跑测试的宿主进程。
    case testHost

    static func current(isTestHost: Bool, isInstalled: Bool, arguments: [String]) -> Self? {
        if isTestHost { return .testHost }
        if isInstalled || AppInstallLocation.allowsDevBuildRelay(arguments: arguments) { return nil }
        return .developmentBuild
    }
}
