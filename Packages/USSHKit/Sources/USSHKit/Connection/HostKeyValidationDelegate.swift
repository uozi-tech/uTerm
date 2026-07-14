import Foundation
import Crypto
import NIOCore
import NIOSSH

nonisolated enum HostKeySerialization {
    static func serialize(
        _ key: NIOSSHPublicKey,
        host: String,
        port: Int
    ) -> SSHHostKey {
        var buffer = ByteBuffer()
        key.write(to: &buffer)
        let blob = Data(buffer.readableBytesView)
        let openSSH = String(openSSHPublicKey: key)
        let keyType = openSSH.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let digest = SHA256.hash(data: blob)
        let fingerprint = "SHA256:" + Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return SSHHostKey(
            host: host,
            port: port,
            keyType: keyType,
            keyBlob: blob,
            fingerprint: fingerprint
        )
    }
}

nonisolated final class HostKeyValidationDelegate:
    NIOSSHClientServerAuthenticationDelegate,
    @unchecked Sendable
{
    private let host: String
    private let port: Int
    private let store: any HostKeyStore
    private let policy: SSHHostKeyPolicy
    private let approver: @Sendable (SSHHostKeyChallenge) async -> Bool
    private let approvalTimeout: Duration

    init(
        host: String,
        port: Int,
        store: any HostKeyStore,
        policy: SSHHostKeyPolicy,
        approvalTimeout: Duration,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool
    ) {
        self.host = host
        self.port = port
        self.store = store
        self.policy = policy
        self.approvalTimeout = approvalTimeout
        self.approver = approver
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let candidate = HostKeySerialization.serialize(hostKey, host: host, port: port)
        Task {
            do {
                let verification = try await store.verify(candidate)
                try await validate(candidate, verification: verification)
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }

    private func validate(
        _ hostKey: SSHHostKey,
        verification: SSHHostKeyVerification
    ) async throws {
        switch verification {
        case .trusted:
            return

        case .unknown:
            switch policy {
            case .strict:
                throw SSHConnectionError.hostKeyRejected(
                    "未知主机 \(hostKey.host):\(hostKey.port)（\(hostKey.fingerprint)）"
                )
            case .acceptNew, .insecureAcceptAll:
                try await store.remember(hostKey)
            case .ask:
                let challenge = SSHHostKeyChallenge(hostKey: hostKey, kind: .unknown)
                guard await approveWithTimeout(challenge) else {
                    throw SSHConnectionError.hostKeyRejected("用户拒绝了未知主机密钥")
                }
                try await store.remember(hostKey)
            }

        case .mismatch(let previousFingerprint):
            switch policy {
            case .insecureAcceptAll:
                try await store.remember(hostKey)
            case .ask:
                let challenge = SSHHostKeyChallenge(
                    hostKey: hostKey,
                    kind: .mismatch,
                    previousFingerprint: previousFingerprint
                )
                guard await approveWithTimeout(challenge) else {
                    throw SSHConnectionError.hostKeyRejected("用户拒绝了变化的主机密钥")
                }
                try await store.remember(hostKey)
            case .strict, .acceptNew:
                throw SSHConnectionError.hostKeyRejected(
                    "主机密钥已变化：原 \(previousFingerprint)，现 \(hostKey.fingerprint)"
                )
            }
        }
    }

    private func approveWithTimeout(_ challenge: SSHHostKeyChallenge) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await self.approver(challenge) }
            group.addTask {
                try? await Task.sleep(for: self.approvalTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }
}
