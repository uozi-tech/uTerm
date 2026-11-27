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
    /// 接入的时刻（日志：握手、开流各在接入后多久）。
    private let createdAt = ContinuousClock.now
    private let link: RemoteLink
    private unowned let server: RemoteHostServer
    private let pump: RemoteOutputPump
    private let desktopRoute: RemoteDesktopRoute
    /// 当前的桌面流（同一连接最多一路）。
    private var desktop: (channel: UInt32, streamer: RemoteDesktopStreamer)?
    /// 当前桌面流上的声音（手机打开了扬声器才有）。
    private var audio: RemoteAudioStreamer?
    /// 每开一次声音 +1，手机据此认出新的一条声音流（序号从头算）。
    /// 声音流号：开新声音流、声音中途换档都从这里取（换档在连接队列上，所以要加锁）。
    private let audioStreams = RemoteAudioStreamNumbers()
    /// 手机每发一次开 / 关声音就 +1（收到时同步加）。开声音要先 hop 一次再开采集，这期间又收到了关或新的开，
    /// 旧的那次就作废：不然「开了马上关」时关先执行、扑空，开随后照样把声音流开起来。
    private var audioRequestGeneration = 0
    /// 手机认得声音消息（`desktop-audio`）。
    private var peerSupportsAudio = false
    /// 对端能解无损声音（声明了 `desktopAudioLossless`）。
    private var peerSupportsAudioLossless = false
    /// 对端认得 `programStatus`（老设备收到会当未知消息断开整条连接）。本机也要声明过才推。
    private var peerTakesProgramStatus = false
    /// 对端握手里报的终端引擎版本；快照格式和本机不互认时改发回放流，对端不认回放流就不让它接入终端。
    private var peerTerminalEngine: String?
    /// 两端都声明了 `terminal-replay`（对端认得回放流，本机会发）。
    private var peerTakesTerminalReplay = false
    /// 对端认得 `codeTabs`（老设备收到会当未知消息断开整条连接）。本机也要声明过才推。
    private var peerTakesCodeTabs = false
    /// 上次发给这台设备的 Code 标签页。没变就不再发：会话列表每推一次都先问一遍。
    private var sentCodeTabs: [RemoteCodeTabInfo]?

    /// 对端设备名与 ID（握手后才有）。
    private(set) var peerName = ""
    private(set) var peerID: UUID?
    /// 对端握手时报的长期公钥（握手后才有）。等审批时据此判断它是不是刚由别的途径记进了信任表。
    private(set) var peerKey: Data?
    /// 对端握手时报的平台（`RemoteDevicePlatform`）。老版本不报。
    private(set) var peerPlatform: String?
    /// 通过认证的时刻。同一台设备连着不止一条时，用最新的那条。
    private(set) var authorizedAt: Date?

    /// 在 Mac 上给这台设备改了名：正连着的这条立刻换成新名字，不用等它重连。
    func peerRenamed(to name: String) {
        peerName = name
    }
    /// 手机声明了会定时 ping（老手机空闲时不发任何东西，不能按无声断开）。
    private var peerSendsHeartbeat = false
    /// 手机认得 `desktopClipboard`（老手机收到会当未知消息断开整条连接）。
    private var peerTakesClipboard = false
    /// 为当前这条桌面流调过大小的窗口和它原来的位置：流结束时放回去。
    var desktopWindowRestore: (id: UInt32, frame: CGRect)?
    /// 停流后等一小会儿再把窗口放回去的那个任务。主控端转屏、折叠时是「停流 → 按新尺寸再开」，两条消息前后脚到：
    /// 立刻还原的话，还原和新的调大小是两个互不相干的异步动作，谁后落地不一定——还原落在后面，窗口就回到原来的
    /// 大尺寸，画面等于没适配（2026-11-17 真机）。所以先等着，新的开流来了就取消，接着用同一份原位置。
    private var windowRestoreTask: Task<Void, Never>?
    /// 看着一个窗口、主控端要它保持在最前时：隔一会儿看一眼，它的 App 不在最前了就重新提上来。
    private var windowFrontTask: Task<Void, Never>?
    /// 正在看的那个窗口（能控制时才记）和主控端要的像素框：原地换尺寸时用。
    private var desktopWindowStream: (windowID: UInt32, maxWidth: Int, maxHeight: Int)?
    /// 原地换尺寸一次只做一个，后来的排在后面。
    private var windowRefitTask: Task<Void, Never>?
    /// 窗口没调成要的大小、而 Mac 锁着屏（开流时，或看着时换尺寸）：等着调好的那个任务和要调成的大小（见 `awaitWindowFit`）。
    private var windowFitWait: Task<Void, Never>?
    private var pendingWindowFit: CGSize?
    static let windowFrontInterval: Duration = .seconds(1)
    static let windowRestoreGrace: Duration = .milliseconds(600)
    /// 等窗口调好时多久看一次锁屏状态（读会话字典，零点几毫秒）。解开了马上调。
    static let windowFitPollInterval: Duration = .milliseconds(250)
    /// 还锁着时每隔多久再试着调一次：说不定只是刚醒来那一下调不动（显示器重新配置）。
    static let windowFitLockedRetry: Duration = .seconds(2)
    /// 手机认得远程解锁 / 帘幕相关消息（`desktopScreenState` 等）。
    private var peerSupportsUnlock = false
    /// 对端认得解锁结果里的 `inputBlocked`。
    private var peerSupportsUnlockOutcomes = false
    /// 这条桌面流的锁屏状态监听（当前在看屏幕时才挂）。
    private var lockObservers: [NSObjectProtocol] = []
    /// 这条连接远程解锁过 Mac：远控结束时不管帘幕开没开都要锁回去。
    private var remotelyUnlocked = false
    /// 正在执行解锁（按键序列 + 轮询）：同时来的第二个请求直接拒掉，免得两串按键交错。
    private var unlockInFlight = false
    /// 对端认得屏上验证框的报告与回应（`desktop-auth-prompt`）。
    private var peerSupportsAuthPrompt = false
    /// 定时看屏上有没有验证框（开着桌面流、对端认得时才挂）与上次报出去的框。
    private var authPromptWatch: Task<Void, Never>?
    private var lastAuthPrompt: RemoteDesktopAuthPrompt?
    /// 正在回应验证框（切前台、打字、等结果）：同时来的第二个请求直接拒掉。
    private var authPromptInFlight = false
    /// 光标形状的轮询（开流请求要了 `cursorImages` 才挂）与上次发出的形状。
    private var cursorShapeTimer: Timer?
    private var lastCursorSignature: Int?
    /// 从哪条路进来的。公网路径规则更严：不弹审批框，没配对过的只认邀请凭据。
    let origin: RemoteConnectionOrigin
    private var peerSupportsRelayConfig = false
    /// 对端握手时声明了 `file-sharing`。
    private(set) var peerSharesFilesFeature = false
    /// 本机向这台主控端发出、还在等应答的文件请求。
    nonisolated let fileWaiters = RemoteFileWaiters()
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
        let handle: any RemoteHostTerminalAttachment
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
        let fileWaiters = self.fileWaiters
        link.setHandlers(
            onMessage: { [weak self] message in
                if desktopRoute.handle(message) { return }
                // 主控端对本机发出的文件请求的应答：在连接队列上直接交付，不经主线程（传文件时一秒几十条）。
                // 没在等的请求号（包括对端乱发的）直接丢掉。
                if message.kind == .fileReply {
                    fileWaiters.deliver(message.payload)
                    return
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(message) } }
            },
            onClose: { [weak self] error in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.didClose(error) } }
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
            features.removeAll { $0 == RemoteFeature.desktopUnlock || $0 == RemoteFeature.desktopAuthPrompt }
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
                                    platform: RemoteDevicePlatform.current.rawValue,
                                    terminalEngine: server.sessions.terminalEngine)
            let established = try await link.establish(role: .responder, hello: hello, staticKey: staticKey,
                                                       ephemeralKey: ephemeral, handshakeKeys: origin.handshakeKeys)
            let peer = established.peer
            peerName = peer.deviceName
            peerID = peer.deviceID
            peerKey = peer.staticKey
            peerPlatform = peer.platform
            peerSendsHeartbeat = peer.supports(RemoteFeature.heartbeat)
            peerTakesClipboard = peer.supports(RemoteFeature.desktopClipboard)
            peerSupportsUnlock = peer.supports(RemoteFeature.desktopUnlock)
            peerSupportsUnlockOutcomes = peer.supports(RemoteFeature.desktopUnlockOutcomes)
            peerSupportsAuthPrompt = peer.supports(RemoteFeature.desktopAuthPrompt)
            peerSupportsAudio = peer.supports(RemoteFeature.desktopAudio)
            peerSupportsAudioLossless = peer.supports(RemoteFeature.desktopAudioLossless)
            peerTakesProgramStatus = peer.supports(RemoteFeature.programStatus)
                && server.localFeatures.contains(RemoteFeature.programStatus)
            peerTakesCodeTabs = peer.supports(RemoteFeature.codeTabs)
                && server.localFeatures.contains(RemoteFeature.codeTabs)
            peerTerminalEngine = peer.terminalEngine
            peerTakesTerminalReplay = peer.supports(RemoteFeature.terminalReplay)
                && server.localFeatures.contains(RemoteFeature.terminalReplay)
            peerSupportsRelayConfig = peer.supports(RemoteFeature.relayConfig)
            peerSharesFilesFeature = peer.supports(RemoteFeature.fileSharing)
            if case .internet(let expected, _, _) = origin {
                try await authorizeFromInternet(peer: peer, expected: expected)
                return
            }
            if server.localFeatures.contains(RemoteFeature.keyConfirmation) {
                // 不能按对方声明的能力决定要不要验：冒充者在握手里不报 key-confirm 就能跳过验证、被记进信任列表。
                // 远控随 2.0 首发，能连上来的手机都带这一能力。
                guard peer.supports(RemoteFeature.keyConfirmation) else {
                    throw RemoteProtocolError.handshakeFailed(String(localized: "对方没有证明自己持有私钥"))
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
            // 等审批期间它已经由设备组 / 担保记进了信任表（`RemoteHostServer.approvePendingPairings`）：按认识的设备放行，
            // 不再当成在这台 Mac 上手动配对重记一遍——来路和配对时间（资历，§18）都不能被改掉。
            if server.identity.recognizes(id: peer.deviceID, publicKey: peer.staticKey) {
                try rememberRecognized(peer)
                authorize(.trusted)
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
            throw RemoteProtocolError.handshakeFailed(String(localized: "公网连接的身份与信令不符"))
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
        authorizedAt = Date()
        // 横幅、桌面指示条、设置里的「已连接」都按这个名字显示：在 Mac 上改过名就用改过的。
        if let peerID, let known = server.identity.peer(id: peerID) { peerName = known.displayName }
        AppLogger.notice("远控：\(self.peerName) 已确认身份（\(self.origin.path.label)，接入后 "
                         + "\(RemoteConnectTrace.millis(ContinuousClock.now - self.createdAt)) ms）", category: RemoteLog.category)
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
                guard let self else { return }
                self.subscribedToSessions = true
                self.sendSessions()
                // 紧跟在列表后面：设备先认识这些会话，再拿到它们的状态。
                self.sendProgramStatus(RemoteProgramStatusUpdate(replacesAll: true,
                                                                 entries: self.server.programStatusSnapshot()))
            }
        case .attach:
            guard let request = try? RemoteJSON.decode(RemoteAttachRequest.self, from: message.payload) else { return }
            // 通道号按请求到达的先后分配（对端靠回复里的通道号认出是哪一次接入），不等接回与 App 回话。
            let channel = nextChannel
            nextChannel &+= 1
            afterSessionRestoration { [weak self] in
                Task { await self?.attach(request, channel: channel) }
            }
        case .input:
            attachments[message.channel]?.handle.write(message.payload)
            server.noteRemoteInput()
        case .resize:
            guard let attachment = attachments[message.channel],
                  let size = try? RemoteGridSize(decoding: message.payload) else { return }
            attachment.handle.resize(cols: Int(size.cols), rows: Int(size.rows), controller: peerName)
        case .detach:
            detach(channel: message.channel, notify: false)
        case .ping:
            link.send(RemoteMessage(.pong))
        case .openLocalShell:
            guard let request = try? RemoteJSON.decode(RemoteOpenLocalShellRequest.self, from: message.payload) else { return }
            openLocalShell(request)
        case .codeTabAction:
            guard let action = try? RemoteJSON.decode(RemoteCodeTabAction.self, from: message.payload) else { return }
            performCodeTabAction(action)
        case .listLocalWorkspaces:
            guard let request = try? RemoteJSON.decode(RemoteLocalWorkspacesRequest.self, from: message.payload) else { return }
            let reply = RemoteLocalWorkspaces(requestID: request.requestID, home: RemoteLocalShellOpener.realHome,
                                              directories: server.localShellOpener.workspaces())
            link.send(RemoteMessage(.localWorkspaces, payload: RemoteJSON.encode(reply)))
        case .closeSession:
            guard let request = try? RemoteJSON.decode(RemoteCloseSessionRequest.self, from: message.payload) else { return }
            let device = peerName
            Task { [server] in
                let closed = await server.sessions.requestClose(sessionID: request.sessionID)
                AppLogger.info("远控：\(device) 关闭 Mac 上的会话 \(request.sessionID.uuidString.prefix(8))：\(closed ? "已关闭" : "没找到")",
                               category: RemoteLog.category)
            }
        case .arrangeSessions:
            guard let request = try? RemoteJSON.decode(RemoteArrangeSessionsRequest.self, from: message.payload) else { return }
            Task { [server] in await server.sessions.requestArrange(order: request.order) }
        case .terminalImage:
            guard let request = try? RemoteTerminalImageRequest(decoding: message.payload) else { return }
            deliverImage(request, channel: message.channel)
        case .fileRequest:
            handleFileRequest(message.payload)
        case .vouchDevice:
            guard let request = try? RemoteJSON.decode(RemoteVouchRequest.self, from: message.payload),
                  let peerID else { return }
            let result = server.handleVouch(request, voucherID: peerID, voucherName: peerName)
            link.send(RemoteMessage(.vouchResult, payload: RemoteJSON.encode(result)))
        case .revokeSibling:
            guard let request = try? RemoteJSON.decode(RemoteSiblingRevokeRequest.self, from: message.payload),
                  let peerID else { return }
            let result = server.handleSiblingRevoke(request, requesterID: peerID, requesterName: peerName)
            // 撤的可能就是自己：服务端下一拍才撤，结果先发出去。
            link.send(RemoteMessage(.revokeSiblingResult, payload: RemoteJSON.encode(result)))
        case .desktopStart:
            guard let request = try? RemoteJSON.decode(RemoteDesktopStartRequest.self, from: message.payload) else { return }
            Task { await startDesktop(request) }
        case .desktopStop:
            stopDesktop(channel: message.channel, notify: false)
        case .desktopWindows:
            guard let request = try? RemoteJSON.decode(RemoteDesktopWindowListRequest.self, from: message.payload) else { return }
            Task { await listDesktopWindows(request) }
        case .desktopWindowRefit:
            guard let fit = try? RemoteJSON.decode(RemoteDesktopFit.self, from: message.payload) else { return }
            refitDesktopWindow(fit, channel: message.channel)
        case .desktopUnlock:
            guard var request = try? RemoteJSON.decode(RemoteDesktopUnlockRequest.self, from: message.payload) else { return }
            let password = request.password
            request.password = ""
            handleUnlock(requestID: request.requestID, password: password, channel: message.channel)
        case .desktopCurtain:
            guard let request = try? RemoteJSON.decode(RemoteDesktopCurtainRequest.self, from: message.payload) else { return }
            setCurtain(request.on, channel: message.channel)
        case .desktopAuthPrompt:
            guard var request = try? RemoteJSON.decode(RemoteDesktopAuthPromptRequest.self, from: message.payload) else { return }
            let password = request.password
            request.password = nil
            handleAuthPrompt(request, password: password, channel: message.channel)
        case .desktopAudio:
            guard let request = try? RemoteJSON.decode(RemoteDesktopAudioRequest.self, from: message.payload) else { return }
            audioRequestGeneration += 1
            if request.enabled {
                let generation = audioRequestGeneration
                Task { await startAudio(request, channel: message.channel, generation: generation) }
            } else {
                stopAudio(notify: nil)
            }
        case .desktopAck, .desktopInput, .desktopKeyframe, .desktopPaste, .desktopPasteChunk, .desktopVideoLost,
             .desktopPause, .desktopRegion, .desktopPasteFile:
            // 已在连接队列上交给发送端（`RemoteDesktopRoute`），不会走到这里。
            break
        case .keyConfirm, .relayConfig, .sessions, .attached, .output, .closed, .pong, .pairing, .desktopStarted, .desktopFrame,
             .desktopCursor, .desktopClipboard, .desktopLatency, .localShellOpened, .terminalImageResult, .localWorkspaces,
             .desktopScreenState, .desktopUnlockResult, .desktopCursorImage, .desktopAudioFormat, .desktopAudioFrame,
             .linkAck, .linkFragment, .programStatus, .terminalSnapshot, .fileReply, .vouchResult, .revokeSiblingResult,
             .desktopWindowList, .desktopGeometry, .desktopAuthPromptResult, .codeTabs, .codeTabActionResult:
            break
        }
    }

    /// 一条文件请求：过门禁，交给辅助程序，把应答发回去。主程序不解释内容，只为了记日志看一眼头。
    /// 应答不计入终端输出的背压：主控端自己限着在途的请求数，这里计进去的话传文件时镜像的终端会以为链路堵了。
    private func handleFileRequest(_ payload: Data) {
        let access = server.fileAccess
        let link = self.link
        let send: @Sendable (Data) -> Void = { reply in
            link.queue.async {
                link.sendOnQueue(RemoteMessage(.fileReply, channel: RemoteConstants.fileChannel, payload: reply),
                                 countsTowardBackpressure: false)
            }
        }
        guard let (request, _) = try? RemoteFileCodec.decode(RemoteFileRequest.self, from: payload) else {
            send(RemoteFileCodec.packReply(.failure(RemoteFileCodec.requestID(of: payload) ?? UUID(),
                                                    RemoteFileError(.invalid, String(localized: "请求解不开"))), compress: false))
            return
        }
        if let refusal = access.refusal(request.op) {
            send(RemoteFileCodec.packReply(.failure(request.id, refusal), compress: false))
            return
        }
        // 传输时一秒几十条读写，逐条记没有意义：只记会改东西的和跑命令。
        if request.op.isMutation, request.op != .write {
            // 命令只记开头：里面可能带着令牌，日志也不该被一条长命令撑开。
            let subject = request.op == .exec ? String((request.command ?? "").prefix(80)) : (request.path ?? "")
            AppLogger.info("远控：\(self.peerName) 文件操作 \(request.op.rawValue) \(subject)",
                           category: RemoteLog.category)
        }
        server.noteRemoteInput()
        Task.detached {
            send(await access.perform(payload))
        }
    }

    /// Mac 刚重启、本机终端还没接回来时，手机不能看到一份缺了它们的列表（它会把「消失了」的标签关掉），
    /// 接入也不能回「已关闭」。等接回完再说；没有要接回的就是立刻执行。
    private func afterSessionRestoration(_ action: @escaping @MainActor () -> Void) {
        Task { [weak self, server] in
            await server.waitForSessionRestoration()
            guard let self, !self.isClosed else { return }
            action()
        }
    }

    func sendSessions() {
        guard subscribedToSessions else { return }
        // 先于列表：设备收到列表时已经知道哪些会话归 Code 标签页（见 `RemoteMessage.Kind.codeTabs`）。
        sendCodeTabsIfChanged()
        link.send(RemoteMessage(.sessions, payload: RemoteJSON.encode(server.sessionInfos())))
    }

    /// Mac 上的 Code 标签页和上次发给这台设备的不一样就发一份（整份替换）。只发给认得这条消息、订阅了会话列表的设备；
    /// 会话这边报不出来（远控进程里 App 还没交来过）时一条都不发。
    func sendCodeTabsIfChanged() {
        guard subscribedToSessions, peerTakesCodeTabs, let tabs = server.sessions.codeTabs(), tabs != sentCodeTabs else { return }
        sentCodeTabs = tabs
        link.send(RemoteMessage(.codeTabs, payload: RemoteJSON.encode(RemoteCodeTabsUpdate(tabs: tabs))))
    }

    /// 程序状态：订阅时的全量快照，之后是变了的会话。只发给认得这条消息、且订阅了会话列表的设备。
    func sendProgramStatus(_ update: RemoteProgramStatusUpdate) {
        guard subscribedToSessions, peerTakesProgramStatus else { return }
        link.send(RemoteMessage(.programStatus, payload: RemoteJSON.encode(update)))
    }

    private func attach(_ request: RemoteAttachRequest, channel: UInt32) async {
        // 快照是引擎的二进制格式：对端的快照格式和本机不互认就改发回放流，对端连回放流也不认就不接入。
        guard let format = RemoteTerminalEngine.snapshotFormat(peer: peerTerminalEngine, replayBothWays: peerTakesTerminalReplay,
                                                               local: server.sessions.terminalEngine) else {
            sendAttachResult(channel, request.sessionID, error: RemoteTerminalEngine.mismatchMessage)
            return
        }
        let pump = self.pump
        // 先钉尺寸再订阅：第一份快照就是手机的行列数（订阅里等钉好）。
        let result = await server.sessions.attach(RemoteHostAttachRequest(
            sessionID: request.sessionID, cols: Int(request.cols), rows: Int(request.rows), controller: peerName,
            settleTimeout: RemoteConstants.attachGridSettleTimeout, snapshotFormat: format,
            onReadable: { pump.requestDrain() }))
        let attachment: any RemoteHostTerminalAttachment
        switch result {
        case .failure(let error):
            guard !isClosed else { return }
            sendAttachResult(channel, request.sessionID, error: error.message, retryable: error == .appUnavailable)
            return
        case .success(let handle):
            attachment = handle
        }
        guard !isClosed else {
            attachment.detach()
            return
        }
        server.claim(sessionID: request.sessionID, connection: self, channel: channel)
        attachment.onRemoteDisconnect = { [weak self] in
            self?.detach(channel: channel, notify: true, reason: String(localized: "已在 Mac 上断开"))
        }
        // 接入结果先于快照入队：连接队列先进先出，手机一定先收到「接入成功」再收到画面。
        sendAttachResult(channel, request.sessionID, error: nil)
        attachments[channel] = Attachment(sessionID: request.sessionID, handle: attachment)
        pump.add(channel: channel, feed: attachment.feed)
        AppLogger.info("远控接入：\(self.peerName) → 会话 \(request.sessionID.uuidString.prefix(8))，\(request.cols)×\(request.rows)",
                       category: RemoteLog.category)
    }

    /// 手机送来一张图片，交给这个通道上的会话的后端（本机 shell 走剪贴板 + Ctrl+V，SSH 传成服务器上的文件），
    /// 把结果回过去。路径由手机粘进终端：粘贴要看终端开没开 bracketed paste，手机端的终端知道。
    private func deliverImage(_ request: RemoteTerminalImageRequest, channel: UInt32) {
        let device = peerName
        let handle = attachments[channel]?.handle
        Task { [weak self] in
            var reply = RemoteTerminalImageResult(requestID: request.requestID)
            switch await handle?.deliverImage(request.image) {
            case .success(let path): reply.path = path
            case .failure(let error): reply.error = error.message
            case nil: reply.error = String(localized: "这个终端不能接收图片")
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

    /// 设备请 Mac 在它的 Code 标签页里做一件事：交给 `codeTabActions`（可能要先开窗口、开 Code 标签页、等列表），
    /// 把做完的会话 id 或失败原因回过去。等的这几秒里连接照常收发；新会话随后照常出现在 63 / 20 号推送里。
    private func performCodeTabAction(_ action: RemoteCodeTabAction) {
        let device = peerName
        AppLogger.info("远控：\(device) 请求在 Code 标签页里 \(action.action)", category: RemoteLog.category)
        Task { [weak self] in
            guard let actor = self?.server.codeTabActions else { return }
            let result = await actor.perform(action)
            guard let self, !self.isClosed else { return }
            if let error = result.error {
                AppLogger.info("远控：Code 标签页的 \(action.action) 没做成：\(error)", category: RemoteLog.category)
            }
            // 回复里的 requestID 以请求为准（落点没带对也不让设备一直等）。
            let reply = RemoteCodeTabActionResult(requestID: action.requestID, session: result.session,
                                                  error: result.session == nil ? result.error : nil)
            self.link.send(RemoteMessage(.codeTabActionResult, payload: RemoteJSON.encode(reply)))
        }
    }

    private func sendAttachResult(_ channel: UInt32, _ sessionID: UUID, error: String?, retryable: Bool = false) {
        let result = RemoteAttachResult(sessionID: sessionID, error: error, retryable: retryable ? true : nil)
        link.send(RemoteMessage(.attached, channel: channel, payload: RemoteJSON.encode(result)))
    }

    /// 结束一个通道的接入。`notify` = 告诉手机（Mac 侧主动断开、会话结束、被别的设备接管）。
    func detach(channel: UInt32, notify: Bool, reason: String = "") {
        guard let attachment = attachments.removeValue(forKey: channel) else { return }
        pump.remove(channel: channel)
        attachment.handle.detach()
        server.release(sessionID: attachment.sessionID, connection: self, channel: channel)
        if notify {
            link.send(RemoteMessage(.closed, channel: channel, payload: Data(reason.utf8)))
        }
    }

    /// 会话列表变了：已经没了的会话，结束对应的接入。
    func sessionsChanged(alive: Set<UUID>) {
        for (channel, attachment) in attachments where !alive.contains(attachment.sessionID) {
            detach(channel: channel, notify: true, reason: String(localized: "这个终端已经关闭或断开"))
        }
        sendSessions()
    }

    private func didClose(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        if isAuthorized {
            // 为什么断（对端关的、无声超时、网络错误）：手机上「刚回前台就断」这类问题要两头对着看。
            AppLogger.notice("远控：与 \(self.peerName) 的连接断开（\(self.origin.path.label)，接入后 "
                             + "\(RemoteConnectTrace.millis(ContinuousClock.now - self.createdAt)) ms）："
                             + (error?.localizedDescription ?? "正常关闭"), category: RemoteLog.category)
        }
        finishKeyConfirmation(false)
        fileWaiters.failAll(RemoteFileError(.unreachable, String(localized: "「\(peerName)」的连接断开了")))
        for channel in Array(attachments.keys) {
            detach(channel: channel, notify: false)
        }
        if let desktop {
            stopDesktop(channel: desktop.channel, notify: false)
        }
        windowRestoreTask?.cancel()
        windowRestoreTask = nil
        windowFrontTask?.cancel()
        windowFrontTask = nil
        cancelWindowFitWait()
        if let pending = desktopWindowRestore {
            // 调过大小的窗口：连接断了马上放回去，不等了。
            desktopWindowRestore = nil
            let server = self.server
            Task { await Self.restoreFittedWindow(pending, server: server) }
        }
        server.connectionClosed(self)
    }
}

// MARK: - 反过来读写主控端的文件

extension RemoteHostConnection {
    /// 对端是一台肯提供文件的主控端（Mac 上的 uTerm；手机和老版本不声明）。
    var peerSharesFiles: Bool { isAuthorized && !isClosed && peerSharesFilesFeature }

    /// 向主控端发一条文件请求，等应答。它只放行用户共享给本机的那几个文件夹里的请求。
    /// 打包、压缩、解包都不在主线程上做。
    nonisolated func performFile(_ request: RemoteFileRequest, body: Data = Data(),
                                 timeout: Duration? = nil) async throws -> (reply: RemoteFileReply, body: Data) {
        var request = request
        request.acceptsCompression = true
        let payload = RemoteFileCodec.packRequest(request, body: body, compress: true)
        let raw = try await exchangeFile(payload, id: request.id, timeout: timeout ?? RemoteFileTimeouts.limit(for: request))
        let (reply, data) = try RemoteFileCodec.unpackReply(raw)
        if let error = reply.error { throw error }
        return (reply, data)
    }

    /// 发一条打包好的文件请求，等打包好的应答（远控进程替 App 转命令行的请求时用：打包、解包都在 App 那头）。
    nonisolated func exchangeFile(_ payload: Data, id: UUID, timeout: Duration) async throws -> Data {
        let (link, name) = try await MainActor.run { () throws -> (RemoteLink, String) in
            guard !isClosed, isAuthorized else {
                throw RemoteFileError(.unreachable, String(localized: "「\(peerName)」已经不连着这台 Mac 了"))
            }
            guard peerSharesFilesFeature else {
                throw RemoteFileError(.unsupported, String(localized: "「\(peerName)」不提供文件（手机，或者那台 Mac 上的 uTerm 版本太旧）"))
            }
            return (self.link, peerName)
        }
        return try await fileWaiters.exchange(payload, id: id, timeout: timeout, peer: String(localized: "「\(name)」", comment: "给设备名加引号，用在「某设备在 N 秒内没有回应」里")) { payload in
            link.send(RemoteMessage(.fileRequest, channel: RemoteConstants.fileChannel, payload: payload))
        }
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
            return reject(.disabled, String(localized: "Mac 上没有打开远程桌面。在 Mac 的 uTerm 里打开「设置 › 远程控制」中的「允许远程桌面」。"))
        }
        let clock = ContinuousClock()
        let started = clock.now
        func millis() -> Int { RemoteConnectTrace.millis(clock.now - started) }
        AppLogger.notice("远程桌面：收到 \(self.peerName) 的开流请求（连接接入后 \(RemoteConnectTrace.millis(clock.now - self.createdAt)) ms）",
                         category: RemoteLog.category)
        // 息屏要等显示器醒来（最多约 3 秒），和授权查询、准备显示器同时进行，不排在它们后面。
        // 准备显示器可能换出别的显示器，下面还会对真正要采的那块再确认一次（醒着时立即返回）。
        let earlyWake = Task { await environment.wakeDisplay(request.displayID ?? CGMainDisplayID()) }
        async let screenAuthorized = environment.screenCaptureAuthorized()
        async let postEventsAuthorized = environment.canPostEvents()
        let (canCapture, canControl) = await (screenAuthorized, postEventsAuthorized)
        let authorizedAt = millis()
        guard generation == desktopStartGeneration, !isClosed else { return }
        guard canCapture else {
            return reject(.screenPermission,
                          String(localized: "Mac 上的 uTerm 还没有「屏幕录制」权限。在 Mac 的「设置 › 远程控制」里授权，并按提示重启 uTerm。"))
        }
        server.rememberDesktopRequest(peerID: peerID, width: request.maxWidth, height: request.maxHeight,
                                      pointScale: request.pointScale)
        await environment.prepareDisplays((request.maxWidth, request.maxHeight), request.pointScale)
        let preparedAt = millis()
        guard generation == desktopStartGeneration, !isClosed else { return }
        guard var display = environment.display(request.displayID) ?? environment.display(nil) else {
            return reject(.captureFailed, String(localized: "找不到 Mac 的显示器"))
        }
        // 息屏时先把显示器叫醒再采集，否则 ScreenCaptureKit 找不到它。等的这会儿可能又来了新请求或断了。
        await earlyWake.value
        await environment.wakeDisplay(display.id)
        // 叫醒时系统可能换掉这块屏（无显示器的 Mac：睡着时放掉的虚拟屏、睡着的占位屏醒来都换成新号）。
        // 按醒来后的再取一次，别拿着已经撤掉的号去采。
        if let awake = environment.display(request.displayID) ?? environment.display(nil) { display = awake }
        AppLogger.notice("远程桌面开流计时：授权 \(authorizedAt) ms · 准备显示器 \(preparedAt) ms · 显示器就绪 \(millis()) ms",
                         category: RemoteLog.category)
        guard generation == desktopStartGeneration, !isClosed else { return }
        // 只看一个窗口：先把它提到最前（盖住的窗口点不到，有时也采不到），再按它此刻的位置和大小当采集目标。
        var windowTitle: String?
        // 上一条流调过大小的窗口：这次还是它、还要调，就留着它最初的位置（结束时还原到那儿）；否则现在就还原。
        // 停流时排着的那次还原先取消：要不要还原、什么时候还原，从这里起由这次开流定，和下面的调大小排着队来。
        windowRestoreTask?.cancel()
        windowRestoreTask = nil
        windowFrontTask?.cancel()
        windowFrontTask = nil
        cancelWindowFitWait()
        if let pending = desktopWindowRestore, pending.id != request.windowID || request.windowFit == nil {
            desktopWindowRestore = nil
            await Self.restoreFittedWindow(pending, server: server)
            guard generation == desktopStartGeneration, !isClosed else { return }
        }
        // 上一条连接没能放回去的同一个窗口（锁着屏时断开）：这次接着调它，结束时放回它最初的位置，
        // 而不是上一次留下的手机大小；也别让解锁后的那次还原把正在看的窗口改走。
        if let windowID = request.windowID, request.windowFit != nil, canControl,
           let frame = server.takePendingWindowRestore(windowID), desktopWindowRestore == nil {
            desktopWindowRestore = (windowID, frame)
        }
        // 独立键鼠：输入直接投给窗口所在的进程，不动 Mac 上的指针，也就不用把窗口提到最前、把 App 变成当前 App。
        let independentInput = request.windowID != nil && request.windowIndependentInput == true && canControl
        // 窗口没调成要的大小、Mac 又锁着屏时：先不发画面，等调好（见 `awaitWindowFit`）。
        var awaitedFit: CGSize?
        if let windowID = request.windowID {
            var resized = false
            if canControl {
                if independentInput {
                    await environment.surfaceWindow(windowID)
                } else {
                    await environment.raiseWindow(windowID)
                }
                if let fit = request.windowFit,
                   let original = await environment.fitWindow(windowID, CGSize(width: fit.width, height: fit.height)) {
                    resized = true
                    if desktopWindowRestore == nil { desktopWindowRestore = (windowID, original) }
                }
            }
            guard generation == desktopStartGeneration, !isClosed else { return }
            guard let window = environment.window(windowID) else {
                return reject(.captureFailed, String(localized: "找不到要看的窗口，它可能已经关闭或挪到了别的桌面"))
            }
            display = window.display
            windowTitle = window.title
            if canControl, let fit = request.windowFit.map({ CGSize(width: $0.width, height: $0.height) }),
               RemoteWindowFitWait.mustWait(fit: fit, window: window.display.bounds.size, resized: resized,
                                            locked: environment.isScreenLocked()) {
                awaitedFit = fit
                AppLogger.notice("远程桌面：Mac 锁着屏，窗口没调成 \(Int(fit.width))×\(Int(fit.height)) 点"
                                 + "（现在 \(Int(window.display.bounds.width))×\(Int(window.display.bounds.height))），"
                                 + "画面先不发，调好再发", category: RemoteLog.category)
            }
        }
        let size = RemoteDesktopGeometry.streamSize(
            displayPixels: CGSize(width: display.pixelWidth, height: display.pixelHeight),
            maxWidth: request.maxWidth, maxHeight: request.maxHeight)
        // 告诉主控端的尺寸：等着调大小时报要调成的那个（主控端第一眼的排版就是最终的），画面随调好的窗口一起到。
        let announced = awaitedFit.map { RemoteWindowFitWait.announced(fit: $0, window: display) } ?? display
        let announcedSize = awaitedFit == nil ? size : RemoteDesktopGeometry.streamSize(
            displayPixels: CGSize(width: announced.pixelWidth, height: announced.pixelHeight),
            maxWidth: request.maxWidth, maxHeight: request.maxHeight)
        if let current = desktop {
            // 换流：调过大小的窗口上面已经处理过了（还原，或留给新的这条流），这里不再还原。
            stopDesktop(channel: current.channel, notify: false, restoresWindow: false)
        }
        let device = peerName
        // 新手机（能解旁路精修帧）+ HEVC：10-bit 主流 + 旁路精修。老手机照旧，免得它把旁路帧当主流解。
        let sidecar = request.codec == .hevc && request.sidecarRefine == true
        let video = request.videoDatagrams == true ? link.videoChannel : nil
        let injector = canControl ? environment.makeInjector(display, independentInput) : nil
        // 按进程投递时 Mac 上的指针不动：主控端的指针跟着注入器自己记的位置走，形状也不取 Mac 上那个指针的。
        let ownsPointer = injector?.virtualPointer != nil
        if display.windowID != nil, canControl {
            AppLogger.info("远程桌面：窗口模式的输入\(ownsPointer ? "直接投给窗口所在的进程（不动 Mac 上的指针）" : "走全局通道（会动 Mac 上的指针）")",
                           category: RemoteLog.category)
        }
        let pointerLocation: (@Sendable () -> CGPoint?)? = ownsPointer
            ? { @Sendable [weak injector] in injector?.virtualPointer } : environment.cursorLocation
        let streamer = RemoteDesktopStreamer(
            link: link, channel: channel, codec: request.codec, width: size.width, height: size.height, display: display,
            sidecarRefine: sidecar, sendsLatency: request.latencyStats == true, path: origin.path, video: video,
            source: environment.makeSource(display, size.width, size.height, sidecar),
            injector: injector,
            cursorLocation: pointerLocation,
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
                        self?.stopDesktop(channel: channel, notify: true, reason: String(localized: "Mac 上的屏幕采集已停止"))
                    }
                }
            })
        if awaitedFit != nil {
            // 在开采集之前挂上：之后采到的帧一张都漏不出去。
            streamer.holdUntilWindowFits()
        }
        desktop = (channel, streamer)
        desktopRoute.set(streamer)
        if let windowID = display.windowID, request.windowKeepFront == true, canControl {
            keepWindowFront(windowID, channel: channel)
        }
        desktopWindowStream = display.windowID.flatMap { canControl ? ($0, request.maxWidth, request.maxHeight) : nil }
        server.claimDesktop(connection: self, channel: channel, canControl: canControl)
        setupScreenControl(channel: channel)
        let info = RemoteDesktopInfo(
            requestID: request.requestID, displayID: display.id,
            displayWidth: announced.bounds.width, displayHeight: announced.bounds.height,
            streamWidth: announcedSize.width, streamHeight: announcedSize.height, codec: request.codec, canControl: canControl,
            controlNote: canControl ? nil : String(localized: "Mac 上还没有给远程控制「辅助功能」权限，只能查看。在 Mac 的 uTerm「设置 › 远程控制」里授权，并按提示重新启动 uTerm，即可控制。"),
            videoDatagrams: video != nil ? true : nil,
            displays: { let all = environment.listDisplays(); return all.isEmpty ? nil : all }(),
            windowID: display.windowID, windowTitle: windowTitle)
        AppLogger.info("远程桌面：\(device) 开始查看，\(size.width)×\(size.height) \(request.codec.rawValue)，可控制 \(canControl)",
                       category: RemoteLog.category)
        Task {
            do {
                try await streamer.start()
            } catch {
                guard desktop?.channel == channel else { return }
                stopDesktop(channel: channel, notify: false)
                reject(.captureFailed, String(localized: "Mac 上的屏幕采集无法启动：\(error.localizedDescription)"))
                return
            }
            guard desktop?.channel == channel, !isClosed else {
                streamer.stop()
                return
            }
            streamer.activate(started: RemoteMessage(.desktopStarted, channel: channel, payload: RemoteJSON.encode(info)))
            // 初始锁屏状态、光标形状排在 `desktopStarted` 之后发：对端要先靠它绑定通道，才接得到后续消息。
            sendScreenState()
            if request.cursorImages == true, !ownsPointer { startCursorShapes(channel: channel) }
        }
        if let awaitedFit, let windowID = display.windowID {
            awaitWindowFit(awaitedFit, windowID: windowID, channel: channel)
        }
    }

    /// 回窗口列表。没开远程桌面、没有屏幕录制授权时回空表加一句原因（没授权时系统不给窗口标题）。
    fileprivate func listDesktopWindows(_ request: RemoteDesktopWindowListRequest) async {
        let environment = server.desktopEnvironment
        func reply(_ windows: [RemoteDesktopWindowSummary], _ message: String? = nil) {
            guard !isClosed else { return }
            link.send(RemoteMessage(.desktopWindowList, payload: RemoteJSON.encode(
                RemoteDesktopWindowList(requestID: request.requestID, windows: windows, message: message))))
        }
        guard environment.isEnabled() else {
            return reply([], String(localized: "Mac 上没有打开远程桌面。在 Mac 的 uTerm 里打开「设置 › 远程控制」中的「允许远程桌面」。"))
        }
        guard await environment.screenCaptureAuthorized() else {
            return reply([], String(localized: "Mac 上的 uTerm 还没有「屏幕录制」权限。在 Mac 的「设置 › 远程控制」里授权，并按提示重启 uTerm。"))
        }
        reply(environment.listWindows())
    }

    /// 主控端的画布变了（转屏、键盘弹出收起）：不停流，把正在看的窗口改成新的大小，流原地换尺寸
    /// （`RemoteDesktopStreamer.retarget`）。排着队做，前一次没改完时不抢。
    private func refitDesktopWindow(_ fit: RemoteDesktopFit, channel: UInt32) {
        if windowFitWait != nil, desktop?.channel == channel {
            // 还在等锁屏解开后调大小：换成新要的大小，到时候按它调。
            pendingWindowFit = CGSize(width: fit.width, height: fit.height)
            return
        }
        let previous = windowRefitTask
        windowRefitTask = Task { [weak self] in
            await previous?.value
            await self?.performWindowRefit(fit, channel: channel)
        }
    }

    private func performWindowRefit(_ fit: RemoteDesktopFit, channel: UInt32) async {
        guard !isClosed, let current = desktop, current.channel == channel, let target = desktopWindowStream else { return }
        let environment = server.desktopEnvironment
        let clock = ContinuousClock()
        let started = clock.now
        // 改窗口大小到新尺寸的第一帧之间的过渡画面一张都不送，主控端停在上一张上，等新的到了一次换完。
        current.streamer.holdForRetarget()
        let fitSize = CGSize(width: fit.width, height: fit.height)
        let original = await environment.fitWindow(target.windowID, fitSize)
        // 第一次改它的大小时记下原来的位置，结束时还原到那儿。
        if let original, desktopWindowRestore == nil {
            desktopWindowRestore = (target.windowID, original)
        }
        guard !isClosed, desktop?.channel == channel, let window = environment.window(target.windowID) else {
            current.streamer.cancelRetargetHold()
            return
        }
        let size = RemoteDesktopGeometry.streamSize(
            displayPixels: CGSize(width: window.display.pixelWidth, height: window.display.pixelHeight),
            maxWidth: target.maxWidth, maxHeight: target.maxHeight)
        AppLogger.info("远程桌面：改窗口大小 \(RemoteConnectTrace.millis(clock.now - started)) ms，流原地换成 \(size.width)×\(size.height)",
                       category: RemoteLog.category)
        current.streamer.retarget(display: window.display, width: size.width, height: size.height)
        // 看着的时候 Mac 锁了屏、手机这时弹出 / 收起键盘：辅助功能改不动，画面照旧按窗口现在的大小走（留黑边），
        // 等解锁了再调（2026-11-27 真机：以前解锁后没人再调，下次连上来窗口还是这一次的大小）。
        if original == nil, environment.isScreenLocked(),
           !RemoteWindowFitWait.fits(fit: fitSize, window: window.display.bounds.size) {
            AppLogger.notice("远程桌面：Mac 锁着屏，窗口没调成 \(Int(fitSize.width))×\(Int(fitSize.height)) 点"
                             + "（现在 \(Int(window.display.bounds.width))×\(Int(window.display.bounds.height))），解锁后再调",
                             category: RemoteLog.category)
            awaitWindowFit(fitSize, windowID: target.windowID, channel: channel)
        }
    }

    /// 开流时窗口没调成要的大小、Mac 又锁着屏（2026-11-25 真机：锁屏 + 息屏时接管 Claude 的窗口，窗口还是
    /// 2304×1204 的原尺寸，手机上下两大条黑边）。辅助功能在锁屏时改不动别的 App 的窗口：那次 37 ms 就失败返回，
    /// 解锁后不会有人再去调。所以画面先冻住（`RemoteDesktopStreamer.holdUntilWindowFits`），隔一会儿看一眼：
    /// 解锁了就调，调成了把流原地换成新尺寸，主控端看到的第一帧就是调好的；解锁后还是调不成（App 不让改）就按窗口
    /// 实际的大小放行，不再等。还锁着时也每隔 `windowFitLockedRetry` 试一次，刚醒来那一下调不动的这样也能接上。
    /// 解锁后头几次也常常调不动（2026-11-27 真机），所以解锁后再试 `RemoteWindowFitWait.unlockGrace` 才放弃。
    ///
    /// 看着的时候锁了屏、原地换尺寸没调成（`performWindowRefit`）也走这里：那时画面没冻住，照旧按窗口现在的大小走。
    ///
    /// 不改走虚拟屏：把窗口挪到虚拟屏上同样要靠辅助功能挪窗口，锁屏时一样挪不动。
    private func awaitWindowFit(_ fit: CGSize, windowID: UInt32, channel: UInt32) {
        windowFitWait?.cancel()
        pendingWindowFit = fit
        windowFitWait = Task { [weak self] in
            let clock = ContinuousClock()
            var lastTry = clock.now
            // 这段等待里最近一次看到解锁的时刻：解锁后头几次常常还调不动，再试 `RemoteWindowFitWait.unlockGrace`。
            var unlockedAt: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.windowFitPollInterval)
                guard !Task.isCancelled, let self, !self.isClosed, self.desktop?.channel == channel else { return }
                let environment = self.server.desktopEnvironment
                let locked = environment.isScreenLocked()
                guard !locked || clock.now - lastTry >= Self.windowFitLockedRetry else { continue }
                lastTry = clock.now
                let target = self.pendingWindowFit ?? fit
                let original = await environment.fitWindow(windowID, target)
                guard !Task.isCancelled, !self.isClosed, let current = self.desktop, current.channel == channel else { return }
                if let original, self.desktopWindowRestore == nil { self.desktopWindowRestore = (windowID, original) }
                guard let window = environment.window(windowID) else {
                    // 窗口没了：放开，采集那头自己会停。
                    self.finishWindowFitWait(streamer: current.streamer, window: nil)
                    return
                }
                let stillLocked = environment.isScreenLocked()
                if stillLocked {
                    unlockedAt = nil
                } else if unlockedAt == nil {
                    unlockedAt = clock.now
                }
                if RemoteWindowFitWait.mustWait(fit: target, window: window.display.bounds.size, resized: original != nil,
                                                locked: stillLocked, unlockedFor: unlockedAt.map { clock.now - $0 }) { continue }
                AppLogger.notice("远程桌面：\(locked ? "锁屏时" : "解锁后")窗口调到了 \(Int(window.display.bounds.width))×"
                                 + "\(Int(window.display.bounds.height)) 点（要 \(Int(target.width))×\(Int(target.height))），开始发画面",
                                 category: RemoteLog.category)
                self.finishWindowFitWait(streamer: current.streamer, window: window.display)
                return
            }
        }
    }

    /// 把为流调过大小的窗口放回去；改不动（锁着屏）就交给服务端，解锁后再放（`RemoteHostServer.restoreWindowLater`）。
    /// 2026-11-27 真机：锁着屏时手机断开，窗口一直留着手机的大小，下次连上来还当成它原来的样子。
    private static func restoreFittedWindow(_ pending: (id: UInt32, frame: CGRect), server: RemoteHostServer) async {
        guard await !server.desktopEnvironment.restoreWindow(pending.id, pending.frame) else { return }
        server.restoreWindowLater(pending.id, frame: pending.frame)
    }

    /// 不等了：流原地换成窗口现在的大小（`retarget` 放开冻结，下一张新尺寸的画面就是第一帧）。
    private func finishWindowFitWait(streamer: RemoteDesktopStreamer, window: RemoteDesktopDisplay?) {
        windowFitWait = nil
        pendingWindowFit = nil
        guard let window else {
            streamer.cancelRetargetHold()
            return
        }
        if let target = desktopWindowStream {
            let size = RemoteDesktopGeometry.streamSize(
                displayPixels: CGSize(width: window.pixelWidth, height: window.pixelHeight),
                maxWidth: target.maxWidth, maxHeight: target.maxHeight)
            streamer.retarget(display: window, width: size.width, height: size.height)
        } else {
            streamer.cancelRetargetHold()
        }
    }

    private func cancelWindowFitWait() {
        windowFitWait?.cancel()
        windowFitWait = nil
        pendingWindowFit = nil
    }

    /// 这条流还在的时候把窗口保持在最前：每隔 `windowFrontInterval` 看一眼，它的 App 不是当前 App 了就再提一次。
    /// 被别的 App 盖住的窗口 macOS 不让它重绘，画面就停在最后一帧（2026-11-18 user 反馈）。
    private func keepWindowFront(_ windowID: UInt32, channel: UInt32) {
        windowFrontTask?.cancel()
        windowFrontTask = Task { [weak self] in
            var raises = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.windowFrontInterval)
                guard !Task.isCancelled, let self, !self.isClosed, self.desktop?.channel == channel else { return }
                let environment = self.server.desktopEnvironment
                guard !environment.windowAppIsFront(windowID) else { continue }
                raises += 1
                // 头几次每次都记，之后每 30 次记一行。
                if raises <= 3 || raises % 30 == 0 {
                    AppLogger.info("远程桌面：正在看的窗口退到了后面，重新提到最前（第 \(raises) 次）", category: RemoteLog.category)
                }
                await environment.raiseWindow(windowID)
            }
        }
    }

    /// 结束桌面流。`notify` = 告诉手机（Mac 上断开、被别的设备接管、采集停了）。
    func stopDesktop(channel: UInt32, notify: Bool, reason: String = "", restoresWindow: Bool = true) {
        guard let current = desktop, current.channel == channel else { return }
        windowFrontTask?.cancel()
        windowFrontTask = nil
        cancelWindowFitWait()
        desktopWindowStream = nil
        if restoresWindow, desktopWindowRestore != nil {
            // 为这条流调过大小的窗口放回去——等一小会儿，主控端马上按新尺寸再开同一个窗口时就不用折腾了。
            windowRestoreTask?.cancel()
            windowRestoreTask = Task { [weak self] in
                try? await Task.sleep(for: Self.windowRestoreGrace)
                guard !Task.isCancelled, let self, let pending = self.desktopWindowRestore else { return }
                self.desktopWindowRestore = nil
                self.windowRestoreTask = nil
                await Self.restoreFittedWindow(pending, server: self.server)
            }
        }
        stopAudio(notify: nil)
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

// MARK: - 声音

extension RemoteHostConnection {
    /// 手机打开了扬声器：开一条声音流。先发格式，之后的声音包按它解。开不起来（Mac 上关了开关、编码器或采集起不来）
    /// 回一条没有编码的格式，带上原因，桌面流不受影响。
    fileprivate func startAudio(_ request: RemoteDesktopAudioRequest, channel: UInt32, generation: Int) async {
        guard generation == audioRequestGeneration, let current = desktop, current.channel == channel,
              peerSupportsAudio else { return }
        stopAudio(notify: nil)
        let stream = audioStreams.next()
        let environment = server.desktopEnvironment
        func refuse(_ message: String) {
            link.send(RemoteMessage(.desktopAudioFormat, channel: channel, payload: RemoteJSON.encode(
                RemoteDesktopAudioFormat(stream: stream, codec: nil, message: message))))
        }
        guard environment.isAudioEnabled(), let makeSource = environment.makeAudioSource else {
            return refuse(String(localized: "Mac 上没有打开「允许传输声音」。在 Mac 的 uTerm 里打开「设置 › 远程控制 › 允许传输声音」"))
        }
        let display = current.streamer.display
        let numbers = audioStreams
        let streamer = RemoteAudioStreamer(
            link: link, channel: channel, stream: stream, codecs: request.codecs,
            nextStream: { numbers.next() },
            linkInfo: Self.audioLinkInfo(link: link, path: origin.path, video: current.streamer,
                                         lossless: peerSupportsAudioLossless),
            datagrams: current.streamer.datagramChannel,
            source: makeSource(display),
            onSourceStopped: { [weak self] error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AppLogger.info("远程桌面声音采集停止：\(error?.localizedDescription ?? "无错误")", category: RemoteLog.category)
                        self?.stopAudio(notify: String(localized: "Mac 上的声音采集已停止"))
                    }
                }
            })
        audio = streamer
        do {
            let format = try await streamer.start()
            // 等采集起来的这段时间里，桌面流可能结束了、声音可能又被关了。
            guard audio === streamer, desktop?.channel == channel, !isClosed else {
                streamer.stop()
                return
            }
            link.send(RemoteMessage(.desktopAudioFormat, channel: channel, payload: RemoteJSON.encode(format)))
            server.desktopAudioChanged(connection: self, channel: channel, on: true)
            AppLogger.info("远程桌面：开始向 \(self.peerName) 传输声音（\(streamer.codec.rawValue)）", category: RemoteLog.category)
        } catch {
            guard audio === streamer else { return }
            audio = nil
            streamer.stop()
            if case RemoteAudioStreamerError.noCodec = error {
                refuse(String(localized: "Mac 无法编码手机支持的声音格式"))
            } else {
                refuse(String(localized: "Mac 上的声音采集无法启动：\(error.localizedDescription)"))
            }
        }
    }

    /// 声音档位要的链路情况（在连接队列上调）。直连走数据报时用发送节奏与丢包率；局域网 TCP 没有节奏，
    /// 用画面编码器眼下的码率当容量（画面码控对局域网的估计）；中继给固定档。
    static func audioLinkInfo(link: RemoteLink, path: RemoteLinkPath, video: RemoteDesktopStreamer,
                              lossless: Bool) -> () -> RemoteAudioPolicy.Link {
        let datagrams = video.datagramChannel != nil
        let stats = video.stats
        return {
            if datagrams, let state = link.datagramLinkState {
                return RemoteAudioPolicy.Link(path: .direct, capacity: state.pacingRate * 8, lossRate: state.lossRate,
                                              peerDecodesLossless: lossless)
            }
            if path == .relay { return RemoteAudioPolicy.Link(path: .relay) }
            let bitrate = stats.snapshot().bitrate
            return RemoteAudioPolicy.Link(path: .localNetwork, capacity: bitrate > 0 ? Double(bitrate) : nil,
                                          peerDecodesLossless: lossless)
        }
    }

    /// 停掉声音。`notify` 不为 nil 时告诉手机原因（它会把扬声器按钮复位并提示）。
    func stopAudio(notify reason: String?) {
        guard let streamer = audio else { return }
        audio = nil
        streamer.stop()
        server.desktopAudioChanged(connection: self, channel: streamer.channel, on: false)
        if let reason {
            link.send(RemoteMessage(.desktopAudioFormat, channel: streamer.channel, payload: RemoteJSON.encode(
                RemoteDesktopAudioFormat(stream: streamer.stream, codec: nil, message: reason))))
        }
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
            self.stopDesktop(channel: channel, notify: true, reason: String(localized: "已在 Mac 上解除帘幕"))
        }
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            let observer = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendScreenState() }
            }
            lockObservers.append(observer)
        }
        if peerSupportsAuthPrompt { watchAuthPrompts(controller) }
    }

    /// 验证框没有系统通知可听，每半秒看一次屏上的窗口表（几毫秒），框出现 / 消失 / 换了一个就推新状态。
    private func watchAuthPrompts(_ controller: any RemoteScreenController) {
        authPromptWatch?.cancel()
        lastAuthPrompt = controller.currentAuthPrompt()
        authPromptWatch = Task { [weak self, weak controller] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.authPromptPollInterval)
                guard let self, let controller, !Task.isCancelled else { return }
                let prompt = controller.isLocked ? nil : controller.currentAuthPrompt()
                guard prompt != self.lastAuthPrompt else { continue }
                if let prompt {
                    AppLogger.info("远程桌面：Mac 上出现验证框（\(prompt.kind.rawValue)）", category: RemoteLog.category)
                }
                self.sendScreenState()
            }
        }
    }

    static let authPromptPollInterval: Duration = .milliseconds(500)

    private func teardownScreenControl() {
        authPromptWatch?.cancel()
        authPromptWatch = nil
        lastAuthPrompt = nil
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
        var state = RemoteDesktopScreenState(
            locked: controller.isLocked, curtained: controller.isCurtained,
            unlockAvailable: server.desktopEnvironment.isUnlockEnabled() && (server.desktopViewer?.canControl ?? false))
        if peerSupportsAuthPrompt {
            // 锁屏上不会有这类框；即使有也先解锁。
            state.authPrompt = state.locked ? nil : controller.currentAuthPrompt()
            lastAuthPrompt = state.authPrompt
        }
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
        // 帘幕开着时注入的按键进不了锁屏密码框（2026-11-09 真机实测，见 `RemoteUnlockTypist`）：打字时撤掉，
        // 打完密码、按回车之前再挂上——锁屏一消失物理屏已经是黑的，不会闪出桌面。打字期间物理屏上看到的只是锁屏。
        let wasCurtained = controller.isCurtained
        if wasCurtained { controller.setCurtain(false) }
        Task {
            let attempt = await controller.unlock(password: password) { controller.setCurtain(true) }
            let success = attempt == .unlocked
            unlockInFlight = false
            guard !isClosed, desktop?.channel == channel else {
                // 手机在解锁过程中走了：解开了就锁回去，别把已解锁的桌面晾在那里。
                if success { controller.lockScreen() }
                if controller.isCurtained != wasCurtained { controller.setCurtain(wasCurtained) }
                return
            }
            if success {
                // 中途被 Mac 前的人解开时没走到回车那一步，这里补上帘幕。
                if !controller.isCurtained { controller.setCurtain(true) }
                remotelyUnlocked = true
                AppLogger.info("远程桌面：解锁成功，已进入帘幕", category: RemoteLog.category)
            } else {
                // 没解开：恢复解锁前的帘幕状态，Mac 前的人还能看到锁屏。
                if controller.isCurtained != wasCurtained { controller.setCurtain(wasCurtained) }
                AppLogger.info(attempt == .inputBlocked ? "远程桌面：解锁未进行（有程序占着键盘）"
                                                        : "远程桌面：解锁未成功（输完密码仍锁着）", category: RemoteLog.category)
            }
            reply(Self.unlockOutcome(attempt, peerKnowsBlocked: peerSupportsUnlockOutcomes))
            sendScreenState()
        }
    }

    /// 回应屏上的验证框。和远程解锁同一道门：开了「允许远程解锁」、是正在看屏幕且能控制的那一路。
    fileprivate func handleAuthPrompt(_ request: RemoteDesktopAuthPromptRequest, password: String?, channel: UInt32) {
        func reply(_ outcome: RemoteDesktopAuthPromptResult.Outcome) {
            link.send(RemoteMessage(.desktopAuthPromptResult, channel: channel, payload: RemoteJSON.encode(
                RemoteDesktopAuthPromptResult(requestID: request.requestID, outcome: outcome))))
        }
        guard peerSupportsAuthPrompt, canUnlockRemotely(channel: channel), !authPromptInFlight, !unlockInFlight,
              let controller = server.screenController else { return reply(.notAllowed) }
        guard !controller.isLocked else { return reply(.gone) }
        if request.action == .fill, password?.isEmpty ?? true { return reply(.notFocused) }
        AppLogger.info("远程桌面：\(self.peerName) 回应 Mac 上的验证框（\(request.action.rawValue)）",
                       category: RemoteLog.category)
        authPromptInFlight = true
        Task {
            let attempt = await controller.answerAuthPrompt(id: request.promptID, action: request.action,
                                                            password: password)
            authPromptInFlight = false
            AppLogger.info("远程桌面：验证框回应结果 \(String(describing: attempt))", category: RemoteLog.category)
            guard !isClosed, desktop?.channel == channel else { return }
            reply(Self.authPromptOutcome(attempt))
            sendScreenState()
        }
    }

    nonisolated static func authPromptOutcome(_ attempt: RemoteAuthPromptAttempt) -> RemoteDesktopAuthPromptResult.Outcome {
        switch attempt {
        case .accepted: .accepted
        case .rejected: .rejected
        case .cancelled: .cancelled
        case .gone: .gone
        case .notFocused: .notFocused
        }
    }

    /// 解锁结果怎么告诉对端：老对端不认 `inputBlocked`，退回 `stillLocked`。
    nonisolated static func unlockOutcome(_ attempt: RemoteUnlockAttempt,
                                          peerKnowsBlocked: Bool) -> RemoteDesktopUnlockResult.Outcome {
        switch attempt {
        case .unlocked: .unlocked
        case .stillLocked: .stillLocked
        case .inputBlocked: peerKnowsBlocked ? .inputBlocked : .stillLocked
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
    private var subscribers: [(channel: UInt32, subscriber: any RemoteTerminalFeed)] = []
    private var cursor = 0

    init(link: RemoteLink) {
        self.link = link
    }

    func add(channel: UInt32, feed: any RemoteTerminalFeed) {
        link.queue.async {
            self.subscribers.append((channel, feed))
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
                guard let chunk = subscriber.take(maxBytes: RemoteConstants.maxOutputChunkBytes) else { continue }
                switch chunk {
                case .output(let bytes):
                    link.sendOnQueue(RemoteMessage(.output, channel: channel, payload: bytes))
                case .snapshot(let piece, let isFirst, let isLast):
                    link.sendOnQueue(RemoteMessage(.terminalSnapshot, channel: channel,
                                                   payload: RemoteTerminalSnapshotPiece.encode(piece, isFirst: isFirst, isLast: isLast)))
                }
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

/// 声音流号的计数器（加锁：连接在主线程上开新流，声音发送端在连接队列上换档）。
nonisolated final class RemoteAudioStreamNumbers: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16 = 0

    func next() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }
}
