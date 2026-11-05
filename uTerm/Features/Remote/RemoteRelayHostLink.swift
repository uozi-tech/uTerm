import CryptoKit
import Foundation
import Observation

/// Mac 在中继上的注册：保持一条出站控制连接，回应手机的信令，手机要走中继时回拨。
///
/// 连接进来后交给 `RemoteHostServer.accept(transport:origin:)`，后面的握手和业务都与局域网相同。
@MainActor
@Observable
final class RemoteRelayHostLink {
    enum State: Equatable {
        case connecting
        case registered
        case failed(String)
        /// 另一台机器用同样的身份注册了，互相顶替没有意义，不再自动重连。
        case superseded
        case stopped
    }

    private(set) var state = State.connecting

    @ObservationIgnored let config: RemoteRelayConfig
    @ObservationIgnored private weak var server: RemoteHostServer?
    @ObservationIgnored private var responder: RemoteSignalResponder?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var control: RemoteRelayConnection?
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var retryDelay: Duration = .seconds(1)
    @ObservationIgnored private var retryWake: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var callbacksInFlight = 0
    @ObservationIgnored private var networkWatcher: RemoteNetworkWatcher?
    @ObservationIgnored private let pingInterval: Duration
    @ObservationIgnored private let pongTimeout: TimeInterval

    private static let maxCallbacksInFlight = 4
    private static let maxProbesInFlight = 4
    @ObservationIgnored private var probesInFlight = 0
    /// 测试用：当它是还不会打洞的旧版本。
    @ObservationIgnored var acceptsDirect = true

    init(config: RemoteRelayConfig, server: RemoteHostServer, pingInterval: Duration = .seconds(60),
         pongTimeout: TimeInterval = 20) {
        self.config = config
        self.server = server
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
    }

    func start() {
        guard runner == nil else { return }
        state = .connecting
        // 换了网络，旧连接多半已经死了；等 keepalive 报错要半分钟。
        networkWatcher = RemoteNetworkWatcher { [weak self] isSatisfied in
            if isSatisfied { self?.reconnectNow() }
        }
        runner = Task { [weak self] in await self?.run() }
    }

    func stop() {
        runner?.cancel()
        runner = nil
        heartbeat?.cancel()
        heartbeat = nil
        networkWatcher = nil
        control?.close()
        control = nil
        wakeRetry()
        state = .stopped
    }

    /// 测试用：模拟控制连接断开。
    func dropConnectionForTesting() {
        state = .connecting
        control?.close()
    }

    private func reconnectNow() {
        retryDelay = .seconds(1)
        wakeRetry()
        if state != .registered { return }
        control?.close()
    }

    private func wakeRetry() {
        retryWake?.resume()
        retryWake = nil
    }

    // MARK: - 注册

    private func run() async {
        while !Task.isCancelled {
            do {
                try await registerAndServe()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if case RemoteRelayError.refused(let reason) = error, reason == "superseded" {
                    state = .superseded
                    return
                }
                state = .failed(error.localizedDescription)
                AppLogger.info("中继注册断开：\(error.localizedDescription)", category: RemoteLog.category)
            }
            await waitBeforeRetry()
            retryDelay = min(retryDelay * 2, .seconds(60))
        }
    }

