import CryptoKit
import Foundation
import ServiceManagement

/// App 侧到远控进程的桥：注册 LaunchAgent、连 XPC、把身份 / 设置 / 会话交过去，接远控进程转来的终端接入与请求，
/// 把它报来的状态照进 App 里的 `RemoteHostServer`（设置页、横幅、命令行照旧读那个对象）。
///
/// 什么时候不用远控进程（远控服务留在 App 里，行为与以前相同）：测试宿主、没装在 `/Applications` 或 `~/Applications` 的构建
///（开发构建与正式版同 bundle id，注册同一个 launchd 任务会顶掉正式版的）、包里没有远控进程、用户在系统设置里关了它的
/// 后台运行、或排查问题时设了 `DefaultsKey.remoteHostAgentDisabled`。
@MainActor
final class RemoteHostAgentBridge: NSObject, RemoteHostAgentLink {
    /// 怎么连到远控进程。正式版连 launchd 的 mach 服务；测试里连同一进程里的匿名监听器。
    struct Transport {
        var makeConnection: @MainActor () -> NSXPCConnection
        /// 只认同团队签名的远控进程（测试里不设）。
        var serverRequirement: String?
    }

    private let server: RemoteHostServer
    private let sessions: RemoteRegistrySessions
    private let settings: RemoteControlSettings
    private let transport: Transport
    private let appBuild: String
    private var connection: NSXPCConnection?
    private var agent: (any RemoteHostAgentXPC)?
    private var attachments: [String: AppSideAttachment] = [:]
    private var restored = false
    private var sessionsPushScheduled = false
    private var reconnect: Task<Void, Never>?
    private var reconnectDelay: Duration = .milliseconds(250)
    /// 远控进程版本和 App 不同，等它空下来（没有设备连着）就换掉。
    private var pendingUpgrade = false
    private var upgradeCheck: Task<Void, Never>?
    private(set) var isConnected = false
    private var isStopped = false
    /// 正在用的桥（App 进程里至多一个；没用远控进程时为 nil）。
    static var current: RemoteHostAgentBridge?
    /// 连上远控进程并握过手（测试用）。
    var onConnected: (@MainActor (RemoteHostAgentInfo) -> Void)?

    init(server: RemoteHostServer, registry: TerminalSessionRegistry, settings: RemoteControlSettings,
         restoration: (@MainActor () async -> Void)?, transport: Transport,
         appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") {
        self.server = server
        sessions = RemoteRegistrySessions(registry: registry, restoration: restoration)
        self.settings = settings
        self.transport = transport
        self.appBuild = appBuild
        super.init()
    }

    // MARK: - 何时启用

    /// 这个构建要不要用远控进程。
    static func isEligible(bundle: Bundle = .main, defaults: UserDefaults = RemoteLocalState.defaults) -> Bool {
        guard !BackgroundLaunchMode.isRunningInTestHost, AppInstallLocation.isCurrentInstalled,
              !defaults.bool(forKey: DefaultsKey.remoteHostAgentDisabled) else { return false }
        return FileManager.default.fileExists(atPath: plistURL(bundle: bundle).path)
    }

