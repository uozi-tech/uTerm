import CryptoKit
import Foundation
@preconcurrency import Network
import Observation

/// 「我的 Mac」：配对过的 Mac、局域网里还没配对的 Mac，以及每台 Mac 的远控客户端。两端共用：
/// iPhone / iPad 与 Mac 当主控端都是它；iOS 退到后台的处理在 `RemoteMacDirectoryLifecycle`。
///
/// 配对过的 Mac 只来自本机信任（局域网审批或邀请配上的），同一 Apple ID 不算数。Bonjour（`_uterm-remote._tcp`）
/// 回答「哪台此刻在线、地址是什么」：按 TXT 记录里的设备 ID 对号，设备 ID 与公钥在握手里再核对一遍
///（`RemoteMacClient.expectedPeer`）。对不上号的在线 Mac 分两种：
/// - 登记在本机同一个 iCloud 账户里的（设备组名册里有它的 `device` 条目，`accountDevices`）自动列进「附近的 Mac」；
/// - 其余的（别人的 Mac、没开 iCloud 钥匙串的）**不自动列出来**，只在「配对其他 Mac」里给看（`otherNearbyMacs`；
///   Mac 是列表头「+」打开的面板，iOS 是扫码页里的入口）。别人的 Mac 一进同一个局域网就出现在你的列表里，既打扰，
///   也让人误点去配对。
/// 两种点了都是发起局域网配对：Mac 上输入这里显示的核对码之后才记进本机信任。账户只决定列不列，不构成信任。
///
/// 浏览要「本地网络」授权，所以和局域网同步一样推迟：用户第一次点「连接我的 Mac」才开始
/// （之后每次进主机页自动开始），不会一启动就弹系统授权框。
@MainActor
@Observable
final class RemoteMacDirectory {
    nonisolated struct Mac: Identifiable, Hashable {
        enum Source: Hashable {
            /// 本机配对过（局域网审批或邀请）。
            case paired
            /// 局域网里看到、还没配对。连上去要在 Mac 上审批。
            case nearby
            /// 调试直连（`-RemoteDebugEndpoint`），事先不知道身份。
            case debug
        }

        /// 设备 ID 的字符串；调试直连是 `debug:<地址>`。
        let id: String
        let deviceID: UUID?
        var name: String
        var publicKey: Data?
        var source: Source
        /// 在线时的服务端点；nil = 此刻在局域网里找不到它。
        var endpoint: NWEndpoint?
        /// 此刻在中继上，可以跨公网连。
        var isOnRelay = false
        /// 只给这台用的中继（配对时记下的）；nil = 走默认中继。
        var relay: RemoteRelayConfig?

        var isOnline: Bool { endpoint != nil || isOnRelay }

        var expectedPeer: RemotePeer? {
            guard let deviceID, let publicKey else { return nil }
            return RemotePeer(id: deviceID, name: name, publicKey: publicKey, pairedAt: .distantPast)
        }
    }

    private static let activatedKey = DefaultsKey.remoteBrowseActivated

    /// 配对过的 Mac（在线的在前）。
    private(set) var macs: [Mac] = []
    /// 局域网里此刻在线、还没配对、登记在本机同一个 iCloud 账户里的 Mac。自动列进「附近的 Mac」。
    private(set) var nearbyMacs: [Mac] = []
    /// 局域网里此刻在线、还没配对、不在本机 iCloud 账户里的 Mac。不自动列出来，只在「配对其他 Mac」里给看。
    private(set) var otherNearbyMacs: [Mac] = []
    /// 刚凭邀请配上、等它一上线就打开的 Mac（`Mac.id`）。主机页的「我的 Mac」负责打开并清掉。
    var pendingOpenMacID: String?
    /// 打开链接收到、还没确认的邀请（Mac 上点开 `uterm://pair`）。「我的 Mac」窗口弹出确认并清掉。
    var pendingInvitation: RemotePairingInvitation?
    private(set) var isBrowsing = false
    /// 存储属性而不是现读 UserDefaults：视图要能观察到它从 false 变成 true。
    private(set) var isActivated: Bool
    /// 只走公网（开发者选项）：正式连接无视局域网里看到的 Mac，一律经中继或打洞，打洞也不用私有地址，用来在家里
    /// 复现外出时的情况。默认关。网络诊断不看它：诊断的每条路都强制只走自己。
    /// 切换立即生效：已有连接马上断开，按新的路重连（只换路由表的话，连着的那条会一直留在旧路上）。
    /// 启动参数 `-remote.internetOnly YES` 同样生效（手机插着线收日志时，Mac 会经 USB 链路被 Bonjour 发现）。
    var internetOnly: Bool {
        didSet {
            guard internetOnly != oldValue else { return }
            defaults.set(internetOnly, forKey: Self.internetOnlyKey)
            online = internetOnly ? [:] : discovered
            rebuild()
            for client in clients.values { client.disconnect() }
        }
    }
    private static let internetOnlyKey = DefaultsKey.remoteInternetOnly