    private func waitBeforeRetry() async {
        let delay = retryDelay
        let sleeper = Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.wakeRetry()
        }
        await withCheckedContinuation { continuation in
            retryWake = continuation
        }
        sleeper.cancel()
    }

    private func registerAndServe() async throws {
        guard let server, let memberKey = config.memberKey else { throw RemoteRelayError.notConfigured }
        let identity = server.identity
        let hostKey = try identity.relayHostKey()
        let hostID = server.localID.uuidString
        let connection = RemoteRelayConnection(config: config)
        control = connection
        defer {
            connection.close()
            if control === connection { control = nil }
            heartbeat?.cancel()
            heartbeat = nil
        }
        state = state == .registered ? .connecting : state
        let hello = try await connection.open()
        try await connection.send(RemoteRelayRequest(
            role: "host", hostID: hostID,
            hostKey: hostKey.publicKey.derRepresentation.base64EncodedString(),
            sig: try RemoteRelaySignature.sign(memberKey, role: "host", relayID: config.relayID, nonce: hello.nonce,
                                               parameter: hostID),
            hostSig: try RemoteRelaySignature.sign(hostKey, role: "host", relayID: config.relayID, nonce: hello.nonce,
                                                   parameter: hostID)))
        let answer: RemoteRelayAnswer = try await connection.receive()
        guard answer.ok else { throw RemoteRelayError.refused(answer.reason ?? "") }

        responder = RemoteSignalResponder(
            localKey: try identity.localIdentity(), localID: server.localID,
            recognize: { [weak server] id in MainActor.assumeIsolated { server?.knownPeer(id: id) } },
            isAllowed: { [weak server] id in MainActor.assumeIsolated { server?.allowsInternetAccess(id) ?? false } })
        state = .registered
        retryDelay = .seconds(1)
        lastHeard = Date()
        startHeartbeat(connection)

        while !Task.isCancelled {
            let message: RemoteRelayMessage = try await connection.receive(timeout: nil)
            lastHeard = Date()
            switch message.type {
            case "signal": await handleSignal(message, on: connection)
            case "incoming": handleIncoming(message)
            case "ping": try await connection.send(RemoteRelayMessage(type: "pong"))
            case "superseded": throw RemoteRelayError.refused("superseded")
            default: break
            }
        }
        throw CancellationError()
    }

    private func startHeartbeat(_ connection: RemoteRelayConnection) {
        heartbeat?.cancel()
        let interval = pingInterval
        let timeout = pongTimeout
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                let asked = Date()
                try? await connection.send(RemoteRelayMessage(type: "ping"))
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self else { return }
                // 只有中继本身的回答才算数：反向代理会替它回 TCP keepalive。
                if self.lastHeard < asked {
                    connection.close()
                    return
                }
            }
        }
    }

    // MARK: - 信令

    private func handleSignal(_ message: RemoteRelayMessage, on connection: RemoteRelayConnection) async {
        guard let session = message.session else { return }
        let now = Date().timeIntervalSince1970
        let canTryDirect = acceptsDirect && probesInFlight < Self.maxProbesInFlight
        switch responder?.receiveOffer(session: session, from: message.from, box: message.box, now: now,
                                       acceptsDirect: canTryDirect) {
        case .reply(let reply):
            try? await connection.send(RemoteRelayMessage(type: "signal", session: session, box: reply))
            return
        case .direct(let offer):
            startDirect(offer, session: session, connection: connection)
            return
        case .ignore, nil:
            break
        }
        switch responder?.receiveProbe(session: session, from: message.from, box: message.box, now: now) {
        case .denied(let reply):
            try? await connection.send(RemoteRelayMessage(type: "signal", session: session, box: reply))
        case .accepted(let request):
            startProbe(request, session: session, connection: connection)
        case .ignore, nil:
            break
        }
    }

    private func startProbe(_ request: RemoteSignalResponder.ProbeRequest, session: String,
                            connection: RemoteRelayConnection) {
        guard probesInFlight < Self.maxProbesInFlight, let localID = server?.localID else { return }
        probesInFlight += 1
        let stunHost = config.host
        let stunPort = UInt16(clamping: config.port)
        Task { [weak self] in
            await RemoteICEProbeResponder.serve(request: request, session: session, localID: localID, stunHost: stunHost,
                                                stunPort: stunPort) { reply in
                try? await connection.send(RemoteRelayMessage(type: "signal", session: session, box: reply))
            }
            self?.probesInFlight -= 1
        }
    }

    // MARK: - 直连

    /// 不能阻塞控制连接：收集地址要时间，这期间别的手机也可能在打招呼。
    private func startDirect(_ offer: RemoteSignalResponder.DirectOffer, session: String,
                             connection: RemoteRelayConnection) {
        probesInFlight += 1
        Task { [weak self] in
            await self?.serveDirect(offer, session: session, connection: connection)
            self?.probesInFlight -= 1
        }
    }

    private func serveDirect(_ offer: RemoteSignalResponder.DirectOffer, session: String,
                             connection: RemoteRelayConnection) async {
        // 中继那条路已经备好（`receiveOffer` 登记过）。这里任何一步不成，回一个不带地址的答复手机就走中继。
        let attempt = RemoteDirectAttempt(stunHost: config.host, stunPort: UInt16(clamping: config.port))
        // 先设对端，这一端才是 controlled；地址一出来就开始往手机打。
        var description: String?
        if let attempt, attempt.setRemote(offer.remoteDescription), attempt.gather() {
            await attempt.waitForGathering(limit: RemoteDirectAttempt.gatherLimit)
            description = attempt.localDescription()
        }
        guard let reply = offer.sealedReply(ice: description, session: session) else {
            attempt?.close()
            return
        }
        try? await connection.send(RemoteRelayMessage(type: "signal", session: session, box: reply))
        guard let attempt, description != nil else {
            attempt?.close()
            return
        }
        // 打洞要几秒。这期间用户可能关了公网接入，或者取消了这台设备的勾选。
        guard await attempt.waitForCheck(keys: offer.directKeys.check), runner != nil, let server,
              server.allowsInternetAccess(offer.peer.id),
              let transport = attempt.makeTransport(keys: offer.directKeys.datagram) else {
            attempt.close()
            return
        }
        server.accept(transport: transport,
                      origin: .internet(peerID: offer.peer.id, keys: offer.handshakeKeys, path: .direct))
        try? await Task.sleep(for: RemoteDirectAttempt.hostAnswerLinger)
        withExtendedLifetime(attempt) {}
    }

    private func handleIncoming(_ message: RemoteRelayMessage) {
        guard let session = message.session, let ticket = message.ticket,
              let pending = responder?.claim(session: session, now: Date().timeIntervalSince1970),
              callbacksInFlight < Self.maxCallbacksInFlight else { return }
        callbacksInFlight += 1
        Task { [weak self] in
            defer { self?.callbacksInFlight -= 1 }
            do {
                try await self?.callBack(ticket: ticket, pending: pending)
            } catch {
                AppLogger.info("中继回拨失败：\(error.localizedDescription)", category: RemoteLog.category)
            }
        }
    }

    private func callBack(ticket: String, pending: RemoteSignalResponder.PendingSession) async throws {
        guard let server else { return }
        let hostKey = try server.identity.relayHostKey()
        let connection = RemoteRelayConnection(config: config)
        do {
            let hello = try await connection.open()
            try await connection.send(RemoteRelayRequest(
                role: "accept", ticket: ticket,
                hostSig: try RemoteRelaySignature.sign(hostKey, role: "accept", relayID: config.relayID,
                                                       nonce: hello.nonce, parameter: ticket)))
            let answer: RemoteRelayAnswer = try await connection.receive()
            guard answer.ok else { throw RemoteRelayError.refused(answer.reason ?? "") }
        } catch {
            connection.close()
            throw error
        }
        server.accept(transport: connection.detach(),
                      origin: .internet(peerID: pending.peer.id, keys: pending.keys, path: .relay))
    }
}
