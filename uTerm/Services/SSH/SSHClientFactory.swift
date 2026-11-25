import Foundation
import NIOCore
@_spi(uTermIntegration) import USSHKit

/// App-local compatibility view over USSHKit's SPI connection handle.
///
/// 来自 `SSHClientFactory.connectShared` 的实例是共享连接上的一份租约（`lease` 非 nil）：
/// `close()` 只归还租约，同一连接上的其他使用方不受影响；要判死整条连接用 `closeTransport()`。
nonisolated struct ConnectedClient: Sendable {
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

    /// 传输断开（含别的共享者判死后断开）时回调。共享连接走池子分发（池子按租约登记、归还时一起撤掉）。
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
    /// - 没有 `exec` 那道 64 000 字节的总量闸（超了整条抛 `SSHCommandError.outputTooLarge`，
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
        _ = target.onDisconnect { _ in handler() }
        _ = bastion?.onDisconnect { _ in handler() }
    }

    /// 不管有几个共享者，直接断开底层传输。看门狗判死时用：连接死了对谁都是死的，
    /// 池子通知这条连接上的所有使用方，各自走重连。共享连接先从池里摘掉再断开（`SharedConnectionPool.invalidate`），
    /// 断开还没完成的那几秒里新来的借用者拿到的是新连接，不是这条正在关的。
    func closeTransport() async {
        if let lease {
            await SharedSSHConnections.pool.invalidate(lease)
        } else {
            await shared.close()
        }
    }
}

/// USSHKit 的日志 → App 的日志（`ssh` 类别）。建连时交给它：比如「这台主机只能用旧算法」那一条警告
/// （metadata 里有 host、port、用上的旧算法）。
nonisolated struct AppSSHLogger: USSHKit.SSHLogger {
    func log(_ event: USSHKit.SSHLogEvent) {
        let details = event.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let text = details.isEmpty ? event.message : "\(event.message) \(details)"
        switch event.level {
        case .trace, .debug, .info:
            AppLogger.info(text, category: "ssh")
        case .warning:
            AppLogger.warn(text, category: "ssh")
        case .error:
            AppLogger.error(text, category: "ssh")
        }
    }
}

