@preconcurrency import Citadel

/// Narrow integration surface used by uTerm while its terminal/SFTP adapters remain app-owned.
@_spi(uTermIntegration)
public enum USSHKitIntegration {
    public static func connect(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool
    ) async throws -> ConnectedClient {
        try await SSHClientFactory.connect(
            endpoint: endpoint,
            credential: credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver
        )
    }

    public static func makeAuthenticationMethod(
        username: String,
        credential: SSHCredential
    ) throws -> SSHAuthenticationMethod {
        try SSHClientFactory.makeAuthenticationMethod(
            username: username,
            credential: credential
        )
    }

    public static func makeHostKeyValidator(
        host: String,
        port: Int,
        store: any HostKeyStore,
        policy: SSHHostKeyPolicy,
        approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool
    ) -> Citadel.SSHHostKeyValidator {
        .custom(HostKeyValidationDelegate(
            host: host,
            port: port,
            store: store,
            policy: policy,
            approvalTimeout: approvalTimeout,
            approver: approver
        ))
    }
}
