import CoreGraphics
import CryptoKit
import Foundation

/// Mac 端一台已连上的远控设备：握手、配对审批、会话列表、接入 / 断开、输入、尺寸。
///
/// 收到的消息从连接队列按先后顺序跳回主线程处理（`DispatchQueue.main` 是先进先出的，按键顺序
/// 不会乱）。输出则反过来：镜像订阅者有新字节时，在连接队列上直接取、合并、加密、发送，
/// 不经过主线程。桌面流的确认、输入、关键帧请求也不经主线程，在连接队列上直接交给发送端
///（见 `RemoteDesktopRoute`）；只有开流 / 停流这种低频控制回主线程。
@MainActor
final class RemoteHostConnection {
    let id = UUID()
    private let link: RemoteLink
    private unowned let server: RemoteHostServer
    private let pump: RemoteOutputPump
    private let desktopRoute: RemoteDesktopRoute
    /// 当前的桌面流（同一连接最多一路）。
    private var desktop: (channel: UInt32, streamer: RemoteDesktopStreamer)?

    /// 对端设备名与 ID（握手后才有）。
    private(set) var peerName = ""
    private(set) var peerID: UUID?

    /// 在 Mac 上给这台设备改了名：正连着的这条立刻换成新名字，不用等它重连。
    func peerRenamed(to name: String) {
        peerName = name
    }
    /// 手机声明了会定时 ping（老手机空闲时不发任何东西，不能按无声断开）。
    private var peerSendsHeartbeat = false
    /// 手机认得 `desktopClipboard`（老手机收到会当未知消息断开整条连接）。
    private var peerTakesClipboard = false
    /// 手机认得远程解锁 / 帘幕相关消息（`desktopScreenState` 等）。
    private var peerSupportsUnlock = false
    /// 这条桌面流的锁屏状态监听（当前在看屏幕时才挂）。
    private var lockObservers: [NSObjectProtocol] = []
    /// 这条连接远程解锁过 Mac：远控结束时不管帘幕开没开都要锁回去。
    private var remotelyUnlocked = false
    /// 正在执行解锁（按键序列 + 轮询）：同时来的第二个请求直接拒掉，免得两串按键交错。
    private var unlockInFlight = false
    /// 光标形状的轮询（开流请求要了 `cursorImages` 才挂）与上次发出的形状。
    private var cursorShapeTimer: Timer?
    private var lastCursorSignature: Int?
    /// 从哪条路进来的。公网路径规则更严：不弹审批框，没配对过的只认邀请凭据。
    let origin: RemoteConnectionOrigin
    private var peerSupportsRelayConfig = false
    private var keyConfirmed = false
    private var keyConfirmationWaiter: CheckedContinuation<Bool, Never>?
    private(set) var isAuthorized = false
    private var subscribedToSessions = false
    private var isClosed = false
    private var nextChannel: UInt32 = 1
    /// 每次开流 +1，授权查询回来时用它认出自己是不是最后一次请求（见 `startDesktop`）。
    private var desktopStartGeneration: UInt32 = 0
    private var attachments: [UInt32: Attachment] = [:]

    private struct Attachment {
        let sessionID: UUID
        weak var session: TerminalSession?
        let subscriberID: UUID
    }

    init(link: RemoteLink, server: RemoteHostServer, origin: RemoteConnectionOrigin = .localNetwork) {
        self.link = link
        self.server = server
        self.origin = origin
        self.pump = RemoteOutputPump(link: link)
        self.desktopRoute = RemoteDesktopRoute(queue: link.queue)
        self.pump.onOutputSent = { [weak server] in
            DispatchQueue.main.async { MainActor.assumeIsolated { server?.noteRemoteOutput() } }
        }
    }

