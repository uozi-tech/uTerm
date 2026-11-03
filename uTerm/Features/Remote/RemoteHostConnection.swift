import CryptoKit
import Foundation

/// Mac 端一台已连上的远控设备：握手、配对审批、会话列表、接入 / 断开、输入、尺寸。
///
/// 收到的消息从连接队列按先后顺序跳回主线程处理（`DispatchQueue.main` 是先进先出的，按键顺序
/// 不会乱）。输出则反过来：镜像订阅者有新字节时，在连接队列上直接取、合并、加密、发送，
/// 不经过主线程。
@MainActor
final class RemoteHostConnection {
    let id = UUID()
    private let link: RemoteLink
    private unowned let server: RemoteHostServer
    private let pump: RemoteOutputPump

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
    }

    func start() {
        let pump = self.pump
        link.setHandlers(
            onMessage: { [weak self] message in
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
                                    staticKey: staticKey.publicKey.rawRepresentation)
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
        case .sessions, .attached, .output, .closed, .pong, .pairing:
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
        server.connectionClosed(self)
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