    static func plistURL(bundle: Bundle) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(RemoteHostAgent.plistName)")
    }

    /// 注册 LaunchAgent。plist 和上次注册时不同就先注销再注册（launchd 在注册时缓存任务定义，不注销的话新包里改的
    /// 设置不生效）。用户在系统设置里关掉了后台运行时回 false，远控服务留在 App 里。
    static func register(bundle: Bundle = .main, defaults: UserDefaults = RemoteLocalState.defaults) -> Bool {
        let service = SMAppService.agent(plistName: RemoteHostAgent.plistName)
        let digest = (try? Data(contentsOf: plistURL(bundle: bundle))).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        if service.status == .enabled, let digest, defaults.string(forKey: DefaultsKey.remoteHostAgentPlistDigest) != digest {
            try? service.unregister()
        }
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                AppLogger.info("远控进程注册失败（\(service.status.rawValue)）：\(error.localizedDescription)",
                               category: RemoteLog.category)
            }
        }
        guard service.status == .enabled else {
            AppLogger.notice("远控进程不可用（状态 \(service.status.rawValue)），远控服务留在 App 里", category: RemoteLog.category)
            return false
        }
        defaults.set(digest, forKey: DefaultsKey.remoteHostAgentPlistDigest)
        return true
    }

    static let production = Transport(makeConnection: {
        NSXPCConnection(machServiceName: RemoteHostAgent.machServiceName, options: [])
    }, serverRequirement: RemoteHostAgent.agentRequirement)

    // MARK: - 起停

    func start() {
        isStopped = false
        server.agent = self
        sessions.observe(RemoteHostSessionObserver(
            sessionsChanged: { [weak self] _ in self?.scheduleSessionsPush() },
            titlesChanged: { [weak self] in self?.scheduleSessionsPush(delay: RemoteConstants.tabTitlePushInterval) },
            programStatusChanged: { [weak self] in self?.scheduleSessionsPush() },
            orderChanged: { [weak self] in self?.scheduleSessionsPush() }))
        connect()
        Task { [weak self] in
            await self?.sessions.waitUntilRestored()
            guard let self else { return }
            self.restored = true
            self.pushSessions()
        }
    }

    /// 远控设置变了（App 里 `RemoteControlSettings.observe` 的回调转到这里）。
    func settingsChanged() {
        agent?.configure(RemoteHostAgentJSON.encode(settings.agentSnapshot))
        if !settings.isEnabled { scheduleUpgradeCheck() }
    }

    /// 测试用：像 App 被结束那样断开（不告诉远控进程原因、不再重连）。
    func simulateAppTermination() {
        isStopped = true
        reconnect?.cancel()
        connection?.invalidate()
    }

    /// App 要退出了：告诉远控进程原因（更新时宽限期取长的、用户退出时远控随之结束），等它回话再走。
    func depart(_ reason: RemoteHostAgentDeparture) {
        isStopped = true
        reconnect?.cancel()
        guard let connection else { return }
        // 异步代理 + 信号量：回复在 XPC 的队列上到，主线程等它最多一秒（同步代理在同一进程里会和对端抢主线程）。
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in done.signal() } as? any RemoteHostAgentXPC
        proxy?.depart(reason.rawValue) { done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    // MARK: - 连接

    private func connect() {
        guard !isStopped else { return }
        let connection = transport.makeConnection()
        if let requirement = transport.serverRequirement { connection.setCodeSigningRequirement(requirement) }
        connection.remoteObjectInterface = NSXPCInterface(with: RemoteHostAgentXPC.self)
        connection.exportedInterface = NSXPCInterface(with: RemoteHostAppXPC.self)
        connection.exportedObject = RemoteHostAppEndpoint(bridge: self)
        // 交给 XPC 的闭包都要标 @Sendable：XPC 在自己的队列上调它们，默认继承主线程隔离的话运行时会直接中断。
        let token = ObjectIdentifier(connection)
        connection.invalidationHandler = { @Sendable [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionLost(token) } }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        self.connection = connection
        let agent = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
            AppLogger.info("调远控进程失败：\(error.localizedDescription)", category: RemoteLog.category)
        } as? any RemoteHostAgentXPC
        self.agent = agent
        agent?.hello(RemoteHostAgentJSON.encode(makeHello())) { [weak self] data in
            let info = RemoteHostAgentJSON.decode(RemoteHostAgentInfo.self, from: data)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.helloReplied(info, on: token) } }
        }
    }

    private func helloReplied(_ info: RemoteHostAgentInfo?, on replied: ObjectIdentifier) {
        guard connection.map(ObjectIdentifier.init) == replied, let info else { return }
        isConnected = true
        reconnectDelay = .milliseconds(250)
        AppLogger.notice("远控进程已连上（build \(info.build)，pid \(info.pid)，\(info.authorizedConnections) 台设备连着）",
                         category: RemoteLog.category)
        pendingUpgrade = info.build != appBuild
        if pendingUpgrade { scheduleUpgradeCheck(immediate: info.authorizedConnections == 0) }
        onConnected?(info)
    }

    private func connectionLost(_ lost: ObjectIdentifier) {
        guard connection.map(ObjectIdentifier.init) == lost else { return }
        connection = nil
        agent = nil
        isConnected = false
        for attachment in attachments.values { attachment.detach() }
        attachments.removeAll()
        server.agentDisconnected()
        guard !isStopped else { return }
        // 远控进程没了（被换新版本、崩溃）：launchd 在下一次连接时按需拉起。
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, .seconds(5))
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            self?.connect()
        }
    }

    private func makeHello() -> RemoteHostAgentHello {
        let identity = server.identity
        // 先在 App 这头备好长期密钥：两个进程各自生成就成了两把。
        _ = try? identity.localIdentity()
        _ = try? identity.relayHostKey()
        var secrets: [String: Data] = [:]
        for account in RemoteHostAgentBridge.secretAccounts {
            if let data = identity.rawValue(account: account) { secrets[account] = data }
        }
        let revocations = server.relayRevocations.defaults.dictionary(forKey: DefaultsKey.remoteRelayPendingRevocations)
            .flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
        return RemoteHostAgentHello(appBuild: appBuild, localName: server.localName, localID: server.localID,
                                    secrets: secrets, relayConfig: server.loadRelayConfig().map(RemoteHostAgentJSON.encode),
                                    revocations: revocations, relayRegistrationBlock: server.relayRegistrationBlock?.rawValue,
                                    settings: settings.agentSnapshot, sessions: currentSessions())
    }

    /// 被控端用得到的身份存储账号（`RemoteIdentityStore` 的 `.controllers` 方向）。
    static let secretAccounts = ["identity", "relayHostKey", "trustedPeers", "blockedPeers"]

    // MARK: - 版本替换

    /// 远控进程是旧版本：没有设备连着时请它退出，launchd 随后按包里的新二进制拉起。有设备连着就等它们断开。
    private func scheduleUpgradeCheck(immediate: Bool = false) {
        guard pendingUpgrade, upgradeCheck == nil else { return }
        upgradeCheck = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .seconds(30)) }
            guard let self else { return }
            self.upgradeCheck = nil
            guard self.pendingUpgrade, self.isConnected else { return }
            guard self.server.connectedPeerIDs.isEmpty else {
                self.scheduleUpgradeCheck()
                return
            }
            AppLogger.notice("远控进程不是这一版，换成包里的新版本", category: RemoteLog.category)
            self.pendingUpgrade = false
            self.post(.shutdown)
        }
    }

    // MARK: - RemoteHostAgentLink

    func post(_ command: RemoteHostAgentCommand) {
        agent?.command(RemoteHostAgentJSON.encode(command)) { _ in }
    }

    func send(_ command: RemoteHostAgentCommand) async -> RemoteHostAgentCommandReply? {
        guard let agent else { return nil }
        let payload = RemoteHostAgentJSON.encode(command)
        return await withCheckedContinuation { continuation in
            let once = RemoteOnce(continuation)
            agent.command(payload) { once.resume(RemoteHostAgentJSON.decode(RemoteHostAgentCommandReply.self, from: $0)) }
            // 连接断了 XPC 不会回：断开时 `connectionLost` 之后这里靠超时收尾。
            Task {
                try? await Task.sleep(for: .seconds(130))
                once.resume(nil)
            }
        }
    }

    // MARK: - 会话目录

    private func currentSessions() -> RemoteHostAgentSessions {
        RemoteHostAgentSessions(entries: sessions.orderedSessions(), terminalEngine: sessions.terminalEngine,
                                restored: restored, workspaces: server.localShellOpener.workspaces())
    }

    private func scheduleSessionsPush(delay: Duration = .zero) {
        guard !sessionsPushScheduled else { return }
        sessionsPushScheduled = true
        Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { return }
            self.sessionsPushScheduled = false
            self.pushSessions()
        }
    }

    private func pushSessions() {
        agent?.updateSessions(RemoteHostAgentJSON.encode(currentSessions()))
    }

    // MARK: - 远控进程转来的

    func applyState(_ state: RemoteHostAgentState) {
        server.applyAgentState(state)
        if pendingUpgrade, state.connectedPeerIDs.isEmpty { scheduleUpgradeCheck() }
    }

    func attach(_ id: String, _ request: RemoteHostAgentAttach) {
        guard let agent, attachments[id] == nil else { return }
        let pump = AppSidePump(id: id, agent: agent)
        Task {
            let result = await sessions.attach(RemoteHostAttachRequest(
                sessionID: request.sessionID, cols: request.cols, rows: request.rows, controller: request.controller,
                settleTimeout: request.settleTimeout, onReadable: { pump.drain() }))
            switch result {
            case .failure(let error):
                agent.terminalAttached(id, error: error.message)
            case .success(let handle):
                guard let current = self.agent, current === agent else {
                    handle.detach()
                    return
                }
                let attachment = AppSideAttachment(handle: handle, pump: pump)
                handle.onRemoteDisconnect = { [weak self] in
                    self?.attachments.removeValue(forKey: id)?.detach()
                    agent.terminalEnded(id, reason: "已在 Mac 上断开")
                }
                attachments[id] = attachment
                agent.terminalAttached(id, error: nil)
                pump.start(feed: handle.feed)
            }
        }
    }

    func credit(_ id: String, bytes: Int) {
        attachments[id]?.pump.grant(bytes)
    }

    func input(_ id: String, data: Data) {
        attachments[id]?.handle.write(data)
    }

    func resize(_ id: String, cols: Int, rows: Int, controller: String) {
        attachments[id]?.handle.resize(cols: cols, rows: rows, controller: controller)
    }

    func detach(_ id: String) {
        attachments.removeValue(forKey: id)?.detach()
    }

    func handle(_ request: RemoteHostAppRequest) async -> RemoteHostAppReply {
        switch request {
        case .openLocalShell(let directory):
            switch await server.localShellOpener.open(directory) {
            case .success(let id): return RemoteHostAppReply(sessionID: id)
            case .failure(let failure): return RemoteHostAppReply(error: failure.message)
            }
        case .localWorkspaces:
            return RemoteHostAppReply(directories: server.localShellOpener.workspaces())
        case .closeSession(let id):
            return await sessions.requestClose(sessionID: id) ? RemoteHostAppReply() : RemoteHostAppReply(error: "没找到")
        case .deliverImage(let id, let data, let format):
            guard let handle = attachments[id]?.handle, let format = TerminalImage.Format(rawValue: format) else {
                return RemoteHostAppReply(error: "这个终端不能接收图片")
            }
            switch await handle.deliverImage(TerminalImage(format: format, data: data)) {
            case .success(let path): return RemoteHostAppReply(path: path)
            case .failure(let error): return RemoteHostAppReply(error: error.message)
            }
        case .persistSecret(let account, let data):
            do {
                try server.identity.saveRaw(data, account: account)
            } catch {
                AppLogger.info("保存远控进程写回的身份失败：\(error.localizedDescription)", category: RemoteLog.category)
                return RemoteHostAppReply(error: error.localizedDescription)
            }
            server.agentPersistedIdentity()
            return RemoteHostAppReply()
        case .persistRelayConfig(let data):
            server.persistRelayConfigFromAgent(data)
            return RemoteHostAppReply()
        case .grantInternetAccess(let id):
            server.grantInternetAccess(id)
            return RemoteHostAppReply()
        }
    }
}