    func start() {
        let pump = self.pump
        let desktopRoute = self.desktopRoute
        link.setHandlers(
            onMessage: { [weak self] message in
                if desktopRoute.handle(message) { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(message) } }
            },
            onClose: { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.didClose() } }
            },
            onWritable: { pump.drainOnQueue() }
        )
        // 握手可能跨越很长时间（等审批、等密钥确认），期间要保证 server 还在，`server` 是 unowned。
        Task { [server] in
            await handshake()
            withExtendedLifetime(server) {}
        }
    }

    func close() {
        link.close()
    }

    /// 握手里报给手机的能力。`desktop-unlock` 只表示「这台 Mac 认得解锁消息、会推锁屏状态」，与设置开关无关：
    /// 能力只在握手时交换一次，连接会一直留着，若随开关增减，打开开关后已有连接永远看不到解锁入口。
    /// 开关是否打开随锁屏状态（`unlockAvailable`）实时推送。
    private func advertisedFeatures() -> [String] {
        var features = server.localFeatures
        if server.desktopEnvironment.makeScreenController == nil {
            features.removeAll { $0 == RemoteFeature.desktopUnlock }
        }
        return features
    }

    // MARK: - 握手与配对

    private func handshake() async {
        do {
            let staticKey = try server.identity.localIdentity()
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: server.localID,
                                    deviceName: server.localName, ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                    staticKey: staticKey.publicKey.rawRepresentation,
                                    features: advertisedFeatures().isEmpty ? nil : advertisedFeatures(),
                                    deviceModel: RemoteDeviceModel.current(),
                                    platform: RemoteDevicePlatform.current.rawValue)
            let established = try await link.establish(role: .responder, hello: hello, staticKey: staticKey,
                                                       ephemeralKey: ephemeral, handshakeKeys: origin.handshakeKeys)
            let peer = established.peer
            peerName = peer.deviceName
            peerID = peer.deviceID
            peerSendsHeartbeat = peer.supports(RemoteFeature.heartbeat)
            peerTakesClipboard = peer.supports(RemoteFeature.desktopClipboard)
            peerSupportsUnlock = peer.supports(RemoteFeature.desktopUnlock)
            peerSupportsRelayConfig = peer.supports(RemoteFeature.relayConfig)
            if case .internet(let expected, _, _) = origin {
                try await authorizeFromInternet(peer: peer, expected: expected)
                return
            }
            if server.localFeatures.contains(RemoteFeature.keyConfirmation) {
                // 不能按对方声明的能力决定要不要验：冒充者在握手里不报 key-confirm 就能跳过验证、被记进信任列表。
                // 远控随 2.0 首发，能连上来的手机都带这一能力。
                guard peer.supports(RemoteFeature.keyConfirmation) else {
                    throw RemoteProtocolError.handshakeFailed("对方没有证明自己持有私钥")
                }
                try await waitForKeyConfirmation()
            }
            if server.identity.recognizes(id: peer.deviceID, publicKey: peer.staticKey) {
                try rememberRecognized(peer)
                authorize(.trusted)
                return
            }
            if let proof = peer.pairingProof, let redemption = server.redeemPairingProof(proof, phoneKey: peer.staticKey) {
                try server.trust(newPeer(from: peer, redemption: redemption))
                authorize(.approved)
                return
            }
            // 没见过的设备，或同一台设备换了长期密钥（重装过）：都要 Mac 上的人确认。
            sendPairing(.awaitingApproval)
            let approved = await server.requestApproval(connectionID: id, deviceName: peer.deviceName,
                                                        code: established.verificationCode)
            guard !isClosed else { return }
            guard approved else {
                link.send(RemoteMessage(.pairing, payload: Data([RemotePairingState.rejected.rawValue])),
                          thenClose: RemoteProtocolError.pairingRejected)
                return
            }
            try server.trust(newPeer(from: peer))
            authorize(.approved)
        } catch {
            AppLogger.info("远控握手失败：\(error.localizedDescription)", category: RemoteLog.category)
            link.close(error)
        }
    }

    /// 公网来的连接：只认信令里打过招呼的那台设备，必须能证明持有私钥，且此刻仍被允许；
    /// 或者带着本机正在出示的邀请凭据（凭据绑定它的公钥，一次性），这时配对并替它开通公网接入。
    /// 任何一条不满足就断开。不弹审批框，否则任何拿到中继配置的人都能远程刷弹窗骗点击。
    private func authorizeFromInternet(peer: RemoteHello, expected: UUID) async throws {
        guard peer.deviceID == expected, peer.supports(RemoteFeature.keyConfirmation) else {
            throw RemoteProtocolError.handshakeFailed("公网连接的身份与信令不符")
        }
        try await waitForKeyConfirmation()
        guard !isClosed else { throw RemoteProtocolError.closed }
        if server.identity.recognizes(id: peer.deviceID, publicKey: peer.staticKey),
           server.allowsInternetAccess(peer.deviceID) {
            try rememberRecognized(peer)
            authorize(.trusted)
            return
        }
        guard let proof = peer.pairingProof,
              let redemption = server.redeemPairingProof(proof, phoneKey: peer.staticKey) else {
            throw RemoteProtocolError.pairingRejected
        }
        try server.trust(newPeer(from: peer, redemption: redemption))
        server.grantInternetAccess(peer.deviceID)
        authorize(.approved)
    }

    /// 认出来的设备只跟着更新名字与机型。名字只在配对时记一次的话，手机改了名、或 App 后来拿到了真实设备名，
    /// Mac 上永远是旧的。公钥与配对时间不动。
    private func rememberRecognized(_ peer: RemoteHello) throws {
        guard var known = server.identity.peer(id: peer.deviceID) else { return }
        let reported = known
        let name = peer.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { known.name = name }
        // 老版本不报机型：保留上次记的，别清空。本机起的别名不动。
        if let model = peer.deviceModel { known.model = model }
        if let platform = peer.platform { known.platform = platform }
        guard known != reported else { return }
        try server.trust(known)
    }

    /// 新配上（或重新配对）的设备。之前发给它的中继证书留着；凭邀请配上的换成邀请里那张，旧的吊销。
    private func newPeer(from peer: RemoteHello, redemption: RemoteHostServer.PairingRedemption? = nil) -> RemotePeer {
        var trusted = RemotePeer(id: peer.deviceID, name: peer.deviceName, publicKey: peer.staticKey, pairedAt: Date(),
                                 model: peer.deviceModel, platform: peer.platform)
        let previous = server.identity.peer(id: peer.deviceID)?.relayGrant
        trusted.relayGrant = redemption?.relayGrant ?? previous
        if let previous, previous != trusted.relayGrant { server.revokeRelayGrant(previous) }
        return trusted
    }

    /// 等手机证明它真的持有握手里报的长期私钥。公钥是公开的，只凭握手消息信任会让冒充者被记进信任列表、
    /// 显示成「已连接」（虽然它解不开也发不出任何密文）。
    private func waitForKeyConfirmation() async throws {
        let timeout = server.keyConfirmationTimeout
        let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if keyConfirmed || isClosed {
                continuation.resume(returning: keyConfirmed)
                return
            }
            keyConfirmationWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishKeyConfirmation(false)
            }
        }
        guard confirmed else { throw RemoteProtocolError.timeout }
    }

    private func finishKeyConfirmation(_ confirmed: Bool) {
        keyConfirmed = keyConfirmed || confirmed
        keyConfirmationWaiter?.resume(returning: keyConfirmed)
        keyConfirmationWaiter = nil
    }

    private func authorize(_ state: RemotePairingState) {
        isAuthorized = true
        // 横幅、桌面指示条、设置里的「已连接」都按这个名字显示：在 Mac 上改过名就用改过的。
        if let peerID, let known = server.identity.peer(id: peerID) { peerName = known.displayName }
        sendPairing(state)
        // 公网连接不管对方声明什么都要判死，否则不发东西的连接会一直占着名额。
        if peerSendsHeartbeat || origin.isInternet { link.startSilenceWatch(limit: server.peerSilenceLimit) }
        server.connectionAuthorized(self)
        sendRelayConfigIfAllowed()
    }

    /// 把中继配置交给勾选过公网接入的设备。之后它在外面也连得上。
    func sendRelayConfigIfAllowed() {
        guard isAuthorized, peerSupportsRelayConfig, let peerID, server.allowsInternetAccess(peerID),
              let config = server.relayConfig(forPeer: peerID) else { return }
        link.send(RemoteMessage(.relayConfig, payload: RemoteJSON.encode(config)))
    }

    /// 公网接入被关掉，或这台设备被取消勾选：公网连接立刻断开。
    func enforceInternetPolicy() {
        guard origin.isInternet, let peerID, !server.allowsInternetAccess(peerID) else { return }
        link.close(RemoteProtocolError.pairingRejected)
    }

    private func sendPairing(_ state: RemotePairingState) {
        link.send(RemoteMessage(.pairing, payload: Data([state.rawValue])))
    }

    // MARK: - 消息

    private func handle(_ message: RemoteMessage) {
        if message.kind == .keyConfirm {
            finishKeyConfirmation(true)
            return
        }
        // 审批通过之前，对端说什么都不理。
        guard isAuthorized, !isClosed else { return }
        switch message.kind {
        case .subscribeSessions:
            afterSessionRestoration { [weak self] in
                self?.subscribedToSessions = true
                self?.sendSessions()
            }
        case .attach:
            guard let request = try? RemoteJSON.decode(RemoteAttachRequest.self, from: message.payload) else { return }
            afterSessionRestoration { [weak self] in self?.attach(request) }
        case .input:
            attachments[message.channel]?.session?.writeRemoteInput(message.payload)
            server.noteRemoteInput()
        case .resize:
            guard let attachment = attachments[message.channel],
                  let size = try? RemoteGridSize(decoding: message.payload) else { return }
            attachment.session?.pinRemoteGrid(cols: Int(size.cols), rows: Int(size.rows), controller: peerName)
        case .detach:
            detach(channel: message.channel, notify: false)
        case .ping:
            link.send(RemoteMessage(.pong))
        case .openLocalShell:
            guard let request = try? RemoteJSON.decode(RemoteOpenLocalShellRequest.self, from: message.payload) else { return }
            openLocalShell(request)
        case .listLocalWorkspaces:
            guard let request = try? RemoteJSON.decode(RemoteLocalWorkspacesRequest.self, from: message.payload) else { return }
            let reply = RemoteLocalWorkspaces(requestID: request.requestID, home: LocalShellWorkspaces.home,
                                              directories: server.localShellOpener.workspaces())
            link.send(RemoteMessage(.localWorkspaces, payload: RemoteJSON.encode(reply)))
        case .closeSession:
            guard let request = try? RemoteJSON.decode(RemoteCloseSessionRequest.self, from: message.payload) else { return }
            let closed = server.registry.requestClose(sessionID: request.sessionID)
            AppLogger.info("远控：\(self.peerName) 关闭 Mac 上的会话 \(request.sessionID.uuidString.prefix(8))：\(closed ? "已关闭" : "没找到")",
                           category: RemoteLog.category)
        case .terminalImage:
            guard let request = try? RemoteTerminalImageRequest(decoding: message.payload) else { return }
            deliverImage(request, channel: message.channel)
        case .desktopStart:
            guard let request = try? RemoteJSON.decode(RemoteDesktopStartRequest.self, from: message.payload) else { return }
            Task { await startDesktop(request) }
        case .desktopStop:
            stopDesktop(channel: message.channel, notify: false)
        case .desktopUnlock:
            guard var request = try? RemoteJSON.decode(RemoteDesktopUnlockRequest.self, from: message.payload) else { return }
            let password = request.password
            request.password = ""
            handleUnlock(requestID: request.requestID, password: password, channel: message.channel)
        case .desktopCurtain:
            guard let request = try? RemoteJSON.decode(RemoteDesktopCurtainRequest.self, from: message.payload) else { return }
            setCurtain(request.on, channel: message.channel)
        case .desktopAck, .desktopInput, .desktopKeyframe, .desktopPaste, .desktopPasteChunk, .desktopVideoLost,
             .desktopPause:
            // 已在连接队列上交给发送端（`RemoteDesktopRoute`），不会走到这里。
            break
        case .keyConfirm, .relayConfig, .sessions, .attached, .output, .closed, .pong, .pairing, .desktopStarted, .desktopFrame,
             .desktopCursor, .desktopClipboard, .desktopLatency, .localShellOpened, .terminalImageResult, .localWorkspaces,
             .desktopScreenState, .desktopUnlockResult, .desktopCursorImage:
            break
        }
    }

    /// Mac 刚重启、本机终端还没接回来时，手机不能看到一份缺了它们的列表（它会把「消失了」的标签关掉），
    /// 接入也不能回「已关闭」。等接回完再说；没有要接回的就是立刻执行。
    private func afterSessionRestoration(_ action: @escaping @MainActor () -> Void) {
        guard let restoration = server.sessionRestoration else {
            action()
            return
        }
        Task { [weak self] in
            await restoration()
            guard let self, !self.isClosed else { return }
            action()
        }
    }

    func sendSessions() {
        guard subscribedToSessions else { return }
        link.send(RemoteMessage(.sessions, payload: RemoteJSON.encode(server.sessionInfos())))
    }

    private func attach(_ request: RemoteAttachRequest) {
        let channel = nextChannel
        nextChannel &+= 1
        guard let session = server.registry.session(for: request.sessionID),
              session.connectionState == .connected else {
            sendAttachResult(channel, request.sessionID, error: "这个终端已经关闭或断开")
            return
        }
        // 先钉尺寸再订阅：第一份快照就是手机的行列数。
        server.claim(sessionID: request.sessionID, connection: self, channel: channel)
        session.pinRemoteGrid(cols: Int(request.cols), rows: Int(request.rows), controller: peerName)
        session.remoteDisconnect = { [weak self] in
            self?.detach(channel: channel, notify: true, reason: "已在 Mac 上断开")
        }
        // 接入结果先于快照入队：连接队列先进先出，手机一定先收到「接入成功」再收到画面。
        sendAttachResult(channel, request.sessionID, error: nil)
        let subscriberID = UUID()
        let pump = self.pump
        let subscriber = session.mirrorTap.subscribe(id: subscriberID) { pump.requestDrain() }
        attachments[channel] = Attachment(sessionID: request.sessionID, session: session, subscriberID: subscriberID)
        pump.add(channel: channel, subscriber: subscriber)
        let device = peerName
        AppLogger.info("远控接入：\(device) → 会话 \(request.sessionID.uuidString.prefix(8))，\(request.cols)×\(request.rows)",
                       category: RemoteLog.category)
    }

    /// 手机送来一张图片，交给这个通道上的会话的后端（本机 shell 走剪贴板 + Ctrl+V，SSH 传成服务器上的文件），
    /// 把结果回过去。路径由手机粘进终端：粘贴要看终端开没开 bracketed paste，手机端的终端知道。
    private func deliverImage(_ request: RemoteTerminalImageRequest, channel: UInt32) {
        let device = peerName
        let backend = attachments[channel]?.session?.backend as? any TerminalImageReceiving
        Task { [weak self] in
            var reply = RemoteTerminalImageResult(requestID: request.requestID)
            if let backend {
                do {
                    if case .file(let path) = try await backend.deliverImage(request.image) { reply.path = path }
                } catch {
                    reply.error = "图片发送失败：\(error.localizedDescription)"
                }
            } else {
                reply.error = "这个终端不能接收图片"
            }
            AppLogger.info("远控：\(device) 贴图 \(request.image.data.count) 字节 → \(reply.error ?? reply.path ?? "剪贴板")",
                           category: RemoteLog.category)
            guard let self, !self.isClosed else { return }
            self.link.send(RemoteMessage(.terminalImageResult, payload: RemoteJSON.encode(reply)))
        }
    }

    /// 手机要一个本机 shell：交给 `localShellOpener`（开窗口、等会话登记），把会话 id 或失败原因回过去。
    /// 等的这几秒里连接照常收发；手机拿到 id 后自己发 `.attach`。
    private func openLocalShell(_ request: RemoteOpenLocalShellRequest) {
        let device = peerName
        AppLogger.info("远控：\(device) 请求新建本机终端", category: RemoteLog.category)
        Task { [weak self] in
            guard let opener = self?.server.localShellOpener else { return }
            let result = await opener.open(request.directory)
            guard let self, !self.isClosed else { return }
            let reply: RemoteOpenLocalShellResult
            switch result {
            case .success(let sessionID):
                reply = RemoteOpenLocalShellResult(requestID: request.requestID, sessionID: sessionID, error: nil)
            case .failure(let failure):
                AppLogger.info("远控：本机终端没开成：\(failure.message)", category: RemoteLog.category)
                reply = RemoteOpenLocalShellResult(requestID: request.requestID, sessionID: nil, error: failure.message)
            }
            self.link.send(RemoteMessage(.localShellOpened, payload: RemoteJSON.encode(reply)))
        }
    }

    private func sendAttachResult(_ channel: UInt32, _ sessionID: UUID, error: String?) {
        link.send(RemoteMessage(.attached, channel: channel,
                                payload: RemoteJSON.encode(RemoteAttachResult(sessionID: sessionID, error: error))))
    }

    /// 结束一个通道的接入。`notify` = 告诉手机（Mac 侧主动断开、会话结束、被别的设备接管）。
    func detach(channel: UInt32, notify: Bool, reason: String = "") {
        guard let attachment = attachments.removeValue(forKey: channel) else { return }
        pump.remove(channel: channel)
        if let session = attachment.session {
            session.mirrorTap.unsubscribe(id: attachment.subscriberID)
            if server.isController(sessionID: attachment.sessionID, connection: self, channel: channel) {
                session.unpinRemoteGrid()
                session.remoteDisconnect = nil
            }
        }
        server.release(sessionID: attachment.sessionID, connection: self, channel: channel)
        if notify {
            link.send(RemoteMessage(.closed, channel: channel, payload: Data(reason.utf8)))
        }
    }

    /// 会话列表变了：已经没了的会话，结束对应的接入。
    func sessionsChanged(alive: Set<UUID>) {
        for (channel, attachment) in attachments where !alive.contains(attachment.sessionID) {
            detach(channel: channel, notify: true, reason: "这个终端已经关闭或断开")
        }
        sendSessions()
    }

    private func didClose() {
        guard !isClosed else { return }
        isClosed = true
        finishKeyConfirmation(false)
        for channel in Array(attachments.keys) {
            detach(channel: channel, notify: false)
        }
        if let desktop {
            stopDesktop(channel: desktop.channel, notify: false)
        }
        server.connectionClosed(self)
    }
}

