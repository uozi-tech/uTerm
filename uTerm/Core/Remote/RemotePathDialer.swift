import CryptoKit
import Foundation

nonisolated enum RemoteLog {
    static let category = "remote"
}

/// 一条连接走的是哪条路。
nonisolated enum RemoteLinkPath: String, Equatable, Sendable {
    case localNetwork
    case direct
    case relay

    var isInternet: Bool { self != .localNetwork }

    var label: String {
        switch self {
        case .localNetwork: return String(localized: "局域网")
        case .direct: return String(localized: "直连", comment: "远控连接路径：公网直连")
        case .relay: return String(localized: "中继", comment: "远控连接路径：经中继")
        }
    }
}

/// 拨通的结果：字节流，以及公网路径要用的握手密钥。
nonisolated struct RemoteDialedPath: Sendable {
    let transport: any RemoteTransport
    let handshakeKeys: RemoteHandshakeKeys?
    let path: RemoteLinkPath
}

/// 手机这边跨公网连一台 Mac：先经中继打招呼，能打洞就直连，打不通走中继。
nonisolated struct RemotePathDialer: Sendable {
    let relay: RemoteRelayClient
    let identity: RemoteIdentityStore
    let localID: UUID
    var allowsDirect = true
    /// 「只走公网」：打洞时连私有 IPv4 也不用，否则同一局域网里两端的私有地址一配就通，测不到外出时的路。
    var publicOnly = false
    /// 按网络类型记的打洞成败，决定这次让直连先跑多久。
    var history = RemoteDirectHistory.standard

    /// `invitationToken`：凭邀请第一次连这台 Mac（它还不认识本机），打招呼时包上邀请外层。
    /// `trace`：每一步（收集地址、连中继、信令、直连、中继接通）的耗时与结果记进去。
    func dial(_ mac: RemotePeer, invitationToken: Data? = nil,
              trace: RemoteConnectTrace = .silent()) async throws -> RemoteDialedPath {
        let session = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }).base64URLEncoded
        let staticKey = try identity.localIdentity()
        let shared = try RemoteSignalBox.sharedKey(local: staticKey, remotePublicKey: mac.publicKey)
        // 连中继与收集打洞地址同时进行：两样都要等一两个往返，排着做白白多等。
        let control = trace.begin(.relayControl, detail: relay.relayConfig.name)
        let relay = self.relay
        let warming = Task { try await relay.warmUp() }
        var attempt: RemoteDirectAttempt?
        if allowsDirect {
            let gather = trace.begin(.gather)
            attempt = await startDirect()
            trace.end(gather, ok: attempt != nil, detail: attempt.flatMap { Self.candidateSummary($0.localDescription()) })
        }
        defer { attempt?.close() }
        let network: String
        do {
            let interface = try await warming.value
            network = interface ?? "?"
            trace.end(control, ok: true, detail: interface)
        } catch {
            trace.end(control, ok: false, detail: error.localizedDescription)
            throw error
        }
        let offer = RemoteSignalBody(kind: .offer, deviceID: localID, sentAt: Date().timeIntervalSince1970,
                                     nonce: RemoteSignalBody.newNonce(),
                                     ice: attempt?.localDescription().map {
                                         RemoteICEDescriptionFilter.keep($0, family: nil, publicOnly: publicOnly)
                                     })
        var sealed = try RemoteSignalBox.seal(offer, key: shared, session: session, direction: .phoneToMac)
        if let invitationToken {
            sealed = try RemoteInvitationSignal.wrap(sealed, clientKey: staticKey.publicKey.rawRepresentation,
                                                     token: invitationToken, session: session)
        }
        let replyBox = try await trace.step(.signal) {
            try await relay.signal(to: mac.id, from: localID, session: session, box: sealed)
        }
        let reply: RemoteSignalBody
        do {
            reply = try RemoteSignalBox.open(replyBox, key: shared, session: session, direction: .macToPhone)
        } catch {
            throw RemoteProtocolError.peerIdentityChanged
        }
        guard reply.deviceID == mac.id, reply.nonce.count == 32,
              abs(Date().timeIntervalSince1970 - reply.sentAt) <= RemoteSignalReplayGuard.window else {
            throw RemoteProtocolError.peerIdentityChanged
        }
        switch reply.kind {
        case .denied: throw RemoteRelayError.notAllowed
        case .offer, .iceProbe, .iceProbeAnswer, .relayProbe, .relayProbeAnswer, .renewCertificate, .renewedCertificate:
            throw RemoteRelayError.malformed
        case .answer: break
        }
        let keys = RemoteSignalBox.handshakeKeys(sharedKey: shared, phoneNonce: offer.nonce, macNonce: reply.nonce,
                                                 session: session, role: .initiator)
        guard let attempt, let remote = reply.ice else {
            let transport = try await trace.step(.relayDial) {
                try await relay.dial(host: mac.id, session: session)
            }
            return RemoteDialedPath(transport: transport, handshakeKeys: keys, path: .relay)
        }
        let direct = RemoteSignalBox.directKeys(sharedKey: shared, phoneNonce: offer.nonce, macNonce: reply.nonce,
                                                session: session, role: .initiator)
        // 中继与打洞同时拨（Mac 收到招呼时已经把中继那路登记好）。直连先独跑 `window`：这段时间里它通了就用它；
        // 之后谁先给出能用的连接用谁。握手只在选中的那条路上发，没选中的关掉。
        let window = history.window(on: network)
        let race = RemoteRelayRace { try await relay.dial(host: mac.id, session: session) }
        let relayStep = trace.begin(.relayDial, detail: String(localized: "与直连同时开始"))
        let directStep = trace.begin(.direct, detail: String(localized: "先等 \(RemoteConnectTrace.millis(window)) ms"))
        let directTask = Task { await connectDirect(attempt, remote: remote, keys: direct) }
        let early = try? await RemoteDeadline.run(window, timeoutError: RemoteProtocolError.timeout) {
            await directTask.value
        }
        let pick: RemotePathPick
        if let early, let transport = early.transport {
            pick = .direct(transport, detail: early.detail)
        } else {
            pick = await RemotePathPick.first(direct: directTask, relay: race)
        }
        switch pick {
        case .direct(let transport, let detail):
            race.abandon()
            trace.end(directStep, ok: true, detail: detail)
            trace.end(relayStep, ok: false, detail: String(localized: "直连先通，不用了"))
            history.record(true, on: network)
            return RemoteDialedPath(transport: transport, handshakeKeys: keys, path: .direct)
        case .relay(let transport, let directDetail):
            trace.end(relayStep, ok: true)
            trace.end(directStep, ok: false, detail: directDetail ?? String(localized: "中继先通"))
            history.record(false, on: network)
            // 直连之后要是也通了，那条用不上，关掉。
            Task { if let late = await directTask.value.transport { late.cancel() } }
            return RemoteDialedPath(transport: transport, handshakeKeys: keys, path: .relay)
        case .failed(let error, let directDetail):
            trace.end(directStep, ok: false, detail: directDetail)
            trace.end(relayStep, ok: false, detail: error.localizedDescription)
            history.record(false, on: network)
            throw error
        }
    }

    /// 日志里的地址摘要：几个本机地址、几个反射地址，不写具体 IP。
    static func candidateSummary(_ description: String?) -> String? {
        guard let description else { return nil }
        let kinds = RemoteICECandidateKind.all(inDescription: description).map(\.label)
        guard !kinds.isEmpty else { return nil }
        let counts = Dictionary(grouping: kinds, by: { $0 }).map { "\($0.key)×\($0.value.count)" }.sorted()
        return counts.joined(separator: " ")
    }

    /// 开始收集地址。失败不要紧，走中继就是了。
    private func startDirect() async -> RemoteDirectAttempt? {
        let config = relay.relayConfig
        guard let attempt = RemoteDirectAttempt(stunHost: config.host, stunPort: UInt16(clamping: config.port)),
              attempt.gather() else { return nil }
        await attempt.waitForGathering(limit: RemoteDirectAttempt.gatherLimit)
        return attempt
    }

    private func connectDirect(_ attempt: RemoteDirectAttempt, remote: String,
                               keys: RemoteDirectKeys) async -> (transport: RemoteP2PTransport?, detail: String) {
        // 链路本地与 ULA 不出公网：同一局域网里本来就走 Bonjour 那条路。不去掉的话，手机插着线时会经 USB 或
        // devicectl 调试隧道「直连」，看着通，其实测不到公网。
        guard attempt.setRemote(RemoteICEDescriptionFilter.keep(remote, family: nil, publicOnly: publicOnly)) else {
            return (nil, String(localized: "对端地址不可用"))
        }
        let clock = ContinuousClock()
        let started = clock.now
        guard await attempt.waitForConnection(limit: RemoteDirectAttempt.connectLimit) else {
            return (nil, String(localized: "直连没打通，改走中继"))
        }
        let connected = clock.now
        guard await attempt.verify(keys: keys.check) else {
            return (nil, String(localized: "直连通了但路径确认没过，改走中继"))
        }
        var detail = ""
        if let selected = attempt.selectedCandidates() {
            let local = RemoteICECandidateKind(sdp: selected.local)?.label ?? "?"
            let remote = RemoteICECandidateKind(sdp: selected.remote)?.label ?? "?"
            detail = "\(local) → \(remote)"
        }
        // 对端有哪些地址、打通和确认各花多久（建连提速的读数）。
        let summary = Self.candidateSummary(remote) ?? "?"
        let connectMillis = RemoteConnectTrace.millis(connected - started)
        let verifyMillis = RemoteConnectTrace.millis(clock.now - connected)
        detail += " · " + String(localized: "对端 \(summary) · 打通 \(connectMillis) ms · 确认 \(verifyMillis) ms")
        return (attempt.makeTransport(keys: keys.datagram), detail)
    }
}