    @ObservationIgnored let identity: RemoteIdentityStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var browser: NWBrowser?
    /// Bonjour 此刻看到的、带设备 ID 的 Mac：设备 ID → (电脑名, 端点)。网络诊断测局域网用它。
    /// 要被观察：「只走公网」打开时 `macs` 不随它变，诊断页的「局域网」标记全靠它刷新。
    private var discovered: [UUID: (name: String, endpoint: NWEndpoint)] = [:]
    /// 正式连接认的局域网 Mac：「只走公网」打开时为空。
    @ObservationIgnored private var online: [UUID: (name: String, endpoint: NWEndpoint)] = [:]
    @ObservationIgnored private var clients: [String: RemoteMacClient] = [:]
    /// 扫码拿到、还没用掉的令牌：设备 ID → 令牌。
    @ObservationIgnored private var pendingTokens: [UUID: Data] = [:]
    @ObservationIgnored private var networkWatcher: RemoteNetworkWatcher?
    /// 读「本机 iCloud 账户里登记过哪些设备」（`liveAccountDevices`）。nil = 一台都不认，没配对的全进 `otherNearbyMacs`。
    @ObservationIgnored private let readAccountDevices: (@MainActor () -> Set<UUID>)?
    /// 上次读到的那一份。只拿来决定「附近的 Mac」自动列谁：名册里的条目同一个钥匙串圈里谁都能写，不构成信任。
    @ObservationIgnored private var accountDevices: Set<UUID> = []
    /// 局域网里有对不上账户的 Mac、又有界面在看时，隔一会儿重读一次名册（它的条目可能还在 iCloud 的路上）。
    @ObservationIgnored private var accountRecheck: Task<Void, Never>?
    @ObservationIgnored let accountRecheckInterval: Duration
    /// 平台的前后台监听（iOS 的 `RemoteMacDirectoryLifecycle`），跟着目录活。
    @ObservationIgnored var lifecycle: AnyObject?
    /// 主机带来的中继能不能当本机默认中继（见 `RemoteRelayPlacement`）。iOS 能；Mac 不能：Mac 的默认中继也是
    /// 它自己被控时注册的那台，不能因为去控制别人就换掉。
    @ObservationIgnored let adoptsRelayAsDefault: Bool
    /// 中继配置存放处。测试里为 nil：不读写真实的 iCloud 钥匙串。
    @ObservationIgnored private let relayStore: RemoteRelayConfigStore?
    /// 每个成员身份一个客户端（`RemoteRelayConfig.memberIdentity`：中继 ID，证书再加它能连的主机）。
    @ObservationIgnored private var relayClients: [String: RemoteRelayClient] = [:]
    @ObservationIgnored private var relayPoll: Task<Void, Never>?
    /// 各个成员身份此刻看得到的在线 Mac：`memberIdentity` → 主机 ID。
    @ObservationIgnored private var relayHosts: [String: Set<UUID>] = [:]
    /// 问中继「谁在线」。测试注入假的，好数清楚问了几次。
    @ObservationIgnored private let fetchRelayHosts: @Sendable (RemoteRelayClient) async throws -> Set<UUID>
    /// 前台时多久问一次中继。
    @ObservationIgnored let relayPollInterval: Duration
    /// 只在有界面显示在线状态时才问。Mac 上 15 秒太迟钝：对面 Mac 重启、上下线后要等好久列表才变（user 反馈
    /// 「要切出去才刷新」）；Mac 没有蜂窝射频的顾虑，缩到 5 秒。iOS 仍是 15 秒，省电。
    nonisolated static var defaultRelayPollInterval: Duration {
        #if os(macOS)
        .seconds(5)
        #else
        .seconds(15)
        #endif
    }
    /// 给某台 Mac 的连接配上「反过来读写本机文件」的门禁（参数是 `Mac.id`）。Mac 上由 App 接到共享文件夹的设置；
    /// 手机不设，握手时也就不声明这项能力。
    @ObservationIgnored var fileSharing: (@MainActor (String) -> RemoteFileSharingAccess?)?
    /// 忘记了一台 Mac（参数是 `Mac.id`）：跟它有关的本机设置一并收回。
    @ObservationIgnored var onForget: (@MainActor (String) -> Void)?
    /// 此刻有几处界面在显示 Mac 的在线状态（主机页「我的 Mac」、新建终端抽屉里的 Mac 行、网络诊断）。
    /// 只有它大于 0 时才按 `relayPollInterval` 一直问；没人看就不问。见 `keepLiveStatusFresh()`。
    @ObservationIgnored private var liveStatusDemand = 0
    @ObservationIgnored private var isInForeground: Bool
    /// 最近一次问完中继的时刻；nil = 还没问过。
    @ObservationIgnored private var lastRelayPoll: ContinuousClock.Instant?
    /// 轮询任务的代号：旧任务收尾时不能把新任务的引用清掉。
    @ObservationIgnored private var relayPollGeneration = 0

    init(identity: RemoteIdentityStore = RemoteIdentityStore(role: .hosts),
         relayStore: RemoteRelayConfigStore? = nil, defaults: UserDefaults = RemoteLocalState.defaults,
         adoptsRelayAsDefault: Bool = true, startsInForeground: Bool = true,
         relayPollInterval: Duration = RemoteMacDirectory.defaultRelayPollInterval,
         fetchRelayHosts: @escaping @Sendable (RemoteRelayClient) async throws -> Set<UUID> = {
             try await $0.onlineHosts()
         },
         // 排在 `fetchRelayHosts` 后面：好几处测试把它写成尾随闭包，闭包类型的参数排在它前面会被尾随闭包认走。
         accountDevices: (@MainActor () -> Set<UUID>)? = RemoteMacDirectory.liveAccountDevices,
         accountRecheckInterval: Duration = .seconds(5)) {
        self.identity = identity
        self.relayStore = relayStore
        self.defaults = defaults
        self.adoptsRelayAsDefault = adoptsRelayAsDefault
        self.relayPollInterval = relayPollInterval
        self.fetchRelayHosts = fetchRelayHosts
        self.readAccountDevices = accountDevices
        self.accountRecheckInterval = accountRecheckInterval
        // 推送把 App 拉起在后台时不该问中继；回到前台由 returnedToForeground 翻过来。
        self.isInForeground = startsInForeground
        self.isActivated = defaults.bool(forKey: Self.activatedKey)
        self.internetOnly = defaults.bool(forKey: Self.internetOnlyKey)
        refreshPaired()
        #if DEBUG && os(iOS)
        // 调试跑链路矩阵时不等用户点进远控页：直接开始找 Mac、问中继。
        if defaults.integer(forKey: Self.debugMatrixKey) > 0 {
            Task { @MainActor [weak self] in self?.startBrowsing() }
        }
        #endif
    }

