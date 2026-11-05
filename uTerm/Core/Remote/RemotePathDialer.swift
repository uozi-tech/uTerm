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
        case .localNetwork: return "局域网"
        case .direct: return "直连"
        case .relay: return "中继"
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

    func dial(_ mac: RemotePeer) async throws -> RemoteDialedPath {
        let session = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }).base64URLEncoded
        let staticKey = try identity.localIdentity()
        let shared = try RemoteSignalBox.sharedKey(local: staticKey, remotePublicKey: mac.publicKey)
        let attempt = allowsDirect ? await startDirect() : nil
        defer { attempt?.close() }
        let offer = RemoteSignalBody(kind: .offer, deviceID: localID, sentAt: Date().timeIntervalSince1970,
                                     nonce: RemoteSignalBody.newNonce(), ice: attempt?.localDescription())
        let sealed = try RemoteSignalBox.seal(offer, key: shared, session: session, direction: .phoneToMac)
        let replyBox = try await relay.signal(to: mac.id, from: localID, session: session, box: sealed)
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
        case .offer, .iceProbe, .iceProbeAnswer: throw RemoteRelayError.malformed
        case .answer: break
        }
        let keys = RemoteSignalBox.handshakeKeys(sharedKey: shared, phoneNonce: offer.nonce, macNonce: reply.nonce,
                                                 session: session, role: .initiator)
        if let attempt, let remote = reply.ice {
            let direct = RemoteSignalBox.directKeys(sharedKey: shared, phoneNonce: offer.nonce, macNonce: reply.nonce,
                                                    session: session, role: .initiator)
            if let transport = await connectDirect(attempt, remote: remote, keys: direct) {
                return RemoteDialedPath(transport: transport, handshakeKeys: keys, path: .direct)
            }
        }
        let transport = try await relay.dial(host: mac.id, session: session)
        return RemoteDialedPath(transport: transport, handshakeKeys: keys, path: .relay)
    }

    /// 开始收集地址。失败不要紧，走中继就是了。
    private func startDirect() async -> RemoteDirectAttempt? {
        let config = relay.relayConfig
        guard let attempt = RemoteDirectAttempt(stunHost: config.host, stunPort: UInt16(clamping: config.port)),
              attempt.gather() else { return nil }
        await attempt.waitForGathering(limit: RemoteDirectAttempt.gatherLimit)
        return attempt
    }

    private func connectDirect(_ attempt: RemoteDirectAttempt, remote: String, keys: RemoteDirectKeys) async -> RemoteP2PTransport? {
        guard attempt.setRemote(remote) else { return nil }
        guard await attempt.waitForConnection(limit: RemoteDirectAttempt.connectLimit) else {
            AppLogger.info("打洞没打通，改走中继", category: RemoteLog.category)
            return nil
        }
        guard await attempt.verify(keys: keys.check) else {
            AppLogger.info("打洞通了但路径确认没过，改走中继", category: RemoteLog.category)
            return nil
        }
        if let selected = attempt.selectedCandidates() {
            let local = RemoteICECandidateKind(sdp: selected.local)?.label ?? "?"
            let remote = RemoteICECandidateKind(sdp: selected.remote)?.label ?? "?"
            AppLogger.info("直连：\(local) → \(remote)", category: RemoteLog.category)
        }
        return attempt.makeTransport(keys: keys.datagram)
    }
}
