import Foundation

/// 设备经中继向签发证书的 Mac 要一张新的：端到端加密的信令（和连接请求同一套配对密钥），中继看不懂也改不了。
/// Mac 只给认识、勾选过公网接入、公钥对得上自己记录的设备续，续了还是同一把钥匙（`RemoteHostServer.renewRelayGrant`）。
nonisolated enum RemoteRelayCertificateRenewal {
    /// Mac 不在线、不回时，同一台 Mac 隔这么久才再要一次。
    static let retryInterval: TimeInterval = 3600

    /// 用这张证书自己的中继连接去要。返回续好的证书；对不上（不是同一把钥匙、同一台 Mac）一律当失败。
    static func renew(_ certificate: RemoteRelayConfig, from mac: RemotePeer, relay: RemoteRelayClient,
                      identity: RemoteIdentityStore, localID: UUID, timeout: TimeInterval = 5,
                      now: Date = Date()) async throws -> RemoteRelayConfig {
        guard certificate.isCertificate, let member = certificate.memberPublicKey else {
            throw RemoteRelayError.notConfigured
        }
        guard !certificate.isExpired(now: now) else { throw RemoteRelayError.certificateExpired }
        let shared = try RemoteSignalBox.sharedKey(local: try identity.localIdentity(), remotePublicKey: mac.publicKey)
        let session = UUID().uuidString
        var request = RemoteSignalBody(kind: .renewCertificate, deviceID: localID, sentAt: now.timeIntervalSince1970,
                                       nonce: RemoteSignalBody.newNonce())
        request.member = member
        let sealed = try RemoteSignalBox.seal(request, key: shared, session: session, direction: .phoneToMac)
        let box = try await relay.signal(to: mac.id, from: localID, session: session, box: sealed, timeout: timeout)
        let reply = try RemoteSignalBox.open(box, key: shared, session: session, direction: .macToPhone)
        guard reply.kind == .renewedCertificate, reply.deviceID == mac.id, reply.nonce.count == 32,
              abs(now.timeIntervalSince1970 - reply.sentAt) <= RemoteSignalReplayGuard.window, let data = reply.relay,
              let renewed = RemoteRelayConfig(importing: data), renewed.isCertificate,
              renewed.key == certificate.key, renewed.scope == certificate.scope,
              renewed.relayID == certificate.relayID else { throw RemoteRelayError.malformed }
        return renewed
    }
}