    /// 每台 Mac 有几个窗口在用它的连接（Mac 上终端窗口与屏幕窗口共用一条）。
    @ObservationIgnored private var holders: [String: Int] = [:]

    /// 一个窗口开始用这台 Mac 的连接。和 `releaseClient` 成对调用。
    func acquireClient(for mac: Mac) -> RemoteMacClient {
        holders[mac.id, default: 0] += 1
        return client(for: mac)
    }

    /// 一个窗口不用了：没有别的窗口在用时才断开，免得关屏幕窗口把终端窗口也断掉。
    func releaseClient(macID: String) {
        let left = max(0, (holders[macID] ?? 0) - 1)
        holders[macID] = left == 0 ? nil : left
        if left == 0 { clients[macID]?.disconnect() }
    }

    /// 已有的远控连接（开过这台 Mac 的窗口才有）；没有就返回 nil，不新建。
    ///
    /// `clients` 不在观察跟踪里：读它的视图看不到「新建了一条连接」，要自己隔一会儿再取一次
    ///（拿到之后连接本身是 `@Observable`，连上 / 断开 / 往返都会刷新）。
    func existingClient(macID: String) -> RemoteMacClient? { clients[macID] }

    /// 有连着的 Mac（iOS 退到后台时据此申请一段后台时间）。
    var hasConnectedClients: Bool {
        clients.values.contains { $0.state == .connected }
    }

    /// App 退到后台：不再问中继谁在线。
    func enteredBackground() {
        isInForeground = false
        stopRelayPolling()
        accountRecheck?.cancel()
        accountRecheck = nil
    }

    /// App 回到前台：重读配对、接着问中继，各条连接看看还通不通。
    func returnedToForeground() {
        isInForeground = true
        refreshAccountDevices()
        refreshPaired()
        // 只在有界面显示在线状态时才接着问中继；没人看时等界面出现（或抽屉读 `pairedMacs`）再问。
        if isActivated, wantsLiveRelayStatus { startRelayPolling() }
        for client in clients.values { client.returnedToForeground() }
    }

    /// 用户主动点了「连接我的 Mac」：记住，之后自动浏览。
    func activate() {
        defaults.set(true, forKey: Self.activatedKey)
        isActivated = true
        startBrowsing()
    }

