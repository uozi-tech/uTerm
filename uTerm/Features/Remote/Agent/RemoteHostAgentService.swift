import Foundation
import Observation

/// 远控进程里的总管：接 App 的 XPC 连接，第一次 `hello` 时建起 `RemoteHostServer`（和 App 里那份是同一套代码，
/// 只是会话、秘密、设置都经 App 转来），之后把服务端的状态推回 App。
///
/// App 走了（连接失效）就进入宽限期：已建立的远控连接照常服务，终端暂停；宽限期内 App 回来就续上，到期就停止服务、
/// 退出进程（launchd 在 App 下一次连接时再拉起，那时也就换成了包里的新版本）。App 回来时版本变了（更新）也立即退出：
/// 换过包的旧进程既过不了 App 的签名核对，也过不了屏幕录制的授权核对。
@MainActor
final class RemoteHostAgentService: NSObject, NSXPCListenerDelegate {
    /// 构造远控进程里那些和系统打交道的部件。测试里换成合成的。
    struct Environment {
        var settingsDefaults: UserDefaults
        var makeDesktopEnvironment: @MainActor (RemoteControlSettings) -> RemoteDesktopEnvironment
        var makeFileAccess: @MainActor (RemoteControlSettings) -> RemoteFileAccess
        /// 在本进程里显示配对审批框与被控指示条（正式版）。测试里不显示。
        var attachPanels: @MainActor (RemoteHostServer) -> Void
        /// 只接受同团队签名的 App（测试里的匿名连接不设）。
        var clientRequirement: String?
        /// 退出进程。测试里只记一笔。
        var terminate: @MainActor () -> Void
        /// 局域网里广播 Bonjour（测试里不广播，主控端直接连端口）。
        var advertises = true
        var defaultGrace: Duration = RemoteHostAgent.defaultGrace
        var updateGrace: Duration = RemoteHostAgent.updateGrace
        var requestTimeout: Duration = RemoteHostAgent.appRequestWait
        var build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        /// 本进程的屏幕录制 / 辅助功能授权（`desktopPermissions`）。
        var desktopPermissions: @MainActor () async -> RemoteHostAgentPermissions = {
            async let screen = RemoteDesktopPermissions.screenCaptureGranted()
            async let post = RemoteDesktopPermissions.postEventsGranted()
            return await RemoteHostAgentPermissions(screenCapture: screen, postEvents: post)
        }
        /// 以本进程的身份申请「辅助功能」（`requestPostEvents`）。
        var requestPostEvents: @MainActor () async -> Void = { await RemoteDesktopPermissions.requestPostEvents() }
    }

    private let environment: Environment
    let sessions: RemoteForwardedSessions
    private(set) var server: RemoteHostServer?
    private var settings: RemoteControlSettings?
    private let secrets = RemoteMirroredSecretStorage()
    private let relayStorage = RemoteMirroredSyncedStorage()
    private var connection: NSXPCConnection?
    private var app: (any RemoteHostAppXPC)?
    /// App 不在时写下、还没交给 App 落盘的请求（按先后）。
    private var pendingWrites: [RemoteHostAppRequest] = []
    private var pendingSecretAccounts: Set<String> = []
    private var grace: Task<Void, Never>?
    private var departure: RemoteHostAgentDeparture?
    private var statePushScheduled = false
    private var lastState: RemoteHostAgentState?
    private var localWorkspaces: [String] = []
    private(set) var isShutDown = false
    private nonisolated let clientRequirement: String?
    private nonisolated let endpoint = RemoteHostAgentEndpoint()