// MARK: - 桌面

extension RemoteHostConnection {
    var desktopStats: RemoteDesktopStreamerStats? { desktop?.streamer.stats }

    /// 开桌面流：查开关与授权 → 定视频尺寸 → 建发送端并开始采集 → 在连接队列上先回「开流成功」再推第一帧。
    /// 被拒（没开开关、没屏幕录制授权、采集起不来）时回一条带 `failure` 的 `desktopStarted`，连接不断。
    ///
    /// 授权查询要等 tccd（见 `RemoteDesktopPermissions`），在主线程外跑；等的这几十毫秒里可能又来了一次开流
    /// 或连接断了，所以回来后只有最后一次请求、且连接还在才继续。
    fileprivate func startDesktop(_ request: RemoteDesktopStartRequest) async {
        let channel = nextChannel
        nextChannel &+= 1
        desktopStartGeneration &+= 1
        let generation = desktopStartGeneration
        let environment = server.desktopEnvironment
        func reject(_ failure: RemoteDesktopInfo.Failure, _ message: String) {
            link.send(RemoteMessage(.desktopStarted, channel: channel, payload: RemoteJSON.encode(
                RemoteDesktopInfo(requestID: request.requestID, failure: failure, message: message))))
        }
        guard environment.isEnabled() else {
            return reject(.disabled, "Mac 上没有打开远程桌面。在 Mac 的 uTerm 里打开「设置 › 远程控制」中的「允许远程桌面」。")
        }
        async let screenAuthorized = environment.screenCaptureAuthorized()
        async let postEventsAuthorized = environment.canPostEvents()
        let (canCapture, canControl) = await (screenAuthorized, postEventsAuthorized)
        guard generation == desktopStartGeneration, !isClosed else { return }
        guard canCapture else {
            return reject(.screenPermission,
                          "Mac 上的 uTerm 还没有「屏幕录制」权限。在 Mac 的「设置 › 远程控制」里授权，并按提示重启 uTerm。")
        }
        guard let display = environment.display(request.displayID) ?? environment.display(nil) else {
            return reject(.captureFailed, "找不到 Mac 的显示器")
        }
        // 息屏时先把显示器叫醒再采集，否则 ScreenCaptureKit 找不到它。等的这会儿可能又来了新请求或断了。
        await environment.wakeDisplay(display.id)
        guard generation == desktopStartGeneration, !isClosed else { return }
        let size = RemoteDesktopGeometry.streamSize(
            displayPixels: CGSize(width: display.pixelWidth, height: display.pixelHeight),
            maxWidth: request.maxWidth, maxHeight: request.maxHeight)
        if let current = desktop {
            stopDesktop(channel: current.channel, notify: false)
        }
        let device = peerName
        // 新手机（能解旁路精修帧）+ HEVC：10-bit 主流 + 旁路精修。老手机照旧，免得它把旁路帧当主流解。
        let sidecar = request.codec == .hevc && request.sidecarRefine == true
        let video = request.videoDatagrams == true ? link.videoChannel : nil
        let streamer = RemoteDesktopStreamer(
            link: link, channel: channel, codec: request.codec, width: size.width, height: size.height, display: display,
            sidecarRefine: sidecar, sendsLatency: request.latencyStats == true, path: origin.path, video: video,
            source: environment.makeSource(display, size.width, size.height, sidecar),
            injector: canControl ? environment.makeInjector(display) : nil,
            cursorLocation: environment.cursorLocation,
            clipboard: canControl && peerTakesClipboard ? environment.clipboard : nil,
            onFirstInput: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.server.desktopInputStarted(connection: self, channel: channel)
                    }
                }
            },
            onSourceStopped: { [weak self] error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AppLogger.info("远程桌面采集停止：\(error?.localizedDescription ?? "无错误")", category: RemoteLog.category)
                        self?.stopDesktop(channel: channel, notify: true, reason: "Mac 上的屏幕采集已停止")
                    }
                }
            })
        desktop = (channel, streamer)
        desktopRoute.set(streamer)
        server.claimDesktop(connection: self, channel: channel, canControl: canControl)
        setupScreenControl(channel: channel)
        let info = RemoteDesktopInfo(
            requestID: request.requestID, displayID: display.id,
            displayWidth: display.bounds.width, displayHeight: display.bounds.height,
            streamWidth: size.width, streamHeight: size.height, codec: request.codec, canControl: canControl,
            controlNote: canControl ? nil : "Mac 上的 uTerm 没有「辅助功能」权限，只能查看。在 Mac 的「设置 › 远程控制」里授权后重启 uTerm，即可控制。",
            videoDatagrams: video != nil ? true : nil,
            displays: { let all = environment.listDisplays(); return all.isEmpty ? nil : all }())
        AppLogger.info("远程桌面：\(device) 开始查看，\(size.width)×\(size.height) \(request.codec.rawValue)，可控制 \(canControl)",
                       category: RemoteLog.category)
        Task {
            do {
                try await streamer.start()
            } catch {
                guard desktop?.channel == channel else { return }
                stopDesktop(channel: channel, notify: false)
                reject(.captureFailed, "Mac 上的屏幕采集无法启动：\(error.localizedDescription)")
                return
            }
            guard desktop?.channel == channel, !isClosed else {
                streamer.stop()
                return
            }
            streamer.activate(started: RemoteMessage(.desktopStarted, channel: channel, payload: RemoteJSON.encode(info)))
            // 初始锁屏状态、光标形状排在 `desktopStarted` 之后发：对端要先靠它绑定通道，才接得到后续消息。
            sendScreenState()
            if request.cursorImages == true { startCursorShapes(channel: channel) }
        }
    }

    /// 结束桌面流。`notify` = 告诉手机（Mac 上断开、被别的设备接管、采集停了）。
    func stopDesktop(channel: UInt32, notify: Bool, reason: String = "") {
        guard let current = desktop, current.channel == channel else { return }
        desktop = nil
        desktopRoute.set(nil)
        current.streamer.stop()
        stopCursorShapes()
        teardownScreenControl()
        server.releaseDesktop(connection: self, channel: channel)
        if notify {
            link.send(RemoteMessage(.closed, channel: channel, payload: Data(reason.utf8)))
        }
    }
}