    func startBrowsing() {
        refreshAccountDevices()
        refreshPaired()
        startRelayPolling()
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteConstants.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(results) } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .failed = state { self?.restartBrowsing() }
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "com.uozi.uTerm.remote.browser"))
        self.browser = browser
        isBrowsing = true
    }

    /// 调试：启动参数 `-RemoteDebugEndpoint 127.0.0.1:端口` 把一个地址当作 Mac 列出来，不走 Bonjour。
    /// 模拟器与 Mac 共用网络栈，回环地址又不受「本地网络」权限管，联调时用它直连 Mac 上的测试服务。
    private var debugMacs: [Mac] {
        #if DEBUG
        guard let raw = defaults.string(forKey: DefaultsKey.remoteDebugEndpoint), let colon = raw.lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(raw[raw.index(after: colon)...])) else { return [] }
        let host = NWEndpoint.Host(String(raw[..<colon]))
        return [Mac(id: "debug:\(raw)", deviceID: nil, name: "调试 Mac（\(raw)）", publicKey: nil, source: .debug,
                    endpoint: .hostPort(host: host, port: port))]
        #else
        return []
        #endif
    }

    private func restartBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        startBrowsing()
    }

    /// 只认 TXT 里带设备 ID 的结果；电脑名只拿来显示。没有设备 ID 的（老版本 Mac）不认。
    private func update(_ results: Set<NWBrowser.Result>) {
        setDiscovered(Self.onlineMacs(results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let txt) = result.metadata else { return nil }
            return (name, txt[RemoteConstants.deviceIDKey], result.endpoint)
        }))
    }

    /// Bonjour 此刻看到的 Mac 换了一批（测试直接调它，`NWBrowser.Result` 造不出来）。
    func setDiscovered(_ found: [UUID: (name: String, endpoint: NWEndpoint)]) {
        discovered = found
        online = internetOnly ? [:] : discovered
        // 新出现的 Mac 可能刚登记进账户：有人在线才读（读一次是一次本机钥匙串查询）。
        if !found.isEmpty { refreshAccountDevices() }
        rebuild()
    }

    // MARK: - 同一个 iCloud 账户

    /// 本机 iCloud 账户里登记过的设备：设备组名册（iCloud 钥匙串 `com.uozi.uTerm.remote.group`，加上快通道刚送到的）
    /// 里的 `device` 条目。每台有远控身份的设备开着 uTerm 时都会登记自己（`RemoteDeviceGroup.register`），进没进
    /// 设备组都一样。测试宿主里这份名册只在内存，读不到真实钥匙串。
    nonisolated static func liveAccountDevices() -> Set<UUID> {
        Set(RemoteGroupRoster(storage: RemoteGroupOverlayStorage.live).load().devices.map(\.id))
    }

    /// 重读账户里的设备。变了返回 true（调用方接着 `rebuild`）。
    @discardableResult
    private func refreshAccountDevices() -> Bool {
        guard let readAccountDevices else { return false }
        let devices = readAccountDevices()
        guard devices != accountDevices else { return false }
        accountDevices = devices
        return true
    }

    /// 局域网里有对不上账户的 Mac：它可能就是你的另一台 Mac，只是条目还没经 iCloud 同步到（一跳约 20 秒）。
    /// 有界面在显示这份列表、App 在前台时隔 `accountRecheckInterval` 重读一次，对上了就挪进「附近的 Mac」；
    /// 没有这样的 Mac、没人看时不读。
    private var wantsAccountRecheck: Bool {
        readAccountDevices != nil && isInForeground && liveStatusDemand > 0 && !otherNearbyMacs.isEmpty
    }

    private func scheduleAccountRecheck() {
        guard accountRecheck == nil, wantsAccountRecheck else { return }
        let interval = accountRecheckInterval
        accountRecheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                guard self.wantsAccountRecheck else {
                    self.accountRecheck = nil
                    return
                }
                if self.refreshAccountDevices() { self.rebuild() }
            }
        }
    }

    nonisolated static func onlineMacs(_ results: [(name: String, deviceID: String?, endpoint: NWEndpoint)])
        -> [UUID: (name: String, endpoint: NWEndpoint)] {
        var online: [UUID: (name: String, endpoint: NWEndpoint)] = [:]
        for result in results {
            guard let id = result.deviceID.flatMap(UUID.init(uuidString:)) else { continue }
            online[id] = (result.name, result.endpoint)
        }
        return online
    }

    /// 某台 Mac 的远控客户端（同一台 Mac 复用同一个，标签之间共用一条连接）。只对在线的 Mac 调。
    func client(for mac: Mac) -> RemoteMacClient {
        let client: RemoteMacClient
        if let existing = clients[mac.id] {
            client = existing
        } else {
            client = RemoteMacClient(macName: mac.name, endpoint: mac.endpoint ?? .hostPort(host: "0.0.0.0", port: 1),
                                     identity: identity, expectedPeer: mac.expectedPeer)
            let deviceID = mac.deviceID
            client.onRelayConfig = { [weak self] config in self?.receiveRelayConfig(config, from: deviceID) }
            client.onPaired = { [weak self] in self?.rebuild() }
            client.fileSharing = fileSharing?(mac.id)
            clients[mac.id] = client
        }
        updateRoutes(client, for: mac)
        if let deviceID = mac.deviceID, let token = pendingTokens.removeValue(forKey: deviceID) {
            client.pairingToken = token
        }
        if networkWatcher == nil {
            networkWatcher = RemoteNetworkWatcher { [weak self] snapshot in self?.networkChanged(snapshot) }
        }
        return client
    }

    /// 网络变了（换网卡、断网、恢复）：
    /// - 中继的控制连接可能绑在没了的网卡上，全部扔掉，下次用到时在新网络上重连；
    /// - Bonjour 的结果可能过时了（刚关 Wi-Fi 时它还挂着几秒），清掉重新浏览，没有局域网时根本不试局域网；
    /// - 各远控连接按新网卡判断要不要断开重连。
    private func networkChanged(_ snapshot: RemoteNetworkSnapshot) {
        for relay in relayClients.values { Task { await relay.networkChanged() } }
        if !discovered.isEmpty || browser != nil {
            discovered = [:]
            online = [:]
            rebuild()
            if isActivated, snapshot.hasLocalNetwork { restartBrowsing() }
        }
        for client in clients.values { client.networkChanged(snapshot) }
    }

    // MARK: - 中继

    /// 连着的 Mac 发来它的中继配置（或只能连它的成员证书）：按 `RemoteRelayPlacement` 存成默认、记在这台 Mac 上，
    /// 或不用记（默认就是同一台中继的成员密钥）。
    func receiveRelayConfig(_ config: RemoteRelayConfig, from deviceID: UUID?) {
        switch RemoteRelayPlacement.place(config, current: defaultRelayConfig(), adoptsAsDefault: adoptsRelayAsDefault) {
        case .keep:
            return
        case .setDefault:
            if adoptsRelayAsDefault { importRelayConfig(config) }
        case .perHost:
            guard let deviceID, var peer = identity.peer(id: deviceID), peer.relay != config else { return }
            peer.relay = config
            try? identity.trust(peer)
            rebuild()
            startRelayPolling()
        }
    }

    /// 导入默认中继配置（扫码、打开链接、或配对过的 Mac 发来）。成员证书不当默认：记到发证的那台 Mac 名下，
    /// 还没配对那台时导入不了。
    @discardableResult
    func importRelayConfig(_ config: RemoteRelayConfig) -> Bool {
        if config.isCertificate {
            guard let host = config.scope.flatMap(UUID.init(uuidString:)), identity.peer(id: host) != nil else {
                return false
            }
            receiveRelayConfig(config, from: host)
            return true
        }
        guard let relayStore else {
            relayConfigOverride = config
            startRelayPolling()
            return true
        }
        guard (try? relayStore.save(config)) != nil else { return false }
        startRelayPolling()
        return true
    }

    /// 没有钥匙串可写时（测试）用的配置。
    @ObservationIgnored private var relayConfigOverride: RemoteRelayConfig?

    private func defaultRelayConfig() -> RemoteRelayConfig? {
        relayConfigOverride ?? relayStore?.load()
    }

    /// 要问的中继：默认那台，加上各台 Mac 单独记的。同一个成员身份只问一次（单独记的优先，它更新）；
    /// 同一台中继上不同主机发的证书各问各的，每张只看得见自己那台。
    private func relayConfigs() -> [RemoteRelayConfig] {
        var byIdentity: [String: RemoteRelayConfig] = [:]
        if let config = defaultRelayConfig() { byIdentity[config.memberIdentity] = config }
        for peer in identity.trustedPeers() {
            if let relay = peer.relay { byIdentity[relay.memberIdentity] = relay }
        }
        return byIdentity.values.sorted { $0.memberIdentity < $1.memberIdentity }
    }

    private func relayClient(for config: RemoteRelayConfig) -> RemoteRelayClient {
        if let existing = relayClients[config.memberIdentity] {
            if existing.relayConfig == config { return existing }
            // 换下来的客户端还握着一条控制连接（自己的读循环让它一直活着），不停掉就一直占着中继的名额。
            Task { await existing.stop() }
        }
        let client = RemoteRelayClient(config: config)
        relayClients[config.memberIdentity] = client
        return client
    }

    /// 连这台 Mac 走哪台中继：它单独记的，否则默认的。
    private func relayClient(for mac: Mac) -> RemoteRelayClient? {
        guard let config = mac.relay ?? defaultRelayConfig() else { return nil }
        return relayClient(for: config)
    }

    /// 这台 Mac 能不能做打洞诊断：配了中继、Mac 在中继上。
    func iceProbeRunner(for mac: Mac) -> (runner: RemoteICEProbeRunner, peer: RemotePeer)? {
        guard mac.isOnRelay, let relay = relayClient(for: mac), let peer = mac.expectedPeer else { return nil }
        return (RemoteICEProbeRunner(relay: relay, identity: identity, localID: RemoteLocalDevice.id()), peer)
    }

    /// 配好的默认中继名字；没配是 nil。读钥匙串，别放进视图 body。
    func relayServerName() -> String? {
        defaultRelayConfig()?.name
    }

    /// 这台 Mac 此刻在局域网里吗（不看「只走公网」）。
    func isOnLocalNetwork(_ mac: Mac) -> Bool {
        mac.deviceID.map { discovered[$0] != nil } ?? false
    }

    /// 对这台 Mac 跑网络诊断。要知道它的身份（配对过）；局域网与中继缺哪条，对应的路直接判不通并写明原因。
    func pathMatrixRunner(for mac: Mac) -> (runner: RemotePathMatrixRunner, peer: RemotePeer)? {
        guard let peer = mac.expectedPeer, let deviceID = mac.deviceID else { return nil }
        var runner = RemotePathMatrixRunner(identity: identity, localID: RemoteLocalDevice.id())
        if let found = discovered[deviceID] {
            runner.lan = RemoteLANTarget(macName: found.name, endpoint: found.endpoint, expectedPeer: peer)
        }
        if let relay = relayClient(for: mac) {
            if mac.isOnRelay {
                runner.relay = relay
            } else {
                runner.relayUnavailable = String(localized: "Mac 不在中继上（未打开「允许经公网接入」，或未勾选这台设备）")
            }
        }
        return (runner, peer)
    }

    private func updateRoutes(_ client: RemoteMacClient, for mac: Mac) {
        client.updateRoutes(endpoint: mac.endpoint, internetDialer: internetDialer(for: mac))
        if let relay = relayClient(for: mac) {
            client.prewarmInternet = { Task { _ = try? await relay.warmUp() } }
        } else {
            client.prewarmInternet = nil
        }
    }

    private func internetDialer(for mac: Mac) -> RemoteMacClient.InternetDialer? {
        guard let relay = relayClient(for: mac), let peer = mac.expectedPeer else { return nil }
        var configured = RemotePathDialer(relay: relay, identity: identity, localID: RemoteLocalDevice.id())
        configured.publicOnly = internetOnly
        let dialer = configured
        return { context in try await dialer.dial(peer, invitationToken: context.pairingToken, trace: context.trace) }
    }

    /// 马上问一次中继谁在线；之后只要还有界面在显示在线状态、App 在前台，就每 `relayPollInterval` 再问一次。
    ///
    /// 以前是 App 在前台就一直每 15 秒问：用户在 SSH 终端、设置里待一个小时，也要往中继发 240 次请求，
    /// 每次都把蜂窝射频从省电态拉起来、再拖几秒尾巴。在线状态只有主机页、新建终端抽屉和网络诊断显示，
    /// 所以改成只在它们出现期间问（出现时立刻问一次，所以打开时不会看到更旧的状态）。
    /// 连接本身不看这份结果（`internetDialer` 只要配了中继、知道公钥），所以不影响连接与重连。
    private func startRelayPolling() {
        relayPoll?.cancel()
        relayPollGeneration += 1
        let generation = relayPollGeneration
        let fetch = fetchRelayHosts
        relayPoll = Task { [weak self] in
            defer { self?.relayPollEnded(generation) }
            while !Task.isCancelled {
                guard let relays = self?.pollTargets(), !relays.isEmpty else {
                    self?.lastRelayPoll = .now
                    self?.setRelayHosts([:])
                    return
                }
                // 各台中继一起问：一台连不上的中继不该把别的中继上的 Mac 也拖成迟迟不显示在线。
                let hosts = await withTaskGroup(of: (String, Set<UUID>).self) { group in
                    for (identity, client) in relays {
                        group.addTask { (identity, (try? await fetch(client)) ?? []) }
                    }
                    var hosts: [String: Set<UUID>] = [:]
                    for await (identity, online) in group { hosts[identity] = online }
                    return hosts
                }
                guard !Task.isCancelled else { return }
                self?.lastRelayPoll = .now
                self?.setRelayHosts(hosts)
                // 刚和中继打过交道：手里该续的证书顺手去续（在线的那几台）。
                self?.startCertificateRenewals()
                // 只借用一下 self，不在睡眠期间强持有它。
                guard let interval = self?.relayPollInterval, self?.wantsLiveRelayStatus == true else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func relayPollEnded(_ generation: Int) {
        guard generation == relayPollGeneration else { return }
        relayPoll = nil
    }

    private func stopRelayPolling() {
        relayPoll?.cancel()
        relayPoll = nil
    }

    /// 要不要接着按间隔问：App 在前台，且有界面在显示在线状态。
    private var wantsLiveRelayStatus: Bool {
        guard isInForeground else { return false }
        #if DEBUG && os(iOS)
        if defaults.integer(forKey: Self.debugMatrixKey) > 0 { return true }
        #endif
        return liveStatusDemand > 0
    }

    /// 显示 Mac 在线状态的界面在可见期间挂着它（`.task { await directory.keepLiveStatusFresh() }`），
    /// 任务取消（界面消失）就返回。第一个挂上时马上问一次中继，最后一个走了就不再问。
    func keepLiveStatusFresh() async {
        liveStatusDemand += 1
        if isActivated, isInForeground, relayPoll == nil { startRelayPolling() }
        scheduleAccountRecheck()
        defer {
            liveStatusDemand -= 1
            if !wantsLiveRelayStatus { stopRelayPolling() }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// 界面上看到的连接状态刚变了（连上 / 断开 / 失败）：不等下一拍，马上重新问一次中继，
    /// 让列表里的在线状态跟上。只在有界面显示在线状态时问；一秒内问过就不再问。
    func refreshLiveStatusNow() {
        guard isActivated, wantsLiveRelayStatus else { return }
        if let lastRelayPoll, ContinuousClock.now - lastRelayPoll < .seconds(1) { return }
        startRelayPolling()
    }

    /// 读在线列表时结果已经旧了、又没有在问：补问一次。新建终端抽屉在工作区里打开，那里挂不上
    /// `keepLiveStatusFresh`（抽屉里一台在线的 Mac 都没有时没有可挂的行），靠这里保证打开时状态是新的。
    /// 设备组有事要在一台此刻不算在线的 Mac 上做时也走这里（`refreshReachability`）。
    func refreshRelayHostsIfStale() {
        guard isActivated, isInForeground, relayPoll == nil else { return }
        if let lastRelayPoll, ContinuousClock.now - lastRelayPoll < relayPollInterval { return }
        // 多半是在视图求值时读到的：不在这一拍里改状态，挪到下一拍。
        Task { @MainActor [weak self] in
            guard let self, self.relayPoll == nil else { return }
            self.startRelayPolling()
        }
    }

    private func pollTargets() -> [(identity: String, client: RemoteRelayClient)] {
        let configs = relayConfigs()
        // 不再用的中继（换了默认、忘了带证书的 Mac）：停掉它的客户端，放掉控制连接。
        let live = Set(configs.map(\.memberIdentity))
        for (identity, client) in relayClients where !live.contains(identity) {
            relayClients[identity] = nil
            Task { await client.stop() }
        }
        return configs.map { ($0.memberIdentity, relayClient(for: $0)) }
    }

    /// 正在续、或最近试过（Mac 不在线、不回）的证书：Mac ID → 上次开始的时刻。
    @ObservationIgnored private var renewalAttempts: [UUID: Date] = [:]
    @ObservationIgnored private var renewalsInFlight: Set<UUID> = []

    /// 该续的证书（签发超过一周、还没过期）、它的 Mac 此刻在中继上、最近一小时没试过：经中继去要新的。
    private func certificatesDue(now: Date) -> [RemotePeer] {
        identity.trustedPeers().filter { peer in
            guard let relay = peer.relay, relay.needsRenewal(now: now), !relay.isExpired(now: now),
                  !renewalsInFlight.contains(peer.id) else { return false }
            if let last = renewalAttempts[peer.id],
               now.timeIntervalSince(last) < RemoteRelayCertificateRenewal.retryInterval { return false }
            return relayHosts[relay.memberIdentity]?.contains(peer.id) ?? false
        }
    }

    private func startCertificateRenewals() {
        let due = certificatesDue(now: Date())
        guard !due.isEmpty else { return }
        Task { [weak self] in await self?.renew(due) }
    }

    /// 手里有别的 Mac 发的成员证书：后台刷新才有事可做。读钥匙串，别放进视图 body。
    var holdsRelayCertificates: Bool {
        identity.trustedPeers().contains { $0.relay?.isCertificate == true }
    }

    /// 后台刷新（iOS 的 BGAppRefreshTask）里调：先问一遍中继谁在线，再把该续的续了。等它们都结束才返回。
    func renewDueCertificates() async {
        guard isActivated else { return }
        var online: [String: Set<UUID>] = [:]
        for (identity, client) in pollTargets() where identity.contains("/") {
            online[identity] = (try? await fetchRelayHosts(client)) ?? []
        }
        for (identity, hosts) in online { relayHosts[identity] = hosts }
        await renew(certificatesDue(now: Date()))
    }

    private func renew(_ peers: [RemotePeer]) async {
        let localID = RemoteLocalDevice.id()
        await withTaskGroup(of: Void.self) { group in
            for peer in peers {
                guard let certificate = peer.relay, !renewalsInFlight.contains(peer.id) else { continue }
                renewalsInFlight.insert(peer.id)
                renewalAttempts[peer.id] = Date()
                let relay = relayClient(for: certificate)
                let identity = self.identity
                group.addTask { [weak self] in
                    let renewed = try? await RemoteRelayCertificateRenewal.renew(
                        certificate, from: peer, relay: relay, identity: identity, localID: localID)
                    await self?.finishRenewal(peer.id, renewed)
                }
            }
        }
    }

    private func finishRenewal(_ macID: UUID, _ renewed: RemoteRelayConfig?) {
        renewalsInFlight.remove(macID)
        guard let renewed else { return }
        AppLogger.info("远程控制：经中继续好了成员证书", category: RemoteLog.category)
        renewalAttempts[macID] = nil
        receiveRelayConfig(renewed, from: macID)
    }

    private func setRelayHosts(_ hosts: [String: Set<UUID>]) {
        guard hosts != relayHosts else { return }
        relayHosts = hosts
        rebuild()
    }

    /// 扫到 Mac 出示的配对码：信任这台 Mac（解除之前的拉黑），下次连它时带上凭据，Mac 那边就直接认这台手机。
    /// 返回这台 Mac（可能此刻不在线）。
    @discardableResult
    func pair(with invitation: RemotePairingInvitation) throws -> Mac? {
        let existing = identity.peer(id: invitation.macID)
        var peer = RemotePeer(id: invitation.macID, name: invitation.macName, publicKey: invitation.macKey,
                              pairedAt: Date(), platform: RemoteDevicePlatform.mac.rawValue)
        // 重新配同一台 Mac：留下用户起的别名、它单独记的中继（这张邀请没带中继时）。
        peer.alias = existing?.alias
        peer.relay = existing?.relay
        // 邀请带着中继：本机没有默认中继（或就是同一台）就存成默认，否则只给这台 Mac 用。
        if let relay = invitation.relay {
            switch RemoteRelayPlacement.place(relay, current: defaultRelayConfig(), adoptsAsDefault: adoptsRelayAsDefault) {
            case .setDefault: importRelayConfig(relay)
            case .perHost: peer.relay = relay
            case .keep: break
            }
        }
        try identity.trust(peer)
        pendingTokens[invitation.macID] = invitation.token
        // 公钥变了（Mac 重装过）：之前按旧身份建的客户端作废，先断开它——窗口还握着它的话，计数照旧，
        // 下次取客户端时按扫到的公钥新建。公钥没变就留着正在用的连接。
        let id = invitation.macID.uuidString
        if existing?.publicKey != invitation.macKey, let stale = clients.removeValue(forKey: id) {
            stale.disconnect()
        }
        if !isActivated { activate() }
        refreshPaired()
        startRelayPolling()
        return macs.first { $0.deviceID == invitation.macID }
    }

    /// 本机信任表里记的这台 Mac（设备组替别的组员开通时取它的名字、机型、单独记的中继）。
    func pairedPeer(id: UUID) -> RemotePeer? {
        identity.peer(id: id)
    }

    /// 别的组员替本机开通了一台 Mac（设备组，`RemoteGroupHostAccess`，G2 接上）：记进信任表。
    /// 本机记着的公钥不一样就不覆盖；本机忘记过（拉黑）的不加回来——那是在这台设备上做的决定。
    /// 不替用户打开局域网浏览（iOS 上会弹本地网络授权框），等用户自己进主机页。
    func adopt(_ grant: RemoteGroupGrant) -> RemoteGroupAdoption {
        if var existing = identity.peer(id: grant.hostID) {
            guard existing.publicKey == grant.hostKey else { return .conflict }
            // 早就配对过：本机还没有这台的中继时补上（凭担保开通后 Mac 发的证书）。
            if existing.relay == nil, let relay = grant.relay,
               RemoteRelayPlacement.place(relay, current: defaultRelayConfig(), adoptsAsDefault: false) == .perHost {
                existing.relay = relay
                try? identity.trust(existing)
                rebuild()
                startRelayPolling()
            }
            return .alreadyKnown
        }
        guard !identity.isBlocked(grant.hostID) else { return .forgotten }
        var peer = RemotePeer(id: grant.hostID, name: grant.hostName, publicKey: grant.hostKey, pairedAt: Date(),
                              model: grant.hostModel, platform: grant.hostPlatform ?? RemoteDevicePlatform.mac.rawValue)
        if let relay = grant.relay {
            switch RemoteRelayPlacement.place(relay, current: defaultRelayConfig(), adoptsAsDefault: adoptsRelayAsDefault) {
            case .setDefault: importRelayConfig(relay)
            case .perHost: peer.relay = relay
            case .keep: break
            }
        }
        guard (try? identity.trust(peer)) != nil else { return .conflict }
        AppLogger.notice("我的设备：收下「\(grant.hostName)」", category: RemoteLog.category)
        refreshPaired()
        startRelayPolling()
        return .added
    }

    /// 设备组回滚（G3，`RemoteGroupHostAccess.dropAdoptedHost`）：拿掉一台只因为后来被移除的组员开通才记下的 Mac。
    /// 和「忘记」不同：不拉黑（以后别的组员再开通还能记回来），也就不在 `adopt` 里算作 `forgotten`。
    /// 断开它的连接、清掉给它共享的文件夹（它可能是被偷的组员冒充的 Mac）。
    func dropAdoptedHost(_ id: UUID, publicKey: Data, pairedAt: Date) -> Bool {
        guard let peer = identity.peer(id: id),
              RemoteGroupTrustedHost(publicKey: peer.publicKey, pairedAt: peer.pairedAt).matches(publicKey: publicKey,
                                                                                                  pairedAt: pairedAt)
        else { return false }
        guard (try? identity.revoke(id: id, blocks: false)) != nil else { return false }
        let macID = macs.first { $0.deviceID == id }?.id ?? id.uuidString
        clients.removeValue(forKey: macID)?.disconnect()
        onForget?(macID)
        AppLogger.notice("我的设备：拿掉「\(peer.displayName)」（只凭被移除的组员开通的结果记下的）", category: RemoteLog.category)
        refreshPaired()
        return true
    }

    /// 按 `Mac.id` 找：配对过的，或附近还没配对的（不在本机 iCloud 账户里的也算：从「配对其他 Mac」点进来的）。
    func mac(id: String) -> Mac? {
        macs.first { $0.id == id } ?? nearbyMacs.first { $0.id == id } ?? otherNearbyMacs.first { $0.id == id }
    }

    /// 配对过、此刻在局域网里能找到的 Mac。新建终端抽屉只列它们。
    var pairedMacs: [Mac] {
        refreshRelayHostsIfStale()
        return macs.filter(\.isOnline)
    }

    /// 重新读本机信任（配对 / 忘记之后、回到前台时）。
    func refreshPaired() {
        rebuild()
    }

    private func rebuild() {
        let trusted = identity.trustedPeers()
        let defaultRelay = defaultRelayConfig()?.memberIdentity
        // 每台 Mac 只看它自己那台中继上在不在。
        let onRelay = Set(trusted.filter { peer in
            (peer.relay?.memberIdentity ?? defaultRelay).flatMap { relayHosts[$0] }?.contains(peer.id) ?? false
        }.map(\.id))
        macs = debugMacs + Self.knownMacs(trusted: trusted, online: online, relayHosts: onRelay)
        let unpaired = Self.nearbyMacs(online: online, paired: Set(trusted.map(\.id)), localID: RemoteLocalDevice.id())
        let nearby = Self.splitByAccount(unpaired, account: accountDevices)
        // 没变就不写：名册每隔几秒重读一次，别让没变的列表也触发界面刷新。
        if nearby.mine != nearbyMacs { nearbyMacs = nearby.mine }
        if nearby.others != otherNearbyMacs { otherNearbyMacs = nearby.others }
        // 局域网和中继的情况变了，已有的客户端下次重连时按新路走。局域网又找到它、中继报它上线时，
        // 客户端会叫醒正在退避的标签马上重试（Mac 长时间离线后没人看的标签退避可达一分钟）。
        for mac in macs + nearbyMacs + otherNearbyMacs {
            guard let client = clients[mac.id] else { continue }
            updateRoutes(client, for: mac)
            client.relayPresenceChanged(mac.isOnRelay)
        }
        scheduleAccountRecheck()
        #if DEBUG && os(iOS)
        runDebugMatrixIfRequested()
        #endif
    }

    // 只在 iOS：这个启动参数是给真机 `devicectl --console` 跑的，Mac 上用「网络诊断」窗口。
    #if DEBUG && os(iOS)
    /// 调试：启动参数 `-RemoteDebugPathMatrix <轮数>`，第一台在中继上的 Mac 一出现就自动跑链路矩阵，
    /// 结果打到标准输出（`devicectl device process launch --console` 收得到）并存进诊断记录。
    /// 配合 `-remote.internetOnly YES` 插着线也测得到公网路径（链路本地与 ULA 地址不参与打洞）。
    private static let debugMatrixKey = DefaultsKey.remoteDebugPathMatrix
    @ObservationIgnored private var debugMatrixStarted = false

    private func runDebugMatrixIfRequested() {
        let rounds = defaults.integer(forKey: Self.debugMatrixKey)
        guard rounds > 0, !debugMatrixStarted, let mac = macs.first(where: \.isOnline),
              let probe = pathMatrixRunner(for: mac) else { return }
        debugMatrixStarted = true
        let defaults = self.defaults
        Task {
            let network = await RemoteNetworkLabel.current()
            print("[链路矩阵] 开始：\(mac.name)，\(rounds) 轮，\(network)")
            var results = await probe.runner.run(mac: probe.peer, rounds: rounds) { result in
                print("[链路矩阵] \(result.summaryLine)")
            }
            for index in results.indices { results[index].network = network }
            for summary in RemotePathProbeSummary.summarize(results) {
                print("[链路矩阵·汇总] \(summary.line)")
            }
            RemotePathMatrixLog(defaults: defaults).append(results)
            print("[链路矩阵] 结束")
        }
    }
    #endif

    /// 配对过的 Mac：本机信任的。名字在线时取 Bonjour 的电脑名（改过名也跟得上），否则取记下的。
    nonisolated static func knownMacs(trusted: [RemotePeer], online: [UUID: (name: String, endpoint: NWEndpoint)],
                                      relayHosts: Set<UUID> = []) -> [Mac] {
        var byID: [UUID: Mac] = [:]
        for peer in trusted where byID[peer.id] == nil {
            byID[peer.id] = Mac(id: peer.id.uuidString, deviceID: peer.id, name: peer.name, publicKey: peer.publicKey,
                                source: .paired, relay: peer.relay)
        }
        for (id, seen) in online where byID[id] != nil {
            byID[id]?.endpoint = seen.endpoint
            byID[id]?.name = seen.name
        }
        for id in relayHosts where byID[id] != nil {
            byID[id]?.isOnRelay = true
        }
        return byID.values.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 局域网里在线、没配对过的 Mac（按名字排）。本机自己不算：Mac 当主控时 Bonjour 也看得到自己。
    nonisolated static func nearbyMacs(online: [UUID: (name: String, endpoint: NWEndpoint)], paired: Set<UUID>,
                                       localID: UUID) -> [Mac] {
        online.compactMap { id, seen -> Mac? in
            guard id != localID, !paired.contains(id) else { return nil }
            return Mac(id: id.uuidString, deviceID: id, name: seen.name, publicKey: nil, source: .nearby,
                       endpoint: seen.endpoint)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 没配对的在线 Mac 按账户分开：登记在本机 iCloud 账户里的（自动列出），和其余的（只在「配对其他 Mac」里）。
    nonisolated static func splitByAccount(_ unpaired: [Mac], account: Set<UUID>) -> (mine: [Mac], others: [Mac]) {
        var mine: [Mac] = [], others: [Mac] = []
        for mac in unpaired {
            if let id = mac.deviceID, account.contains(id) { mine.append(mac) } else { others.append(mac) }
        }
        return (mine, others)
    }

    /// 忘记一台 Mac：本机不再信任，再连要重新配对。
    func forget(_ mac: Mac) {
        if let deviceID = mac.deviceID { try? identity.revoke(id: deviceID) }
        clients.removeValue(forKey: mac.id)?.disconnect()
        onForget?(mac.id)
        refreshPaired()
    }
}
