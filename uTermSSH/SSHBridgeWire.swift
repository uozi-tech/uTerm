import Foundation

/// App 与 `uterm-ssh` 之间那条控制通道的消息。通道是 XPC 服务建的一对 socket，只在握手期间用：连上之后
/// `uterm-ssh` 就关掉它，App 重启不受影响。凭据只走这里，不进 argv、环境变量和磁盘。
///
/// 帧格式复用 `HolderFrame`（kind 固定为 `controlKind`，载荷是 JSON）。
nonisolated enum SSHBridgeMessage: Codable, Sendable {
    static let controlKind: UInt8 = 1

    // App → uterm-ssh
    case connect(SSHBridgeConnectRequest)
    case verifyResult(id: Int, SSHBridgeVerification)
    case rememberResult(id: Int)
    case approval(id: Int, Bool)
    // uterm-ssh → App
    case verifyHostKey(id: Int, SSHBridgeHostKey)
    case rememberHostKey(id: Int, SSHBridgeHostKey)
    case approveHostKey(id: Int, SSHBridgeChallenge)
    case connected
    case failed(SSHBridgeFailure)
    // 连上之后经 holder 转发（`childRequest` / `childReply`）。App 重启后也还能用，不碰凭据、不握手。
    case exec(id: Int, command: String)
    case execResult(id: Int, output: String?)
}

nonisolated enum SSHBridgeCredential: Codable, Sendable {
    case password(String)
    case privateKey(pem: String, passphrase: String?)
}

nonisolated struct SSHBridgeJumpHost: Codable, Sendable {
    var host: String
    var port: Int
    var username: String
    var credential: SSHBridgeCredential
}

nonisolated struct SSHBridgeEnvironmentVariable: Codable, Sendable {
    var name: String
    var value: String
}

nonisolated struct SSHBridgeConnectRequest: Codable, Sendable {
    var host: String
    var port: Int
    var username: String
    var credential: SSHBridgeCredential
    var jumpHost: SSHBridgeJumpHost?
    /// `USSHKit.SSHHostKeyPolicy` 的 rawValue。
    var hostKeyPolicy: String
    var connectTimeoutSeconds: Int
    /// 交互 shell 和经 `exec` 跑的命令都带这些环境变量。
    var environment: [SSHBridgeEnvironmentVariable]
}

nonisolated struct SSHBridgeHostKey: Codable, Sendable {
    var host: String
    var port: Int
    var keyType: String
    var keyBlob: Data
    var fingerprint: String
}

nonisolated enum SSHBridgeVerification: Codable, Sendable {
    case trusted
    case unknown
    case mismatch(previousFingerprint: String)
}

nonisolated struct SSHBridgeChallenge: Codable, Sendable {
    var hostKey: SSHBridgeHostKey
    var isMismatch: Bool
    var previousFingerprint: String?
}

nonisolated struct SSHBridgeFailure: Codable, Sendable, LocalizedError {
    enum Kind: String, Codable, Sendable {
        case jumpHost, connect
    }

    var kind: Kind
    var message: String
    /// 重试完仍是 EHOSTUNREACH：多半是这个进程的局域网权限被拒了（或用户一直没回答权限框）。
    /// App 据此退回进程内连接——App 自己的权限通常早就有了。可选字段，新旧两端互相解码都不受影响。
    var localNetworkUnreachable: Bool? = nil
    /// `kind == .jumpHost` 时是哪一类问题，线上是 `JumpHostFailureCause` 的 rawValue。按**字符串**收：以后加了新的
    /// 类别，还在跑的新辅助进程发给旧 App 的值它不认识，整条失败也照样解得开（不认识的按网络问题算）。
    /// 旧的辅助进程不带这个字段，同样按网络问题算。
    var jumpHostCauseRaw: String? = nil

    enum CodingKeys: String, CodingKey {
        case kind, message, localNetworkUnreachable
        case jumpHostCauseRaw = "jumpHostCause"
    }

    init(kind: Kind, message: String, localNetworkUnreachable: Bool? = nil, jumpHostCause: JumpHostFailureCause? = nil) {
        self.kind = kind
        self.message = message
        self.localNetworkUnreachable = localNetworkUnreachable
        self.jumpHostCauseRaw = jumpHostCause?.rawValue
    }

    var jumpHostCause: JumpHostFailureCause {
        jumpHostCauseRaw.flatMap(JumpHostFailureCause.init(rawValue:)) ?? .unreachable
    }

    var errorDescription: String? { message }
}

nonisolated extension HolderFrame {
    init(bridge message: SSHBridgeMessage) throws {
        self.init(kindRaw: SSHBridgeMessage.controlKind, payload: Array(try JSONEncoder().encode(message)))
    }

    var bridgeMessage: SSHBridgeMessage? {
        guard kindRaw == SSHBridgeMessage.controlKind || kindRaw == HolderFrameKind.childRequest.rawValue else { return nil }
        return try? JSONDecoder().decode(SSHBridgeMessage.self, from: Data(payload))
    }
}