    init(environment: Environment) {
        self.environment = environment
        clientRequirement = environment.clientRequirement
        sessions = RemoteForwardedSessions(requestTimeout: environment.requestTimeout)
        super.init()
        endpoint.service = self
        secrets.onSave = { [weak self] account, data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.persist(.persistSecret(account: account, data: data), secretAccount: account) }
            }
        }
        relayStorage.onChange = { [weak self] data in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.persist(.persistRelayConfig(data)) } }
        }
        // launchd 在崩溃后会把远控进程拉起来，但 App 未必还在：等不到 App 就自己退出，下次连接时再按需启动。
        let idle = environment.defaultGrace
        grace = Task { [weak self] in
            guard (try? await Task.sleep(for: idle)) != nil else { return }
            guard let self, self.server == nil else { return }
            self.shutdown(reason: "没有等到 App")
        }
    }

    // MARK: - XPC

    /// 在 XPC 的队列上调：在这里把连接配好、恢复，再跳回主线程接手（排在这条连接的第一条消息之前）。
    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let clientRequirement { connection.setCodeSigningRequirement(clientRequirement) }
        connection.exportedInterface = NSXPCInterface(with: RemoteHostAgentXPC.self)
        connection.exportedObject = endpoint
        connection.remoteObjectInterface = NSXPCInterface(with: RemoteHostAppXPC.self)
        let token = ObjectIdentifier(connection)
        connection.invalidationHandler = { @Sendable [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionEnded(token) } }
        }
        connection.interruptionHandler = connection.invalidationHandler
        nonisolated(unsafe) let adopted = connection
        DispatchQueue.main.async { MainActor.assumeIsolated { self.adopt(adopted) } }
        connection.resume()
        return true
    }

    private func adopt(_ connection: NSXPCConnection) {
        guard !isShutDown else {
            connection.invalidate()
            return
        }
        // 新连接顶替旧的：同一时刻只服务一个 App。
        if let old = self.connection, old !== connection {
            self.connection = nil
            old.invalidate()
        }
        self.connection = connection
    }

    private func connectionEnded(_ ended: ObjectIdentifier) {
        guard connection.map(ObjectIdentifier.init) == ended else { return }
        connection = nil
        app = nil
        sessions.appDisconnected()
        guard !isShutDown else { return }
        if departure == .quit {
            shutdown(reason: "Mac 上的 uTerm 已退出")
            return
        }
        let wait = departure == .update ? environment.updateGrace : environment.defaultGrace
        AppLogger.notice("远控进程：App 不在了，远控连接再保持 \(Int(wait.components.seconds)) 秒", category: RemoteLog.category)
        grace?.cancel()
        grace = Task { [weak self] in
            guard (try? await Task.sleep(for: wait)) != nil else { return }
            self?.shutdown(reason: "Mac 上的 uTerm 没有回来")
        }
    }

    // MARK: - App 发来的

    func hello(_ hello: RemoteHostAgentHello) -> RemoteHostAgentInfo {
        guard let connection else { return info() }
        let app = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
            AppLogger.info("远控进程：调 App 失败：\(error.localizedDescription)", category: RemoteLog.category)
        } as? any RemoteHostAppXPC
        self.app = app
        // App 换了版本（Sparkle 更新）：本进程的可执行文件已被新包替换，App 按签名核对本进程会失败（-67065），
        // tccd 也不再认本进程的屏幕录制授权。留着只会让 App 一直重连、手机开不了屏幕：交出没写回的数据，退出，
        // launchd 在 App 下一次连接时按包里的新版本拉起。连着的设备会断开重连。
        guard hello.appBuild == environment.build else {
            flushPendingWrites()
            shutdown(reason: "App 已是 build \(hello.appBuild)，本进程是 build \(environment.build)")
            return info()
        }
        grace?.cancel()
        grace = nil
        departure = nil
        secrets.replaceAll(hello.secrets, keeping: pendingSecretAccounts)
        if !pendingWrites.contains(where: { if case .persistRelayConfig = $0 { true } else { false } }) {
            relayStorage.replace(hello.relayConfig)
        }
        if server == nil { buildServer(hello) } else { mergeRevocations(hello.revocations) }
        if let app { sessions.appConnected(app) }
        applySettings(hello.settings)
        apply(hello.sessions)
        flushPendingWrites()
        scheduleStatePush(force: true)
        AppLogger.notice("远控进程：App（build \(hello.appBuild)）已连上", category: RemoteLog.category)
        return info()
    }

    func info() -> RemoteHostAgentInfo {
        RemoteHostAgentInfo(protocolVersion: RemoteHostAgent.protocolVersion, build: environment.build,
                            pid: ProcessInfo.processInfo.processIdentifier,
                            authorizedConnections: server?.connectedPeerIDs.count ?? 0)
    }

    func applySettings(_ snapshot: RemoteHostAgentSettings) {
        settings?.apply(snapshot)
    }

    func apply(_ update: RemoteHostAgentSessions) {
        if let workspaces = update.workspaces { localWorkspaces = workspaces }
        sessions.apply(update)
    }

    func depart(_ reason: RemoteHostAgentDeparture) {
        departure = reason
    }

    func perform(_ command: RemoteHostAgentCommand) async -> RemoteHostAgentCommandReply {
        // 授权与服务端无关：远控进程刚起、还没建服务端时也照答（App 据「回不了话」判断远控进程是旧版本）。
        switch command {
        case .desktopPermissions:
            return RemoteHostAgentCommandReply(data: RemoteHostAgentJSON.encode(await environment.desktopPermissions()))
        case .requestPostEvents:
            await environment.requestPostEvents()
            return RemoteHostAgentCommandReply(data: RemoteHostAgentJSON.encode(await environment.desktopPermissions()))
        default:
            break
        }
        guard let server else { return RemoteHostAgentCommandReply(ok: false, error: "远控进程还没准备好") }
        switch command {
        case .approvePairing(let id): server.approvePairing(id)
        case .rejectPairing(let id): server.rejectPairing(id)
        case .makePairingInvitation:
            do {
                let invitation = try server.makePairingInvitation()
                scheduleStatePush()
                return RemoteHostAgentCommandReply(data: Data(invitation.url.absoluteString.utf8))
            } catch {
                return RemoteHostAgentCommandReply(ok: false, error: error.localizedDescription)
            }
        case .cancelPairingInvitation: server.cancelPairingInvitation()
        case .rename(let id, let name):
            do { try server.rename(id, to: name) } catch {
                return RemoteHostAgentCommandReply(ok: false, error: error.localizedDescription)
            }
        case .revoke(let id): server.revoke(id)
        case .relayConfigChanged(let data):
            if let data, let config = RemoteHostAgentJSON.decode(RemoteRelayConfig.self, from: data) {
                server.importRelayConfig(config)
            } else {
                server.clearRelayConfig()
            }
            if let settings {
                server.updateInternetAccess(enabled: settings.isEnabled && settings.isInternetEnabled,
                                            keepAwake: settings.keepsAwakeForInternet)
            }
        case .reconnectRelay: server.reconnectRelay()
        case .endDesktop(let reason): server.endDesktop(reason: reason)
        case .endDesktopAudio(let reason): server.endDesktopAudio(reason: reason)
        case .desktopSettingsChanged: server.desktopSettingsChanged()
        case .performFile(let device, let payload, let requestID, let timeout):
            // 失败时 `data` 是 `RemoteFileError` 的 JSON：App 那头照原样抛出，命令行的重试规则（超时、断开才重试）不变。
            guard let connection = server.fileConnection(toDevice: device) else {
                return RemoteHostAgentCommandReply(ok: false, data: RemoteHostAgentJSON.encode(
                    RemoteFileError(.unreachable, "那台设备已经不连着这台 Mac 了")))
            }
            do {
                let raw = try await connection.exchangeFile(payload, id: requestID, timeout: .milliseconds(timeout))
                return RemoteHostAgentCommandReply(data: raw)
            } catch {
                let failure = error as? RemoteFileError ?? RemoteFileError(.unreachable, error.localizedDescription)
                return RemoteHostAgentCommandReply(ok: false, data: RemoteHostAgentJSON.encode(failure))
            }
        case .shutdown:
            Task { self.shutdown(reason: "远控组件正在更新") }
        case .desktopPermissions, .requestPostEvents:
            break  // 上面已经处理
        }
        scheduleStatePush()
        return RemoteHostAgentCommandReply()
    }

    // MARK: - 服务端

    private func buildServer(_ hello: RemoteHostAgentHello) {
        let settings = RemoteControlSettings(defaults: environment.settingsDefaults)
        settings.apply(hello.settings)
        self.settings = settings
        let revocations = RemoteRelayRevocations(defaults: environment.settingsDefaults)
        self.revocations = revocations
        mergeRevocations(hello.revocations)
        let monitor = RemoteRelayUpdateMonitor(defaults: environment.settingsDefaults,
                                               fetchLatest: { throw CancellationError() }, notify: { _, _ in })
        let server = RemoteHostServer(
            sessions: sessions,
            identity: RemoteIdentityStore(role: .controllers, storage: secrets),
            localName: hello.localName, localID: hello.localID, advertises: environment.advertises,
            relayStore: RemoteRelayConfigStore(storage: relayStorage), relayUpdates: monitor,
            relayRevocations: revocations,
            desktopEnvironment: environment.makeDesktopEnvironment(settings),
            relayRegistrationBlock: hello.relayRegistrationBlock.flatMap(RemoteRelayRegistrationBlock.init(rawValue:)))
        server.internetAccessPolicy = { [weak settings] in settings?.allowsInternetAccess($0) ?? false }
        server.vouchPolicy = { [weak settings] in settings?.isDeviceVouchingEnabled ?? false }
        server.grantInternetAccess = { [weak self, weak settings] id in
            settings?.internetDevices.insert(id)
            self?.persist(.grantInternetAccess(id))
        }
        server.localShellOpener = RemoteLocalShellOpener(workspaces: { [weak self] in
            self?.localWorkspaces ?? []
        }, open: { [weak self] directory in
            guard let self else { return .failure(.init(message: "远控进程正在退出")) }
            guard let reply = await self.sessions.request(.openLocalShell(directory: directory)) else {
                return .failure(.init(message: RemoteHostAttachError.appUnavailable.message))
            }
            if let id = reply.sessionID { return .success(id) }
            return .failure(.init(message: reply.error ?? "本机终端没开成"))
        })
        server.fileAccess = environment.makeFileAccess(settings)
        server.onStateChange = { [weak self] in self?.scheduleStatePush() }
        self.server = server
        environment.attachPanels(server)
        settings.observe { [weak server] settings in
            guard let server else { return }
            if settings.isEnabled { server.start() } else { server.stop() }
            server.updateInternetAccess(enabled: settings.isEnabled && settings.isInternetEnabled,
                                        keepAwake: settings.keepsAwakeForInternet)
            if !settings.isDesktopEnabled { server.endDesktop(reason: "Mac 上关闭了远程桌面") }
            server.desktopSettingsChanged()
            if !settings.isDesktopAudioEnabled { server.endDesktopAudio(reason: "Mac 上关闭了「允许传输声音」") }
        }
        observeServer()
    }

    private var revocations: RemoteRelayRevocations?

    /// App 那份没确认的吊销并进本进程这份（升级到远控进程之前 App 记下的）。
    private func mergeRevocations(_ data: Data?) {
        guard let data, let revocations,
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Int64]]
        else { return }
        for (relayID, members) in table {
            for (member, expires) in members {
                revocations.add(member, relayID: relayID, expires: expires > 0 ? expires : nil)
            }
        }
    }

    /// 停止服务：先锁屏撤帘幕（`stop()` 里），通知对端，然后退出进程。
    func shutdown(reason: String) {
        guard !isShutDown else { return }
        isShutDown = true
        grace?.cancel()
        AppLogger.notice("远控进程：停止服务（\(reason)）", category: RemoteLog.category)
        server?.stop()
        sessions.releaseWaiters()
        connection?.invalidate()
        environment.terminate()
    }

    // MARK: - 写回 App

    private func persist(_ request: RemoteHostAppRequest, secretAccount: String? = nil) {
        if let app {
            app.request(RemoteHostAgentJSON.encode(request)) { _ in }
            return
        }
        pendingWrites.append(request)
        if let secretAccount { pendingSecretAccounts.insert(secretAccount) }
    }

    private func flushPendingWrites() {
        guard let app else { return }
        let writes = pendingWrites
        pendingWrites.removeAll()
        pendingSecretAccounts.removeAll()
        for write in writes { app.request(RemoteHostAgentJSON.encode(write)) { _ in } }
    }

    // MARK: - 状态推送

    private func observeServer() {
        guard let server else { return }
        withObservationTracking {
            _ = server.status
            _ = server.port
            _ = server.connectedDevices
            _ = server.connectedPeerIDs
            _ = server.pairingRequests
            _ = server.pairingInvitation
            _ = server.desktopViewer
            _ = server.relayLink?.state
            _ = server.relayUpdates.runningVersion
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.scheduleStatePush()
                    self?.observeServer()
                }
            }
        }
    }

    private func scheduleStatePush(force: Bool = false) {
        if force { lastState = nil }
        guard !statePushScheduled else { return }
        statePushScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.statePushScheduled = false
                self.pushState()
            }
        }
    }

    private func pushState() {
        guard let server, let app else { return }
        let state = server.agentState()
        guard state != lastState else { return }
        lastState = state
        app.state(RemoteHostAgentJSON.encode(state))
    }
}

