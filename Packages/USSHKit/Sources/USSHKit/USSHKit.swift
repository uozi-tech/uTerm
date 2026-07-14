import Foundation

/// A network address used by an SSH endpoint or forwarding destination.
public struct SSHHostAddress: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Authentication material supplied by the application. USSHKit never reads a keychain.
public enum SSHCredential: Hashable, Sendable {
    case password(String)
    case privateKey(pem: String, passphrase: String?)
    case agent
}

/// A single optional bastion. It is deliberately non-recursive so the endpoint remains a value type.
public struct SSHJumpHost: Hashable, Sendable {
    public var address: SSHHostAddress
    public var username: String
    public var credential: SSHCredential

    public init(
        host: String,
        port: Int = 22,
        username: String,
        credential: SSHCredential
    ) {
        self.address = SSHHostAddress(host: host, port: port)
        self.username = username
        self.credential = credential
    }
}

/// Everything needed to identify an SSH server, with an optional one-hop bastion.
public struct SSHEndpoint: Hashable, Sendable {
    public var address: SSHHostAddress
    public var username: String
    public var jumpHost: SSHJumpHost?

    public init(
        host: String,
        port: Int = 22,
        username: String,
        jumpHost: SSHJumpHost? = nil
    ) {
        self.address = SSHHostAddress(host: host, port: port)
        self.username = username
        self.jumpHost = jumpHost
    }

    public var host: String {
        get { address.host }
        set { address.host = newValue }
    }

    public var port: Int {
        get { address.port }
        set { address.port = newValue }
    }
}

/// A serialized server host key. The byte representation matches OpenSSH `known_hosts` key data.
public struct SSHHostKey: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let keyBlob: Data
    public let fingerprint: String

    public init(
        host: String,
        port: Int,
        keyType: String,
        keyBlob: Data,
        fingerprint: String
    ) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.keyBlob = keyBlob
        self.fingerprint = fingerprint
    }
}

public enum SSHHostKeyVerification: Equatable, Sendable {
    case trusted
    case unknown
    case mismatch(previousFingerprint: String)
}

/// Persistence boundary for host-key trust. Applications own storage and UI policy.
public protocol HostKeyStore: Sendable {
    func verify(_ hostKey: SSHHostKey) async throws -> SSHHostKeyVerification
    func remember(_ hostKey: SSHHostKey) async throws
}

public enum SSHHostKeyPolicy: String, CaseIterable, Sendable {
    case ask
    case strict
    case acceptNew
    case insecureAcceptAll
}

public struct SSHHostKeyChallenge: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable {
        case unknown
        case mismatch
    }

    public let id: UUID
    public let hostKey: SSHHostKey
    public let kind: Kind
    public let previousFingerprint: String?

    public init(
        id: UUID = UUID(),
        hostKey: SSHHostKey,
        kind: Kind,
        previousFingerprint: String? = nil
    ) {
        self.id = id
        self.hostKey = hostKey
        self.kind = kind
        self.previousFingerprint = previousFingerprint
    }
}

public enum SSHPrivateKeyKind: String, CaseIterable, Hashable, Codable, Sendable {
    case rsa
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
}

/// An immutable parsed private key. Concrete Citadel and swift-crypto key types stay internal.
public struct SSHPrivateKey: @unchecked Sendable {
    public let kind: SSHPrivateKeyKind
    let parsed: ParsedPrivateKey

    init(kind: SSHPrivateKeyKind, parsed: ParsedPrivateKey) {
        self.kind = kind
        self.parsed = parsed
    }
}

/// Stable parsing entry point for OpenSSH, PEM, encrypted PKCS#8, RSA, Ed25519, and ECDSA keys.
public enum SSHPrivateKeyParser {
    public static func parse(pem: String, passphrase: String? = nil) throws -> SSHPrivateKey {
        let parsed = try PrivateKeyImporter.resolve(pem: pem, passphrase: passphrase)
        let kind: SSHPrivateKeyKind
        switch parsed {
        case .rsa, .legacyOpenSSHRSA:
            kind = .rsa
        case .ed25519:
            kind = .ed25519
        case .p256:
            kind = .ecdsaP256
        case .p384:
            kind = .ecdsaP384
        case .p521:
            kind = .ecdsaP521
        }
        return SSHPrivateKey(kind: kind, parsed: parsed)
    }
}

public struct SSHForwardingRequest: Hashable, Sendable {
    public var endpoint: SSHEndpoint
    public var credential: SSHCredential
    public var target: SSHHostAddress
    public var localHost: String
    /// Zero asks the operating system to choose an available local port.
    public var localPort: Int

    public init(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        targetHost: String,
        targetPort: Int,
        localHost: String = "127.0.0.1",
        localPort: Int = 0
    ) {
        self.endpoint = endpoint
        self.credential = credential
        self.target = SSHHostAddress(host: targetHost, port: targetPort)
        self.localHost = localHost
        self.localPort = localPort
    }
}

public struct SSHForwardingEndpoint: Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public protocol SSHForwardingTunnel: Sendable {
    func open() async throws -> SSHForwardingEndpoint
    func close() async
}

public enum SSHConnectionError: Error, LocalizedError, Sendable {
    case alreadyOpen
    case closed
    case unsupportedAgentAuthentication
    case authenticationFailed(String)
    case connectFailed(String)
    case jumpHostFailed(String)
    case hostKeyRejected(String)
    case bindFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyOpen:
            return "SSH 隧道已经建立"
        case .closed:
            return "SSH 隧道已关闭"
        case .unsupportedAgentAuthentication:
            return "当前版本尚未支持 ssh-agent 认证"
        case .authenticationFailed(let message):
            return "SSH 认证失败：\(message)"
        case .connectFailed(let message):
            return "SSH 连接失败：\(message)"
        case .jumpHostFailed(let message):
            return "SSH 跳板机连接失败：\(message)"
        case .hostKeyRejected(let message):
            return "SSH 主机密钥被拒绝：\(message)"
        case .bindFailed(let message):
            return "SSH 本地转发端口绑定失败：\(message)"
        }
    }
}

public enum SSHLogLevel: Sendable {
    case trace
    case debug
    case info
    case warning
    case error
}

public struct SSHLogEvent: Sendable {
    public let level: SSHLogLevel
    public let message: String
    public let metadata: [String: String]

    public init(level: SSHLogLevel, message: String, metadata: [String: String] = [:]) {
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

public protocol SSHLogger: Sendable {
    func log(_ event: SSHLogEvent)
}

public struct NoOpSSHLogger: SSHLogger {
    public init() {}
    public func log(_ event: SSHLogEvent) {}
}

enum USSHKitInternalError: Error, LocalizedError {
    case authenticationFailed(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let message):
            return message
        }
    }
}