/// App 侧的一个接入：会话的接管句柄 + 按信用往远控进程送数据的泵。
@MainActor
private final class AppSideAttachment {
    let handle: any RemoteHostTerminalAttachment
    let pump: AppSidePump

    init(handle: any RemoteHostTerminalAttachment, pump: AppSidePump) {
        self.handle = handle
        self.pump = pump
    }

    func detach() {
        pump.stop()
        handle.detach()
    }
}

/// 有信用就取、取了就送；没信用就停，积压留在订阅者那里（超过上限它自己改发快照）。
nonisolated private final class AppSidePump: @unchecked Sendable {
    private let id: String
    private let agent: any RemoteHostAgentXPC
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.agent-pump")
    /// 以下只在 `queue` 上读写。
    private var feed: (any RemoteTerminalFeed)?
    private var credit = RemoteHostAgent.terminalCreditWindow
    private var stopped = false

    init(id: String, agent: any RemoteHostAgentXPC) {
        self.id = id
        self.agent = agent
    }

    func start(feed: any RemoteTerminalFeed) {
        queue.async {
            self.feed = feed
            self.drainOnQueue()
        }
    }

    func drain() {
        queue.async { self.drainOnQueue() }
    }

    func grant(_ bytes: Int) {
        queue.async {
            self.credit += bytes
            self.drainOnQueue()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.feed = nil
        }
    }

    private func drainOnQueue() {
        guard !stopped, let feed else { return }
        while credit > 0, let chunk = feed.take(maxBytes: min(credit, RemoteConstants.maxOutputChunkBytes)) {
            credit -= chunk.byteCount
            let data: Data
            switch chunk {
            case .output(let bytes), .snapshot(let bytes, _, _): data = bytes
            }
            agent.terminalChunk(id, kind: RemoteHostTerminalChunkKind(chunk).rawValue, data: data)
        }
    }
}