/// XPC 导出对象：把调用跳回主线程交给 `RemoteHostAgentService`。
nonisolated private final class RemoteHostAgentEndpoint: NSObject, RemoteHostAgentXPC, @unchecked Sendable {
    /// 建好后只设一次（服务的 init 里）。
    weak var service: RemoteHostAgentService?

    private func onMain(_ body: @escaping @MainActor (RemoteHostAgentService) -> Void) {
        DispatchQueue.main.async { [weak service] in
            MainActor.assumeIsolated { if let service { body(service) } }
        }
    }

    func hello(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let hello = RemoteHostAgentJSON.decode(RemoteHostAgentHello.self, from: payload) else {
            reply(Data())
            return
        }
        onMain { reply(RemoteHostAgentJSON.encode($0.hello(hello))) }
    }

    func configure(_ payload: Data) {
        guard let settings = RemoteHostAgentJSON.decode(RemoteHostAgentSettings.self, from: payload) else { return }
        onMain { $0.applySettings(settings) }
    }

    func updateSessions(_ payload: Data) {
        guard let update = RemoteHostAgentJSON.decode(RemoteHostAgentSessions.self, from: payload) else { return }
        onMain { $0.apply(update) }
    }

    func terminalAttached(_ attachment: String, error: String?) {
        onMain { $0.sessions.attachResult(attachment, error: error) }
    }

    func terminalChunk(_ attachment: String, kind: Int, data: Data) {
        onMain { $0.sessions.chunk(attachment, kind: kind, data: data) }
    }

    func terminalEnded(_ attachment: String, reason: String) {
        onMain { $0.sessions.ended(attachment) }
    }

    func command(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let command = RemoteHostAgentJSON.decode(RemoteHostAgentCommand.self, from: payload) else {
            reply(RemoteHostAgentJSON.encode(RemoteHostAgentCommandReply(ok: false, error: "远控进程不认得这个操作")))
            return
        }
        onMain { service in
            Task { reply(RemoteHostAgentJSON.encode(await service.perform(command))) }
        }
    }

    func depart(_ reason: String, reply: @escaping @Sendable () -> Void) {
        let departure = RemoteHostAgentDeparture(rawValue: reason)
        onMain { service in
            if let departure { service.depart(departure) }
            reply()
        }
    }
}

