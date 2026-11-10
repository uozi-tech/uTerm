import AppKit
import CryptoKit
import Foundation
import Observation

/// 被顶替（另一台机器用这台 Mac 的身份注册了中继）之后多久再注册：5 分钟起、每次翻倍、最多 1 小时。
///
/// 被顶替多半是同一台 Mac 上一个短命的开发构建，它退出后这台得自己回来；但也可能是两台真机共用一个身份
///（克隆的磁盘、迁移过来的 Mac），那样互相顶的间隔至少是这个下限，并且越来越长，不会每几秒抢一次。
nonisolated struct RemoteRelaySupersededBackoff: Equatable, Sendable {
    static let standard = RemoteRelaySupersededBackoff(initial: .seconds(300), maximum: .seconds(3600))

    let initial: Duration
    let maximum: Duration
    private(set) var next: Duration

    init(initial: Duration, maximum: Duration) {
        self.initial = initial
        self.maximum = maximum
        next = initial
    }

    /// 这次被顶替后等多久；下一次翻倍。
    mutating func take() -> Duration {
        let delay = next
        next = min(next * 2, maximum)
        return delay
    }

    mutating func reset() { next = initial }
}

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
        /// 另一台机器用同样的身份注册了：按 `RemoteRelaySupersededBackoff` 隔一阵再注册，
        /// 换网络、唤醒或在设置里点「重新连接」时立刻再试。
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
    @ObservationIgnored private var supersededBackoff: RemoteRelaySupersededBackoff
    /// 这次注册上的时间。注册稳定够久（一个退避上限）再被顶替，退避从头算。
    @ObservationIgnored private var registeredSince: Date?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private static let maxCallbacksInFlight = 4
    private static let maxProbesInFlight = 4
    @ObservationIgnored private var probesInFlight = 0
    /// 测试用：当它是还不会打洞的旧版本。
    @ObservationIgnored var acceptsDirect = true

    init(config: RemoteRelayConfig, server: RemoteHostServer, pingInterval: Duration = .seconds(60),
         pongTimeout: TimeInterval = 20, supersededBackoff: RemoteRelaySupersededBackoff = .standard) {
        self.config = config
        self.server = server
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.supersededBackoff = supersededBackoff
    }

    func start() {
        guard runner == nil else { return }
        state = .connecting
        // 换了网络，旧连接多半已经死了；等 keepalive 报错要半分钟。
        networkWatcher = RemoteNetworkWatcher { [weak self] snapshot in
            if snapshot.isSatisfied { self?.reconnectNow() }
        }
        // 睡醒时连接多半已经死了；被顶替时也趁这一下再试一次。
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectNow() }
        }
        runner = Task { [weak self] in await self?.run() }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// 设置里的「重新连接」：立刻再注册，被顶替的退避从头算。
    func reconnect() {
        supersededBackoff.reset()
        if runner == nil {
            start()
            return
        }
        reconnectNow()
    }

    func stop() {
        runner?.cancel()
        runner = nil
        heartbeat?.cancel()
        heartbeat = nil
        networkWatcher = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
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
                    if let since = registeredSince, Date().timeIntervalSince(since) >= Self.seconds(supersededBackoff.maximum) {
                        supersededBackoff.reset()
                    }
                    registeredSince = nil
                    let delay = supersededBackoff.take()
                    let endpoint = config.endpointDescription
                    AppLogger.notice("中继注册被顶替：另一台机器用这台 Mac 的身份注册了 \(endpoint)，"
                                     + "\(Int(Self.seconds(delay).rounded())) 秒后再注册", category: RemoteLog.category)
                    await waitBeforeRetry(delay)
                    continue
                }
                registeredSince = nil
                state = .failed(error.localizedDescription)
                AppLogger.info("中继注册断开：\(error.localizedDescription)", category: RemoteLog.category)
            }
            await waitBeforeRetry(retryDelay)
            retryDelay = min(retryDelay * 2, .seconds(60))
        }
    }

    private func waitBeforeRetry(_ delay: Duration) async {
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
        // 成员证书只能连一台主机，不能注册：本机被控用的必须是中继本身的成员密钥。
        guard let server, !config.isCertificate, let memberKey = config.memberKey else {
            throw RemoteRelayError.notConfigured
        }
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
        let answer = try await connection.answer()
        guard answer.ok else { throw RemoteRelayError.refused(answer.reason ?? "") }

        responder = RemoteSignalResponder(
            localKey: try identity.localIdentity(), localID: server.localID,
            recognize: { [weak server] id in MainActor.assumeIsolated { server?.knownPeer(id: id) } },
            isAllowed: { [weak server] id in MainActor.assumeIsolated { server?.allowsInternetAccess(id) ?? false } },
            invitationToken: { [weak server] in MainActor.assumeIsolated { server?.pairingInvitation?.token } })
        state = .registered
        registeredSince = Date()
        let endpoint = config.endpointDescription, relayVersion = answer.server ?? "?"
        AppLogger.notice("已注册到中继 \(endpoint)（中继 \(relayVersion)）",
                         category: RemoteLog.category)
        server.relayUpdates.noteRunning(answer.server)
        retryDelay = .seconds(1)
        lastHeard = Date()
        startHeartbeat(connection)
        server.relayRegistered()
        sendRevocations()

        while !Task.isCancelled {
            let message: RemoteRelayMessage = try await connection.receive(timeout: nil)
            lastHeard = Date()
            switch message.type {
            case "signal": await handleSignal(message, on: connection)
            case "incoming": handleIncoming(message)
            case "ping": try await connection.send(RemoteRelayMessage(type: "pong"))
            case "revoked":
                if let member = message.member { server.relayRevocations.confirm(member, relayID: config.relayID) }
            case "superseded": throw RemoteRelayError.refused("superseded")
            default: break
            }
        }
        throw CancellationError()
    }

    /// 把还没确认的成员证书吊销发给中继。中继回 `revoked` 才从待发里划掉；没注册上就等下次注册。
    func sendRevocations() {
        guard state == .registered, let control, let server else { return }
        let pending = server.relayRevocations.pending(relayID: config.relayID)
        guard !pending.isEmpty else { return }
        Task {
            for revocation in pending {
                var message = RemoteRelayMessage(type: "revoke")
                message.member = revocation.member
                message.exp = revocation.expires
                try? await control.send(message)
            }
        }
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
            AppLogger.notice("公网接入：收到打招呼（\(session.prefix(6))），不试直连，等中继回拨", category: RemoteLog.category)
            try? await connection.send(RemoteRelayMessage(type: "signal", session: session, box: reply))
            return
        case .direct(let offer):
            AppLogger.notice("公网接入：收到打招呼（\(session.prefix(6))），先试直连", category: RemoteLog.category)
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
        case .relayEcho(let reply):
            try? await connection.send(RemoteRelayMessage(type: "signal", session: session, box: reply))
            return
        case .ignore, nil:
            break
        }
        if let request = responder?.receiveRenewal(session: session, from: message.from, box: message.box, now: now),
           let renewed = server?.renewRelayGrant(peerID: request.peer.id, member: request.member) {
            var reply = RemoteSignalBody(kind: .renewedCertificate, deviceID: server?.localID ?? UUID(), sentAt: now,
                                         nonce: RemoteSignalBody.newNonce())
            reply.relay = RemoteJSON.encode(renewed)
            guard let sealed = try? RemoteSignalBox.seal(reply, key: request.sharedKey, session: session,
                                                         direction: .macToPhone) else { return }
            try? await connection.send(RemoteRelayMessage(type: "signal", session: session, box: sealed))
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
            AppLogger.notice("公网接入（\(session.prefix(6))）：Mac 这边收集不到地址，只能走中继", category: RemoteLog.category)
            attempt?.close()
            return
        }
        // 打洞要几秒。这期间用户可能关了公网接入，或者取消了这台设备的勾选。
        let checked = await attempt.waitForCheck(keys: offer.directKeys.check)
        if checked, let selected = attempt.selectedCandidates() {
            let local = RemoteICECandidateKind(sdp: selected.local)?.label ?? "?"
            let remote = RemoteICECandidateKind(sdp: selected.remote)?.label ?? "?"
            AppLogger.notice("公网接入（\(session.prefix(6))）：直连打通，Mac \(local) ← 手机 \(remote)", category: RemoteLog.category)
        } else if !checked {
            AppLogger.notice("公网接入（\(session.prefix(6))）：直连没打通，等中继回拨", category: RemoteLog.category)
        }
        guard checked, runner != nil, let server,
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
              callbacksInFlight < Self.maxCallbacksInFlight else { return }
        let now = Date().timeIntervalSince1970
        if responder?.claimEcho(session: session, now: now) == true {
            callbacksInFlight += 1
            Task { [weak self] in
                defer { self?.callbacksInFlight -= 1 }
                do {
                    guard let transport = try await self?.accept(ticket: ticket) else { return }
                    await RemoteStreamEchoServer.serve(transport)
                } catch {
                    AppLogger.info("中继诊断回拨失败：\(error.localizedDescription)", category: RemoteLog.category)
                }
            }
            return
        }
        guard let pending = responder?.claim(session: session, now: now) else { return }
        callbacksInFlight += 1
        Task { [weak self] in
            defer { self?.callbacksInFlight -= 1 }
            do {
                try await self?.callBack(ticket: ticket, pending: pending)
            } catch {
                AppLogger.notice("中继回拨失败：\(error.localizedDescription)", category: RemoteLog.category)
            }
        }
    }

    private func callBack(ticket: String, pending: RemoteSignalResponder.PendingSession) async throws {
        guard let server, let transport = try await accept(ticket: ticket) else { return }
        AppLogger.notice("公网接入：中继回拨接通", category: RemoteLog.category)
        server.accept(transport: transport,
                      origin: .internet(peerID: pending.peer.id, keys: pending.keys, path: .relay))
    }

    /// 拿着中继给的票回拨，接上就交出字节流。
    private func accept(ticket: String) async throws -> (any RemoteTransport)? {
        guard let server else { return nil }
        let hostKey = try server.identity.relayHostKey()
        let connection = RemoteRelayConnection(config: config)
        do {
            let hello = try await connection.open()
            try await connection.send(RemoteRelayRequest(
                role: "accept", ticket: ticket,
                hostSig: try RemoteRelaySignature.sign(hostKey, role: "accept", relayID: config.relayID,
                                                       nonce: hello.nonce, parameter: ticket)))
            let answer = try await connection.answer()
            guard answer.ok else { throw RemoteRelayError.refused(answer.reason ?? "") }
        } catch {
            connection.close()
            throw error
        }
        return connection.detach()
    }
}
