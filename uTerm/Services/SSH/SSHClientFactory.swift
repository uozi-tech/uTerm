import Foundation
@preconcurrency import Citadel
import NIOCore
@_spi(uTermIntegration) import USSHKit

/// App-local compatibility view over USSHKit's SPI connection handle.
///
/// 来自 `SSHClientFactory.connectShared` 的实例是共享连接上的一份租约（`lease` 非 nil）：
/// `close()` 只归还租约，同一连接上的其他使用方不受影响；要判死整条连接用 `closeTransport()`。
nonisolated struct ConnectedClient: @unchecked Sendable {
    let shared: USSHKit.ConnectedClient
    let lease: PooledLease?

    init(shared: USSHKit.ConnectedClient, lease: PooledLease? = nil) {
        self.shared = shared
        self.lease = lease
    }

    var target: SSHClient { shared.target }
    var bastion: SSHClient? { shared.bastion }

    /// 用完了：独占连接直接断开；共享连接只归还租约，最后一个归还者才断开。
    func close() async {
        if let lease {
            await SharedSSHConnections.pool.release(lease)
        } else {
            await shared.close()
        }
    }

    /// 传输断开（含别的共享者判死后断开）时回调。共享连接走池子分发 ——
    /// Citadel 的 `onDisconnect` 只存一个回调，直接挂会顶掉别人的。
    func onDisconnect(_ handler: @escaping @Sendable () -> Void) async {
        if let lease {
            await SharedSSHConnections.pool.onClosed(lease, handler)
        } else {
            onTransportClosed(handler)
        }
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

nonisolated extension ConnectedClient: PooledConnection {
    var isAlive: Bool {
        target.isConnected && (bastion?.isConnected ?? true)
    }

    func onTransportClosed(_ handler: @escaping @Sendable () -> Void) {
        target.onDisconnect(perform: handler)
        bastion?.onDisconnect(perform: handler)
    }

    /// 不管有几个共享者，直接断开底层传输。看门狗判死时用：连接死了对谁都是死的，
    /// 断开后池子会通知这条连接上的所有使用方，各自走重连。
    func closeTransport() async {
        await shared.close()
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
        LocalNetworkUse.markUsed()
        let target = packageAuth(auth)
        let jumpHost: USSHKit.SSHJumpHost?
        if let jump = profile.jumpHost {
            guard let jumpHostAuth else {
                throw SSHConnection.SSHConnectionError.jumpHostFailed(String(localized: "缺少登录凭据"))
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

        let timeline = ConnectTimeline.current
        if let timeline, ConnectProbe.isEnabled {
            await probe(profile: profile, auth: auth, timeline: timeline)
        }

        do {
            defer { timeline?.mark("handshake") }
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
                throw SSHConnection.SSHConnectionError.authenticationFailed(message)
            case .hostKeyRejected(let message):
                throw SSHConnection.SSHConnectionError.connectFailed(String(localized: "主机密钥被拒绝：\(message)"))
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

    /// 终端与 SFTP 侧栏用：同一目标（含跳板机与认证材料）复用已有连接，见
    /// `SharedConnectionPool`。返回的是一份租约，`close()` 只归还租约。
    ///
    /// 同时到来的建连只握一次手，用的是第一个建连者的主机密钥审批回调；后来者直接复用
    /// 已经校验过主机密钥的连接。子通道窗口固定用 `channelWindowOptions` —— 要更大窗口的
    /// 大文件传输走 `connect` 自己开专用连接。
    static func connectShared(
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        jumpHostAuth: ResolvedAuth?,
        hostKeyVerifier: HostKeyVerifier,
        hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) async throws -> ConnectedClient {
        let key = SharedSSHKey(profile: profile, auth: auth, jumpHostAuth: jumpHostAuth)
        let acquired = try await SharedSSHConnections.pool.acquire(key) {
            try await connect(
                profile: profile,
                auth: auth,
                jumpHostAuth: jumpHostAuth,
                hostKeyVerifier: hostKeyVerifier,
                hostKeyApprover: hostKeyApprover)
        }
        if acquired.origin != .created {
            ConnectTimeline.current?.mark("handshake(\(acquired.origin.rawValue))")
        }
        return ConnectedClient(shared: acquired.connection.shared, lease: acquired.lease)
    }

    /// `sshTimingProbe` 打开时，在真正握手前单独量第一跳的 DNS、裸 TCP 握手与私钥解析，
    /// 记进 timeline 的 notes；这段耗时不计入建连总时长。私钥解析会在握手里再做一遍，
    /// 这里量的就是握手内那一份本机开销。
    private static func probe(
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        timeline: ConnectTimeline
    ) async {
        let firstHop = profile.jumpHost.map { ($0.host, $0.port) } ?? (profile.host, profile.port)
        timeline.note(await ConnectProbe.resolve(host: firstHop.0, port: firstHop.1))
        let tcp = await ConnectProbe.tcpConnect(host: firstHop.0, port: firstHop.1)
        timeline.note("tcp=\(tcp.map(ConnectTimeline.milliseconds) ?? "failed")")
        let clock = ContinuousClock()
        let keyImport = clock.measure { _ = try? makeAuthMethod(from: auth) }
        timeline.note("keyImport=\(ConnectTimeline.milliseconds(keyImport))")
        if profile.jumpHost != nil {
            timeline.note("viaJump")
        }
        timeline.exclude()
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

    static func packageHostKeyPolicy() -> USSHKit.SSHHostKeyPolicy {
        let raw = UserDefaults.standard.string(forKey: DefaultsKey.sshHostKeyPolicy)
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

    static func connectTimeoutSeconds() -> Int64 {
        let seconds = (UserDefaults.standard.object(forKey: DefaultsKey.sshConnectTimeout) as? Int) ?? 30
        return Int64(seconds)
    }
}