extension RemoteControlSettings {
    /// 交给远控进程的那份设置。
    var agentSnapshot: RemoteHostAgentSettings {
        RemoteHostAgentSettings(enabled: isEnabled, desktopEnabled: isDesktopEnabled, unlockEnabled: isDesktopUnlockEnabled,
                                audioEnabled: isDesktopAudioEnabled, localShellEnabled: isLocalShellEnabled,
                                internetEnabled: isInternetEnabled, internetDevices: internetDevices.sorted { $0.uuidString < $1.uuidString },
                                keepAwakeForInternet: keepsAwakeForInternet, deviceVouching: isDeviceVouchingEnabled)
    }

    /// 远控进程里：换成 App 报来的那份（只改变了的项，每改一项回调一次起停逻辑，与 App 里一致）。
    func apply(_ snapshot: RemoteHostAgentSettings) {
        if isEnabled != snapshot.enabled { isEnabled = snapshot.enabled }
        if isDesktopEnabled != snapshot.desktopEnabled { isDesktopEnabled = snapshot.desktopEnabled }
        if isDesktopUnlockEnabled != snapshot.unlockEnabled { isDesktopUnlockEnabled = snapshot.unlockEnabled }
        if isDesktopAudioEnabled != snapshot.audioEnabled { isDesktopAudioEnabled = snapshot.audioEnabled }
        if isLocalShellEnabled != snapshot.localShellEnabled { isLocalShellEnabled = snapshot.localShellEnabled }
        if isInternetEnabled != snapshot.internetEnabled { isInternetEnabled = snapshot.internetEnabled }
        let devices = Set(snapshot.internetDevices)
        if internetDevices != devices { internetDevices = devices }
        if keepsAwakeForInternet != snapshot.keepAwakeForInternet { keepsAwakeForInternet = snapshot.keepAwakeForInternet }
        let vouching = snapshot.deviceVouching ?? true
        if isDeviceVouchingEnabled != vouching { isDeviceVouchingEnabled = vouching }
    }
}