/// XPC 导出对象：远控进程调 App 的入口，跳回主线程交给桥。
nonisolated private final class RemoteHostAppEndpoint: NSObject, RemoteHostAppXPC, @unchecked Sendable {
    private weak var bridge: RemoteHostAgentBridge?

    init(bridge: RemoteHostAgentBridge) {
        self.bridge = bridge
    }

    private func onMain(_ body: @escaping @MainActor (RemoteHostAgentBridge) -> Void) {
        DispatchQueue.main.async { [weak bridge] in
            MainActor.assumeIsolated { if let bridge { body(bridge) } }
        }
    }

    func state(_ payload: Data) {
        guard let state = RemoteHostAgentJSON.decode(RemoteHostAgentState.self, from: payload) else { return }
        onMain { $0.applyState(state) }
    }

    func terminalAttach(_ attachment: String, request: Data) {
        guard let request = RemoteHostAgentJSON.decode(RemoteHostAgentAttach.self, from: request) else { return }
        onMain { $0.attach(attachment, request) }
    }

    func terminalCredit(_ attachment: String, bytes: Int) {
        onMain { $0.credit(attachment, bytes: bytes) }
    }

    func terminalInput(_ attachment: String, data: Data) {
        onMain { $0.input(attachment, data: data) }
    }

    func terminalResize(_ attachment: String, cols: Int, rows: Int, controller: String) {
        onMain { $0.resize(attachment, cols: cols, rows: rows, controller: controller) }
    }

    func terminalDetach(_ attachment: String) {
        onMain { $0.detach(attachment) }
    }

    func request(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = RemoteHostAgentJSON.decode(RemoteHostAppRequest.self, from: payload) else {
            reply(RemoteHostAgentJSON.encode(RemoteHostAppReply(error: "App 不认得这个请求")))
            return
        }
        onMain { bridge in
            Task { reply(RemoteHostAgentJSON.encode(await bridge.handle(request))) }
        }
    }
}