// MARK: - 光标形状

extension RemoteHostConnection {
    /// 每 100 ms 看一眼系统光标，形状变了才发（一张几 KB 的 PNG）。主控端拿它当本机光标，I 形、调整大小这些都对得上。
    func startCursorShapes(channel: UInt32) {
        stopCursorShapes()
        let environment = server.desktopEnvironment
        guard let signature = environment.cursorSignature, let image = environment.cursorImage else { return }
        let tick: @MainActor () -> Void = { [weak self] in
            guard let self, self.desktop?.channel == channel, let current = signature(),
                  current != self.lastCursorSignature else { return }
            self.lastCursorSignature = current
            guard let shape = image() else { return }
            self.link.send(RemoteMessage(.desktopCursorImage, channel: channel, payload: RemoteJSON.encode(shape)))
        }
        tick()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        cursorShapeTimer = timer
    }

    func stopCursorShapes() {
        cursorShapeTimer?.invalidate()
        cursorShapeTimer = nil
        lastCursorSignature = nil
    }
}

// MARK: - 远程解锁与帘幕

extension RemoteHostConnection {
    /// 开桌面流后（手机支持远程解锁时）：点亮显示器、推一次锁屏状态、挂锁屏状态监听、接本机解除帘幕的出口。
    func setupScreenControl(channel: UInt32) {
        // 不看开关：开关关着也要推锁屏状态，手机才能显示「已锁定、未开启远程解锁」并在开关打开后立刻可用。
        guard peerSupportsUnlock, let controller = server.screenController else { return }
        controller.onLocalCurtainRelease = { [weak self] in
            guard let self, let channel = self.desktop?.channel else { return }
            self.stopDesktop(channel: channel, notify: true, reason: "已在 Mac 上解除帘幕")
        }
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            let observer = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendScreenState() }
            }
            lockObservers.append(observer)
        }
    }

    private func teardownScreenControl() {
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        lockObservers.removeAll()
        if let controller = server.screenController {
            controller.onLocalCurtainRelease = nil
            // 远控结束时：远程解锁过、或帘幕还开着，就先把 Mac 锁回去，再撤掉黑屏与本机输入暂停，
            // 避免一撤帘幕就露出桌面；手机中途手动关了帘幕的，同样要锁回去。
            if remotelyUnlocked || controller.isCurtained {
                controller.lockScreen()
                controller.setCurtain(false)
            }
        }
        remotelyUnlocked = false
    }

    /// 把当前锁屏 / 帘幕状态推给手机。
    func sendScreenState() {
        guard peerSupportsUnlock, let channel = desktop?.channel, let controller = server.screenController else { return }
        let state = RemoteDesktopScreenState(
            locked: controller.isLocked, curtained: controller.isCurtained,
            unlockAvailable: server.desktopEnvironment.isUnlockEnabled() && (server.desktopViewer?.canControl ?? false))
        link.send(RemoteMessage(.desktopScreenState, channel: channel, payload: RemoteJSON.encode(state)))
    }

    /// 发请求的这条连接正是在看屏幕、能控制的那一路（另一台已配对的手机没开桌面流，不能替它解锁）。
    private func ownsControllingDesktop(channel: UInt32) -> Bool {
        guard desktop?.channel == channel, let viewer = server.desktopViewer else { return false }
        return viewer.connection == id && viewer.channel == channel && viewer.canControl
    }

    private func canUnlockRemotely(channel: UInt32) -> Bool {
        peerSupportsUnlock && server.desktopEnvironment.isUnlockEnabled()
            && ownsControllingDesktop(channel: channel) && server.screenController != nil
    }

    fileprivate func handleUnlock(requestID: UUID, password: String, channel: UInt32) {
        func reply(_ outcome: RemoteDesktopUnlockResult.Outcome) {
            link.send(RemoteMessage(.desktopUnlockResult, channel: channel,
                                    payload: RemoteJSON.encode(RemoteDesktopUnlockResult(requestID: requestID, outcome: outcome))))
        }
        guard canUnlockRemotely(channel: channel), !unlockInFlight,
              let controller = server.screenController else { return reply(.notAllowed) }
        guard controller.isLocked else { return reply(.notLocked) }
        AppLogger.info("远程桌面：\(self.peerName) 请求解锁 Mac", category: RemoteLog.category)
        unlockInFlight = true
        // 先挂帘幕再输密码：gamma 黑屏在锁屏界面上同样有效，锁屏一消失物理屏已经是黑的，不会闪出桌面。
        // 本机输入暂停在锁屏时不起作用（系统收走了输入流），解锁后立即生效。
        let wasCurtained = controller.isCurtained
        controller.setCurtain(true)
        Task {
            let success = await controller.unlock(password: password)
            unlockInFlight = false
            guard !isClosed, desktop?.channel == channel else {
                // 手机在解锁过程中走了：解开了就锁回去，别把已解锁的桌面晾在那里。
                if success { controller.lockScreen() }
                if !wasCurtained { controller.setCurtain(false) }
                return
            }
            if success {
                remotelyUnlocked = true
                AppLogger.info("远程桌面：解锁成功，已进入帘幕", category: RemoteLog.category)
            } else {
                // 没解开：撤掉为这次解锁临时挂上的帘幕，Mac 前的人还能看到锁屏。
                if !wasCurtained { controller.setCurtain(false) }
                AppLogger.info("远程桌面：解锁未成功", category: RemoteLog.category)
            }
            reply(success ? .unlocked : .rejected)
            sendScreenState()
        }
    }

    fileprivate func setCurtain(_ on: Bool, channel: UInt32) {
        guard let controller = server.screenController, ownsControllingDesktop(channel: channel) else { return }
        // 关帘幕不看开关：开关中途被关掉时，手机仍要能把帘幕撤掉。开帘幕才要求开关打开。
        if on, !canUnlockRemotely(channel: channel) { return }
        controller.setCurtain(on)
        sendScreenState()
    }
}

