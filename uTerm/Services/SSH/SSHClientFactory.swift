import Foundation
@preconcurrency import Citadel
import NIOCore
@_spi(uTermIntegration) import USSHKit

/// App-local compatibility view over USSHKit's SPI connection handle.
nonisolated struct ConnectedClient: @unchecked Sendable {
    let shared: USSHKit.ConnectedClient

    init(shared: USSHKit.ConnectedClient) {
        self.shared = shared
    }

    var target: SSHClient { shared.target }
    var bastion: SSHClient? { shared.bastion }

    func close() async {
        await shared.close()
    }

    func exec(_ command: String) async throws -> String {
        try await shared.exec(command)
    }

    func openDirectTCPIP(host: String, port: Int) async throws -> Channel {
        try await shared.openDirectTCPIP(host: host, port: port)
    }
}

/// uTerm's model/UI adapter around the shared connection engine.
nonisolated enum SSHClientFactory {
    static func connect(
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        jumpHostAuth: ResolvedAuth?,
        hostKeyVerifier: HostKeyVerifier,
        hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) async throws -> ConnectedClient {
        let target = packageAuth(auth)
        let jumpHost: USSHKit.SSHJumpHost?
        if let jump = profile.jumpHost {
            guard let jumpHostAuth else {
                throw SSHConnection.SSHConnectionError.jumpHostFailed("缺少跳板机认证材料")
            }
            let jumpMaterial = packageAuth(jumpHostAuth)
            jumpHost = USSHKit.SSHJumpHost(
                host: jump.host,
                port: jump.port,
                username: jumpMaterial.username,
                credential: jumpMaterial.credential
            )
        } else {
            jumpHost = nil
        }

        let endpoint = USSHKit.SSHEndpoint(
            host: profile.host,
            port: profile.port,
            username: target.username,
            jumpHost: jumpHost
        )

        do {
            let shared = try await USSHKitIntegration.connect(
                endpoint: endpoint,
                credential: target.credential,
                hostKeyStore: hostKeyVerifier,
                hostKeyPolicy: packageHostKeyPolicy(),
                connectTimeout: .seconds(connectTimeoutSeconds()),
                approver: packageApprover(hostKeyApprover)
            )
            return ConnectedClient(shared: shared)
        } catch let error as USSHKit.SSHConnectionError {
            switch error {
            case .jumpHostFailed(let message):
                throw SSHConnection.SSHConnectionError.jumpHostFailed(message)
            default:
                throw SSHConnection.SSHConnectionError.connectFailed(
                    error.errorDescription ?? FriendlyError.describe(error)
                )
            }
        } catch {
            let message = FriendlyError.describe(error)
            if profile.jumpHost != nil {
                throw SSHConnection.SSHConnectionError.jumpHostFailed(message)
            }
            throw SSHConnection.SSHConnectionError.connectFailed(message)
        }
    }

    /// Kept as a narrow compatibility entry point for callers/tests that need
    /// a Citadel authentication method without owning key parsing.
    static func makeAuthMethod(from auth: ResolvedAuth) throws -> SSHAuthenticationMethod {
        let material = packageAuth(auth)
        do {
            return try USSHKitIntegration.makeAuthenticationMethod(
                username: material.username,
                credential: material.credential
            )
        } catch let error as USSHKit.SSHConnectionError {
            throw SSHConnection.SSHConnectionError.connectFailed(
                error.errorDescription ?? FriendlyError.describe(error)
            )
        }
    }

    private static func packageAuth(
        _ auth: ResolvedAuth
    ) -> (username: String, credential: USSHKit.SSHCredential) {
        switch auth {
        case .password(let username, let password):
            return (username, .password(password))
        case .privateKey(let username, let pem, let passphrase):
            return (username, .privateKey(pem: pem, passphrase: passphrase))
        }
    }

    private static func packageHostKeyPolicy() -> USSHKit.SSHHostKeyPolicy {
        let raw = UserDefaults.standard.string(forKey: "sshHostKeyPolicy")
            ?? SSHHostKeyPolicy.ask.rawValue
        switch SSHHostKeyPolicy(rawValue: raw) ?? .ask {
        case .strict:
            return .strict
        case .ask:
            return .ask
        case .none:
            return .insecureAcceptAll
        }
    }

    private static func packageApprover(
        _ approver: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) -> @Sendable (USSHKit.SSHHostKeyChallenge) async -> Bool {
        { challenge in
            let kind: HostKeyChallenge.Kind
            switch challenge.kind {
            case .unknown:
                kind = .unknown
            case .mismatch:
                kind = .mismatch
            }
            return await approver(HostKeyChallenge(
                host: challenge.hostKey.host,
                port: challenge.hostKey.port,
                kind: kind,
                newFingerprint: challenge.hostKey.fingerprint,
                oldFingerprint: challenge.previousFingerprint
            ))
        }
    }

    private static func connectTimeoutSeconds() -> Int64 {
        let seconds = (UserDefaults.standard.object(forKey: "sshConnectTimeout") as? Int) ?? 30
        return Int64(seconds)
    }
}
