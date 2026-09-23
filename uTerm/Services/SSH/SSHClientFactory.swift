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

    /// 流式 exec：stdout / stderr 每到一块就交给 `onOutput`，命令结束（EOF）才返回。
    ///
    /// 与 `exec` 的两处不同，都是 CLI 的静默看门狗要的：
    /// - 能**边跑边**看到输出，于是能按「多久没动静」而不是「跑了多久」判超时；
    /// - 没有 `exec` 那道 64 000 字节的总量闸（超了整条抛 `commandOutputTooLarge`，
    ///   输出多一点的命令直接失败），留多少由调用方自己裁。
    func execStreaming(
        _ command: String,
        onOutput: @Sendable (Data) -> Void
    ) async throws {
        let stream = try await target.executeCommandStream(command)
        for try await chunk in stream {
            switch chunk {
            case .stdout(let buffer), .stderr(let buffer):
                onOutput(Data(buffer.readableBytesView))
            }
        }
    }

    func openDirectTCPIP(
        host: String,
        port: Int
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        try await shared.openDirectTCPIP(host: host, port: port)
    }
}

/// uTerm's model/UI adapter around the shared connection engine.
nonisolated enum SSHClientFactory {
    /// SSH 子通道（PTY / SFTP / direct-tcpip）的入站窗口大小。
    ///
    /// NIOSSH 把每条子通道的入站窗口钉死成 `SSHClientConfiguration.maximumPacketSize`
    /// （`SSHChannelMultiplexer.createChildChannel` 里 `targetWindowSize:
    /// Int32(self.maximumPacketSize)`），默认 `SSHPacketParser.defaultMaximumPacketSize`
    /// = 128 KiB。SFTP 下载走 64 × 32 000 B 的读流水线，128 KiB 的窗口只放得下 4 个
    /// 在途读请求 —— 流水线深度被窗口而不是被我们的并发度限制住，吞吐直接砍到 1/16。
    ///
    /// 取 1 MiB 的理由：满流水线在途约 64 × 32 000 B ≈ 2 MiB，取其一半即可让窗口不再
    /// 是瓶颈（窗口在消费一半时就会补发 window-adjust，1 MiB 足以覆盖一个 RTT 内的在
    /// 途量）；再往上只是让慢消费者（例如 UI 还没读走的终端输出）在内存里多攒几倍数据，
    /// 收益却已经饱和。NIOSSH 对这个值的硬约束是 `>= 32768 && <= (1 << 24)`
    /// （`SSHPacketParser.init` 的两条 precondition），1 << 20 稳在区间内。
    ///
    /// 这个设置是**每条 SSH 连接**级别的，所以同一连接上的终端 PTY 通道与端口转发通道
    /// 也会拿到 1 MiB 窗口 —— 纯粹是缓冲变大，没有行为变化。跳板机那一跳必须一起设，
    /// 否则内层会话的全部流量还是挤在外层 direct-tcpip 通道的 128 KiB 窗口里；
    /// `USSHKitIntegration.connect`（uAppKit ≥ 1.4.6）内部对直连与跳板机两跳一并应用。
    static let channelWindowOptions: Set<SSHProtocolOption> = windowOptions(bytes: 1 << 20)

    /// 指定窗口大小的协议选项（越界夹回 `maximumPacketSizeRange`）。大文件传输的专用连接
    /// 用更大的窗口（见 `ParallelTransfer`），终端 / 转发连接仍用上面的 1 MiB。
    static func windowOptions(bytes: Int) -> Set<SSHProtocolOption> {
        [.maximumPacketSize(clampedMaximumPacketSize(bytes))]
    }

    /// NIOSSH 允许的最大包长区间。
    ///
    /// `SSHPacketParser.init` 用两条 **precondition** 卡这个值 —— 越界不是抛错、不是
    /// 回退默认值，而是直接 `abort()` 掐掉整个进程。所以宁可在这里把值夹回区间里也不
    /// 能把越界值递下去：常量写错顶多是窗口没调成预期大小，传下去就是启动即崩。
    static let maximumPacketSizeRange: ClosedRange<Int> = 32_768...(1 << 24)

    /// 把包长夹进 `maximumPacketSizeRange`。
    static func clampedMaximumPacketSize(_ raw: Int) -> Int {
        min(max(raw, maximumPacketSizeRange.lowerBound), maximumPacketSizeRange.upperBound)
    }

    static func connect(
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        jumpHostAuth: ResolvedAuth?,
        hostKeyVerifier: HostKeyVerifier,
        hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool,
        protocolOptions: Set<SSHProtocolOption> = SSHClientFactory.channelWindowOptions
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
                approver: packageApprover(hostKeyApprover),
                protocolOptions: protocolOptions
            )
            return ConnectedClient(shared: shared)
        } catch let error as USSHKit.SSHConnectionError {
            // USSHKit 的 errorDescription 已自带「SSH 连接失败：」等前缀；这里只取正文再包一层
            // 本地前缀，避免用户看到「SSH 连接失败：SSH 连接失败：…」。
            switch error {
            case .jumpHostFailed(let message):
                throw SSHConnection.SSHConnectionError.jumpHostFailed(message)
            case .connectFailed(let message):
                throw SSHConnection.SSHConnectionError.connectFailed(message)
            case .authenticationFailed(let message):
                throw SSHConnection.SSHConnectionError.connectFailed("认证失败：\(message)")
            case .hostKeyRejected(let message):
                throw SSHConnection.SSHConnectionError.connectFailed("主机密钥被拒绝：\(message)")
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
