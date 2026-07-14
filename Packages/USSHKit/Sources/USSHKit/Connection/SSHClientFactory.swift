import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOSSH

@_spi(uTermIntegration)
public nonisolated struct ConnectedClient: @unchecked Sendable {
    public let target: SSHClient
    public let bastion: SSHClient?

    init(target: SSHClient, bastion: SSHClient?) {
        self.target = target
        self.bastion = bastion
    }

    public func close() async {
        try? await target.close()
        try? await bastion?.close()
    }

    public func exec(_ command: String) async throws -> String {
        let buffer = try await target.executeCommand(
            command,
            maxResponseSize: 64_000,
            mergeStreams: true
        )
        return String(buffer: buffer)
    }

    public func openDirectTCPIP(host: String, port: Int) async throws -> Channel {
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        return try await target.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(
                targetHost: host,
                targetPort: port,
                originatorAddress: originator
            ),
            initialize: { $0.eventLoop.makeSucceededVoidFuture() }
        )
    }
}

nonisolated enum SSHClientFactory {
    static func connect(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool
    ) async throws -> ConnectedClient {
        if let jumpHost = endpoint.jumpHost {
            return try await connectViaJumpHost(
                endpoint: endpoint,
                credential: credential,
                jumpHost: jumpHost,
                hostKeyStore: hostKeyStore,
                hostKeyPolicy: hostKeyPolicy,
                connectTimeout: connectTimeout,
                approvalTimeout: approvalTimeout,
                approver: approver
            )
        }

        let target = try await connectDirect(
            host: endpoint.host,
            port: endpoint.port,
            username: endpoint.username,
            credential: credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver
        )
        return ConnectedClient(target: target, bastion: nil)
    }

    private static func connectDirect(
        host: String,
        port: Int,
        username: String,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool
    ) async throws -> SSHClient {
        let authenticationMethod = try makeAuthenticationMethod(
            username: username,
            credential: credential
        )
        do {
            return try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: authenticationMethod,
                hostKeyValidator: .custom(
                    HostKeyValidationDelegate(
                        host: host,
                        port: port,
                        store: hostKeyStore,
                        policy: hostKeyPolicy,
                        approvalTimeout: approvalTimeout,
                        approver: approver
                    )
                ),
                reconnect: .never,
                connectTimeout: .nanoseconds(connectTimeout.nanosecondsClamped)
            )
        } catch let error as SSHConnectionError {
            throw error
        } catch {
            throw SSHConnectionError.connectFailed(describe(error))
        }
    }

    private static func connectViaJumpHost(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        jumpHost: SSHJumpHost,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool
    ) async throws -> ConnectedClient {
        let bastion: SSHClient
        do {
            bastion = try await connectDirect(
                host: jumpHost.address.host,
                port: jumpHost.address.port,
                username: jumpHost.username,
                credential: jumpHost.credential,
                hostKeyStore: hostKeyStore,
                hostKeyPolicy: hostKeyPolicy,
                connectTimeout: connectTimeout,
                approvalTimeout: approvalTimeout,
                approver: approver
            )
        } catch {
            throw SSHConnectionError.jumpHostFailed(
                "无法连接 \(jumpHost.address.host):\(jumpHost.address.port) —— \(describe(error))"
            )
        }

        let targetAuthentication: SSHAuthenticationMethod
        do {
            targetAuthentication = try makeAuthenticationMethod(
                username: endpoint.username,
                credential: credential
            )
        } catch {
            try? await bastion.close()
            throw SSHConnectionError.jumpHostFailed(describe(error))
        }

        let settings = SSHClientSettings(
            host: endpoint.host,
            port: endpoint.port,
            authenticationMethod: { targetAuthentication },
            hostKeyValidator: .custom(
                HostKeyValidationDelegate(
                    host: endpoint.host,
                    port: endpoint.port,
                    store: hostKeyStore,
                    policy: hostKeyPolicy,
                    approvalTimeout: approvalTimeout,
                    approver: approver
                )
            )
        )

        do {
            let target = try await bastion.jump(to: settings)
            return ConnectedClient(target: target, bastion: bastion)
        } catch {
            try? await bastion.close()
            throw SSHConnectionError.jumpHostFailed(
                "经跳板机连接 \(endpoint.host):\(endpoint.port) 失败 —— \(describe(error))"
            )
        }
    }

    static func makeAuthenticationMethod(
        username: String,
        credential: SSHCredential
    ) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .privateKey(let pem, let passphrase):
            do {
                let key = try PrivateKeyImporter.resolve(pem: pem, passphrase: passphrase)
                return try key.authenticationMethod(username: username)
            } catch let error as PrivateKeyImportError {
                throw SSHConnectionError.authenticationFailed(
                    error.errorDescription ?? "私钥导入失败"
                )
            } catch {
                throw SSHConnectionError.authenticationFailed(describe(error))
            }
        case .agent:
            throw SSHConnectionError.unsupportedAgentAuthentication
        }
    }

    private static func describe(_ error: Error) -> String {
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return localized.isEmpty ? String(reflecting: error) : localized
    }
}

private extension Duration {
    var nanosecondsClamped: Int64 {
        let parts = components
        let seconds = parts.seconds
        let attoseconds = parts.attoseconds
        let maxSeconds = Int64.max / 1_000_000_000
        if seconds >= maxSeconds { return Int64.max }
        if seconds <= -maxSeconds { return Int64.min }
        return seconds * 1_000_000_000 + Int64(attoseconds / 1_000_000_000)
    }
}
