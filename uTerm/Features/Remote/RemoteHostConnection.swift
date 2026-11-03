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
    private(set) var isAuthorized = false
    private var subscribedToSessions = false
    private var isClosed = false
    private var nextChannel: UInt32 = 1
    private var attachments: [UInt32: Attachment] = [:]

    private struct Attachment {
        let sessionID: UUID
        weak var session: TerminalSession?
        let subscriberID: UUID
    }

    init(link: RemoteLink, server: RemoteHostServer) {
        self.link = link
        self.server = server
        self.pump = RemoteOutputPump(link: link)
        self.desktopRoute = RemoteDesktopRoute(queue: link.queue)
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
        Task { await handshake() }
    }

    func close() {
        link.close()
    }

    // MARK: - 握手与配对

    private func handshake() async {
        do {
            let staticKey = try server.identity.localIdentity()
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: server.localID,
                                    deviceName: server.localName, ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                    staticKey: staticKey.publicKey.rawRepresentation,
                                    features: server.localFeatures.isEmpty ? nil : server.localFeatures)
            let established = try await link.establish(role: .responder, hello: hello, staticKey: staticKey,
                                                       ephemeralKey: ephemeral)
            let peer = established.peer
            peerName = peer.deviceName
            peerID = peer.deviceID
            if let trusted = server.identity.peer(id: peer.deviceID), trusted.publicKey == peer.staticKey {
                authorize(.trusted)
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
            try server.trust(RemotePeer(id: peer.deviceID, name: peer.deviceName, publicKey: peer.staticKey,
                                        pairedAt: Date()))
            authorize(.approved)
        } catch {
            AppLogger.info("远控握手失败：\(error.localizedDescription)", category: RemoteLog.category)
            link.close(error)
        }
    }

    private func authorize(_ state: RemotePairingState) {
        isAuthorized = true
        sendPairing(state)
        server.connectionAuthorized(self)
    }

    private func sendPairing(_ state: RemotePairingState) {
        link.send(RemoteMessage(.pairing, payload: Data([state.rawValue])))
    }

    // MARK: - 消息

    private func handle(_ message: RemoteMessage) {
        // 审批通过之前，对端说什么都不理。
        guard isAuthorized, !isClosed else { return }
        switch message.kind {
        case .subscribeSessions:
            subscribedToSessions = true
            sendSessions()
        case .attach:
            guard let request = try? RemoteJSON.decode(RemoteAttachRequest.self, from: message.payload) else { return }
            attach(request)
        case .input:
            attachments[message.channel]?.session?.writeRemoteInput(message.payload)
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
            startDesktop(request)
        case .desktopStop:
            stopDesktop(channel: message.channel, notify: false)
        case .desktopAck, .desktopInput, .desktopKeyframe, .desktopPaste:
            // 已在连接队列上交给发送端（`RemoteDesktopRoute`），不会走到这里。
            break
        case .sessions, .attached, .output, .closed, .pong, .pairing, .desktopStarted, .desktopFrame, .desktopCursor,
             .localShellOpened, .terminalImageResult:
            break
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
                    reply.error = "图片没传过去：\(error.localizedDescription)"
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
            let result = await opener.open()
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
    fileprivate func startDesktop(_ request: RemoteDesktopStartRequest) {
        let channel = nextChannel
        nextChannel &+= 1
        let environment = server.desktopEnvironment
        func reject(_ failure: RemoteDesktopInfo.Failure, _ message: String) {
            link.send(RemoteMessage(.desktopStarted, channel: channel, payload: RemoteJSON.encode(
                RemoteDesktopInfo(requestID: request.requestID, failure: failure, message: message))))
        }
        guard environment.isEnabled() else {
            return reject(.disabled, "Mac 上没有打开远程桌面。请在 Mac 的 uTerm 里打开 设置 › 远程控制 › 允许远程桌面")
        }
        guard environment.screenCaptureAuthorized() else {
            return reject(.screenPermission,
                          "Mac 上的 uTerm 还没有屏幕录制权限。请在 Mac 的 设置 › 远程控制 里授权，并按提示重启 uTerm")
        }
        guard let display = environment.display(request.displayID) ?? environment.display(nil) else {
            return reject(.captureFailed, "找不到 Mac 的显示器")
        }
        let size = RemoteDesktopGeometry.streamSize(
            displayPixels: CGSize(width: display.pixelWidth, height: display.pixelHeight),
            maxWidth: request.maxWidth, maxHeight: request.maxHeight)
        let canControl = environment.canPostEvents()
        if let current = desktop {
            stopDesktop(channel: current.channel, notify: false)
        }
        let device = peerName
        let streamer = RemoteDesktopStreamer(
            link: link, channel: channel, codec: request.codec, width: size.width, height: size.height, display: display,
            source: environment.makeSource(display, size.width, size.height),
            injector: canControl ? environment.makeInjector(display) : nil,
            cursorLocation: environment.cursorLocation,
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
        let info = RemoteDesktopInfo(
            requestID: request.requestID, displayID: display.id,
            displayWidth: display.bounds.width, displayHeight: display.bounds.height,
            streamWidth: size.width, streamHeight: size.height, codec: request.codec, canControl: canControl,
            controlNote: canControl ? nil : "Mac 上的 uTerm 没有「辅助功能」权限，只能查看。在 Mac 的 设置 › 远程控制 里授权后重启 uTerm 即可控制")
        AppLogger.info("远程桌面：\(device) 开始查看，\(size.width)×\(size.height) \(request.codec.rawValue)，可控制 \(canControl)",
                       category: RemoteLog.category)
        Task {
            do {
                try await streamer.start()
            } catch {
                guard desktop?.channel == channel else { return }
                stopDesktop(channel: channel, notify: false)
                reject(.captureFailed, "Mac 上的屏幕采集没能启动：\(error.localizedDescription)")
                return
            }
            guard desktop?.channel == channel, !isClosed else {
                streamer.stop()
                return
            }
            streamer.activate(started: RemoteMessage(.desktopStarted, channel: channel, payload: RemoteJSON.encode(info)))
        }
    }

    /// 结束桌面流。`notify` = 告诉手机（Mac 上断开、被别的设备接管、采集停了）。
    func stopDesktop(channel: UInt32, notify: Bool, reason: String = "") {
        guard let current = desktop, current.channel == channel else { return }
        desktop = nil
        desktopRoute.set(nil)
        current.streamer.stop()
        server.releaseDesktop(connection: self, channel: channel)
        if notify {
            link.send(RemoteMessage(.closed, channel: channel, payload: Data(reason.utf8)))
        }
    }
}

/// 把镜像订阅者的积压搬上网：合并、加密、发送，全在连接队列上做。
///
/// 每次最多取 `maxOutputChunkBytes`，各通道轮流取；网络栈里在途的字节超过上限就停手，
/// 等 `onWritable` 再继续。停手期间积压留在订阅者那里，超过它的上限就会被换成快照。
nonisolated final class RemoteOutputPump: @unchecked Sendable {
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

    func drainOnQueue() {
        dispatchPrecondition(condition: .onQueue(link.queue))
        guard !subscribers.isEmpty else { return }
        while link.canSendMore {
            var sentAny = false
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

nonisolated enum RemoteLog {
    static let category = "remote"
}