/// 把镜像订阅者的积压搬上网：合并、加密、发送，全在连接队列上做。
///
/// 每次最多取 `maxOutputChunkBytes`，各通道轮流取；网络栈里在途的字节超过上限就停手，
/// 等 `onWritable` 再继续。停手期间积压留在订阅者那里，超过它的上限就会被换成快照。
nonisolated final class RemoteOutputPump: @unchecked Sendable {
    /// 发出了输出（连接队列上，最多 30 秒一次，防睡眠策略用）。在 `RemoteHostConnection.init` 里设一次，之后只读。
    var onOutputSent: (@Sendable () -> Void)?
    /// 只在 `link.queue` 上读写。
    private var lastOutputNote: DispatchTime?
    private let link: RemoteLink
    /// 只在 `link.queue` 上读写。
    private var subscribers: [(channel: UInt32, subscriber: TerminalMirrorTap.Subscriber)] = []
    private var cursor = 0

    init(link: RemoteLink) {
        self.link = link
    }

    func add(channel: UInt32, subscriber: TerminalMirrorTap.Subscriber) {
        link.queue.async {
            self.subscribers.append((channel, subscriber))
            // 订阅时生成的快照可能已经在等着了，而它的唤醒早于这里的登记。
            self.drainOnQueue()
        }
    }

    func remove(channel: UInt32) {
        link.queue.async {
            self.subscribers.removeAll { $0.channel == channel }
        }
    }

    func requestDrain() {
        link.queue.async { self.drainOnQueue() }
    }

    private func noteOutputSent() {
        let now = DispatchTime.now()
        if let lastOutputNote, now < lastOutputNote + 30 { return }
        lastOutputNote = now
        onOutputSent?()
    }

    func drainOnQueue() {
        dispatchPrecondition(condition: .onQueue(link.queue))
        guard !subscribers.isEmpty else { return }
        while link.canSendMore {
            var sentAny = false
            defer { if sentAny { noteOutputSent() } }
            for offset in 0..<subscribers.count {
                let index = (cursor + offset) % subscribers.count
                let (channel, subscriber) = subscribers[index]
                guard let bytes = subscriber.take(maxBytes: RemoteConstants.maxOutputChunkBytes) else { continue }
                link.sendOnQueue(RemoteMessage(.output, channel: channel, payload: bytes))
                sentAny = true
                cursor = (index + 1) % subscribers.count
                if !link.canSendMore { return }
            }
            if !sentAny { return }
        }
    }
}

/// 一条连接是从哪条路进来的。
enum RemoteConnectionOrigin {
    case localNetwork
    /// 经信令打过招呼才进来的公网连接：`peerID` 是打招呼的那台设备。
    case internet(peerID: UUID, keys: RemoteHandshakeKeys, path: RemoteLinkPath)

    var isInternet: Bool {
        if case .internet = self { return true }
        return false
    }

    var handshakeKeys: RemoteHandshakeKeys? {
        if case .internet(_, let keys, _) = self { return keys }
        return nil
    }

    var path: RemoteLinkPath {
        if case .internet(_, _, let path) = self { return path }
        return .localNetwork
    }
}