/// uTerm's model/UI adapter around the shared connection engine.
nonisolated enum SSHClientFactory {
    /// SSH 子通道（PTY / SFTP / direct-tcpip）的最大包长，决定每条子通道的入站窗口。
    ///
    /// NIOSSH 0.15 把每条子通道的入站窗口定为「最大包长 × 64」（`windowBytesPerPacket`），USSHCore 再把包长
    /// 夹进 `SSHClient.maximumPacketSizeRange`（32 KiB…512 KiB，即窗口 2 MiB…32 MiB）。所以要某个窗口就传
    /// 「窗口 ÷ 64」，见 `maximumPacketSize(forWindowBytes:)`。
    ///
    /// 终端、转发、共享连接原来要的是 1 MiB 窗口（SFTP 下载走 64 个在途 READ，128 KiB 的窗口只放得下 4 个，
    /// 流水线被窗口卡住；再往上只是让慢消费者——例如 UI 还没读走的终端输出——在内存里多攒数据，收益已饱和）。
    /// 1 MiB 低于现在能拿到的下限，取最接近的 2 MiB（包长 32 KiB）：每条子通道最多多压 1 MiB 内存，不会更慢。
    ///
    /// 这个设置是**每条 SSH 连接**级别的，同一连接上的终端 PTY 与端口转发通道拿到同一个窗口。跳板机那一跳
    /// 必须一起设，否则内层会话的全部流量还是挤在外层 direct-tcpip 通道的窗口里；`USSHKitIntegration.connect`
    /// 对直连与跳板机两跳一并应用。
    static let channelMaximumPacketSize = maximumPacketSize(forWindowBytes: 1 << 20)

    /// NIOSSH：每条子通道的入站窗口 = 最大包长 × 64。
    static let windowBytesPerPacket = 64

    /// 要 `bytes` 大小的子通道窗口时该传的最大包长（越界夹回 `maximumPacketSizeRange`）。大文件传输的专用连接
    /// 用更大的窗口（见 `ParallelTransfer`），终端 / 转发连接用上面那个。
    static func maximumPacketSize(forWindowBytes bytes: Int) -> Int {
        clampedMaximumPacketSize(bytes / windowBytesPerPacket)
    }

    /// USSHCore 允许的最大包长区间（它自己也会夹，这里先夹是为了让 app 里的数和真正生效的一致）。
    static let maximumPacketSizeRange: ClosedRange<Int> = SSHClient.maximumPacketSizeRange

    /// 把包长夹进 `maximumPacketSizeRange`。
    static func clampedMaximumPacketSize(_ raw: Int) -> Int {
        min(max(raw, maximumPacketSizeRange.lowerBound), maximumPacketSizeRange.upperBound)
    }

    /// - Parameters:
    ///   - hostKeyApprover: 问用户的出口。主机密钥之外，信任过的主机这次只肯用 SHA-1 时代的旧算法时也经它问
    ///     （`HostKeyChallenge.Kind.weakAlgorithms`，规则见 `LegacyAlgorithmGate`）。不能问用户的调用方返回 false，
    ///     这时抛 `SSHConnection.SSHConnectionError.weakAlgorithmsDeclined`。
    ///   - approvesInteractively: `hostKeyApprover` 真的会问人。为 false 时同一台主机同时在问的连接不和它合并
    ///     （它的「不」不能替正在弹框的标签答掉）。
    static func connect(
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        jumpHostAuth: ResolvedAuth?,
        hostKeyVerifier: HostKeyVerifier,
        hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool,
        approvesInteractively: Bool = true,
        maximumPacketSize: Int = SSHClientFactory.channelMaximumPacketSize
    ) async throws -> ConnectedClient {
        LocalNetworkUse.markUsed()
        let target = packageAuth(auth)
        let jumpHost: USSHKit.SSHJumpHost?
        if let jump = profile.jumpHost {
            guard let jumpHostAuth else {
                throw SSHConnection.SSHConnectionError.jumpHostFailed(String(localized: "缺少登录凭据"),
                                                                      cause: .authentication)
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

        let hostKeyPolicy = packageHostKeyPolicy()
        let legacyGate = LegacyAlgorithmGate(verifier: hostKeyVerifier, hostKeyPolicy: hostKeyPolicy,
                                             interactive: approvesInteractively, approver: hostKeyApprover)
        do {
            defer { timeline?.mark("handshake") }
            let shared = try await USSHKitIntegration.connect(
                endpoint: endpoint,
                credential: target.credential,
                hostKeyStore: hostKeyVerifier,
                hostKeyPolicy: hostKeyPolicy,
                connectTimeout: .seconds(connectTimeoutSeconds()),
                approver: packageApprover(hostKeyApprover),
                maximumPacketSize: maximumPacketSize,
                legacyFallbackApproval: legacyGate.approval,
                logger: AppSSHLogger()
            )
            legacyGate.connectionSucceeded(hops: profile.legacyGateHops)
            return ConnectedClient(shared: shared)
        } catch let error as USSHKit.SSHConnectionError {
            throw appError(error)
        } catch let error as CancellationError {
            // 取消（关窗口、关标签页）不是连接失败：原样交出去，调用方据此什么都不报。
            throw error
        } catch {
            let message = FriendlyError.describe(error)
            if profile.jumpHost != nil {
                throw SSHConnection.SSHConnectionError.jumpHostFailed(message)
            }
            throw SSHConnection.SSHConnectionError.connectFailed(message)
        }
    }

    /// USSHKit 的建连错误 → App 的。`switch` 里有 `default`，USSHKit 新加的错误编译器不会提醒，这里逐个列。
    static func appError(_ error: USSHKit.SSHConnectionError) -> SSHConnection.SSHConnectionError {
        // USSHKit 的 errorDescription 已自带「SSH 连接失败：」等前缀；这里只取正文再包一层
        // 本地前缀，避免用户看到「SSH 连接失败：SSH 连接失败：…」。
        switch error {
        case .legacyFallbackDeclined(let request), .jumpHostFailed(_, .legacyFallbackDeclined(let request)?):
            // 没同意用旧算法（哪一跳都一样）：用户自己的决定，不是网络问题，重连逻辑不在它上面打转。
            return .weakAlgorithmsDeclined(LegacyAlgorithmRefusal(request))
        case .jumpHostFailed(let message, let cause):
            // `cause` 是那一跳按直连规则归的类：认证 / 主机密钥 / 握手是配置问题，重连逻辑不在它上面打转。
            return .jumpHostFailed(message, cause: JumpHostFailureCause(cause))
        case .connectFailed(let message):
            return .connectFailed(message)
        case .authenticationFailed(let message):
            return .authenticationFailed(message)
        case .handshakeFailed(let message):
            return .handshakeFailed(message)
        case .hostKeyRejected(let message):
            return .hostKeyRejected(message)
        default:
            return .connectFailed(error.errorDescription ?? FriendlyError.describe(error))
        }
    }

    /// 终端与 SFTP 侧栏用：同一目标（含跳板机与认证材料）复用已有连接，见
    /// `SharedConnectionPool`。返回的是一份租约，`close()` 只归还租约。
    ///
    /// 同时到来的建连只握一次手，用的是第一个建连者的主机密钥审批回调；后来者直接复用
    /// 已经校验过主机密钥的连接。子通道窗口固定用 `channelMaximumPacketSize` —— 要更大窗口的
    /// 大文件传输走 `connect` 自己开专用连接。
    static func connectShared(
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        jumpHostAuth: ResolvedAuth?,
        hostKeyVerifier: HostKeyVerifier,
        hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool,
        approvesInteractively: Bool = true
    ) async throws -> ConnectedClient {
        let key = SharedSSHKey(profile: profile, auth: auth, jumpHostAuth: jumpHostAuth)
        // 不能问用户的建连（主机密钥一律拒绝）不和别人共用握手：它替同时打开的标签页答掉主机密钥问题的话，
        // 用户连确认框都看不到。已经建好的连接照样复用（那时候主机密钥已经定了）。
        let acquired = try await SharedSSHConnections.pool.acquire(key, sharesHandshake: approvesInteractively) {
            try await connect(
                profile: profile,
                auth: auth,
                jumpHostAuth: jumpHostAuth,
                hostKeyVerifier: hostKeyVerifier,
                hostKeyApprover: hostKeyApprover,
                approvesInteractively: approvesInteractively)
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

    /// 凭据 → USSHCore 的认证配置（私钥在这里解析）。给建连前单独量私钥解析耗时的探针与测试用。
    static func makeAuthMethod(from auth: ResolvedAuth) throws -> SSHAuthentication {
        let material = packageAuth(auth)
        do {
            return try USSHKitIntegration.makeAuthentication(
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

nonisolated extension SSHConnection.ProfileSnapshot {
    /// 这次连接的每一跳（跳板机在前），交给 `LegacyAlgorithmGate.connectionSucceeded(hops:)`。
    var legacyGateHops: [(host: String, port: Int)] {
        (jumpHost.map { [(host: $0.host, port: $0.port)] } ?? []) + [(host: host, port: port)]
    }
}
