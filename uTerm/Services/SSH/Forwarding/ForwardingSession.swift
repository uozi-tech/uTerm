import Foundation
import NIOCore
import NIOPosix
import USSHKit

/// 一条隧道的状态（由 `ForwardingCoordinator` 观察、驱动 UI 行）。
nonisolated enum TunnelStatus: Sendable, Equatable {
    case inactive
    case starting
    case active
    case error(ForwardingError)
}

/// 一条隧道的累计收发字节快照（上行=本地→远端，下行=远端→本地）。
nonisolated struct TunnelBytes: Sendable, Equatable {
    let up: UInt64
    let down: UInt64
    static let zero = TunnelBytes(up: 0, down: 0)
}

/// 一台主机的专用转发会话（actor），镜像 `SSHConnection` 的生命周期 / 防泄漏范式。
///
/// - `ConnectedClient` 在 connect 成功后由 actor 隔离字段持有，所有监听器 / 通道操作经它进行
///   （与 `SFTPSession` 一致）。`close()` 独占负责 teardown（`connected.close()`）。
/// - 每条规则一个 `TunnelHandle`：一个驱动 Task + 可选的本地监听 actor（local/dynamic）。
///   `stop` 取消 Task 并关监听；`close` 拆掉全部隧道再关连接。
/// - `connect()` 建立连接并持有 `ConnectedClient`。`start()` 在连接就绪后开隧道，
///   按 `kind` 分派到 `-R` / `-L` / `-D` 三条路径，并经 `onStatus` 回报状态。
actor ForwardingSession {

    // MARK: - 注入

    private let profile: SSHConnection.ProfileSnapshot
    private let auth: ResolvedAuth
    private let jumpHostAuth: ResolvedAuth?
    private let hostKeyVerifier: HostKeyVerifier
    private let hostKeyApprover: @Sendable (HostKeyChallenge) async -> Bool
    private let onStatus: @Sendable (UUID, TunnelStatus) -> Void
    /// 传输确认判死、会话自拆后回调（默认空，供测试/旧调用省略）。协调器据此**立即**驱逐并
    /// 按期望规则重连，不必等看门狗 30s 心跳。
    private let onTransportDeath: @Sendable () -> Void
    /// 单条入站连接开通道失败（规则仍 active、监听继续服务）时回报 (ruleID, 友好原因)，
    /// 供 UI 把「一直绿的已连接」纠正为「已连接·近期失败」，消除 wedge 期的误导。默认空。
    private let onConnectionIssue: @Sendable (UUID, String) -> Void

    // MARK: - 运行时

    /// 已建立的连接（仅在 connect 成功后、close 之前可用）。
    /// 与 `SFTPSession` 一致：监听器/通道操作都经它进行。
    private var connected: ConnectedClient?
    private var isClosed = false

    /// 每条规则的运行句柄。
    private struct TunnelHandle {
        let task: Task<Void, Never>
        /// 规则快照 —— 看门狗判死时构造 `.error` 文案（规则名）用。
        let rule: ForwardingRuleSnapshot
        /// local 的本地监听器；remote/dynamic 为 nil。
        let localListener: LocalForwardListener?
        /// dynamic 的本地 SOCKS5 监听器；remote/local 为 nil。
        let socksListener: SOCKS5ForwardListener?
        /// 本规则的流量计数器（-L/-D 由监听器喂，-R 由 `RemoteForwardBridge` 喂）。
        let counter: TunnelByteCounter
    }
    private var tunnels: [UUID: TunnelHandle] = [:]

    init(profile: SSHConnection.ProfileSnapshot,
         auth: ResolvedAuth,
         jumpHostAuth: ResolvedAuth?,
         hostKeyVerifier: HostKeyVerifier,
         hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool,
         onStatus: @escaping @Sendable (UUID, TunnelStatus) -> Void,
         onTransportDeath: @escaping @Sendable () -> Void = {},
         onConnectionIssue: @escaping @Sendable (UUID, String) -> Void = { _, _ in }) {
        self.profile = profile
        self.auth = auth
        self.jumpHostAuth = jumpHostAuth
        self.hostKeyVerifier = hostKeyVerifier
        self.hostKeyApprover = hostKeyApprover
        self.onStatus = onStatus
        self.onTransportDeath = onTransportDeath
        self.onConnectionIssue = onConnectionIssue
    }

    /// 安全网（仿 SSHConnection.deinit）：消费者未 close 就丢弃会话时，取消所有
    /// 隧道 Task。连接本身的关闭依赖 `close()` 被调用 —— `ForwardingCoordinator`
    /// 在 teardown 时负责调用，与 SFTP 窗口一致。
    deinit {
        for handle in tunnels.values { handle.task.cancel() }
    }

    // MARK: - connect

    /// 建立专用转发连接。失败抛出（由上层归类）。
    func connect() async throws {
        guard !isClosed else { throw SSHConnection.SSHConnectionError.alreadyClosed }
        let connected = try await SSHClientFactory.connect(
            profile: profile,
            auth: auth,
            jumpHostAuth: jumpHostAuth,
            hostKeyVerifier: hostKeyVerifier,
            hostKeyApprover: hostKeyApprover)
        self.connected = connected
        // 专用连接（不进共享池）：直接挂断开观察者，随连接一起释放。
        connected.onTransportClosed { [weak self] in
            Task { await self?.handleUnderlyingDisconnect() }
        }
        AppLogger.info("转发会话已连接 \(self.profile.host):\(self.profile.port)",
                       category: ForwardingLog.category)
    }

    // MARK: - start / stop

    /// 启动一条规则的隧道。按 `kind` 分派。重复启动同一规则先停旧的。
    func start(_ rule: ForwardingRuleSnapshot) async {
        guard !isClosed, let connected else {
            onStatus(rule.id, .error(ForwardingError(
                kind: .unknown, message: String(localized: "\(rule.name)：转发连接尚未建立"))))
            return
        }
        // 幂等：已在跑的先停。
        if tunnels[rule.id] != nil { await stop(rule.id) }
        onStatus(rule.id, .starting)

        switch rule.kind {
        case .remote:
            startRemote(rule, connected: connected)
        case .local:
            startLocal(rule, connected: connected)
        case .dynamic:
            startDynamic(rule, connected: connected)
        }
    }

    /// `-R` 远程：子 Task 跑 `withRemotePortForward`，`onOpen` 回报 active；
    /// Task 阻塞至取消；抛错 → 归类后报 error。
    ///
    /// USSHCore 给每条 forwarded-tcpip 通道装好 `ByteBuffer` 编解码并打开对端半关闭，在通道的 EventLoop 上、
    /// 激活之前包成 `NIOAsyncChannel` 交给 `onAccept`；这里像 `-L` 一样用 `TunnelGlue` 双向泵（顺带有了流量计数）。
    /// （2.1.2 以前 Citadel 的 `runRemotePortForward` 不加编解码，第一份数据到达就断言崩溃。）
    private func startRemote(_ rule: ForwardingRuleSnapshot, connected: ConnectedClient) {
        let onStatus = self.onStatus
        // remote 需要本地目标地址；缺失时退化到回环（与 ssh -R 默认一致）。
        let destHost = rule.destHost ?? "127.0.0.1"
        let destPort = rule.destPort
        let counter = TunnelByteCounter()
        let task = Task {
            do {
                try await connected.target.withRemotePortForward(
                    host: rule.listenHost,
                    port: rule.listenPort,
                    onOpen: { _ in
                        onStatus(rule.id, .active)
                        AppLogger.info(
                            "远程转发已建立 \(rule.listenHost):\(rule.listenPort) → \(destHost):\(rule.destPort)",
                            category: ForwardingLog.category)
                    },
                    onAccept: { inbound, _ in
                        await RemoteForwardBridge.serve(
                            inbound, destHost: destHost, destPort: destPort,
                            ruleName: rule.name, counter: counter)
                    })
                // 正常取消（stop）→ withRemotePortForward 返回，不报 error。
            } catch {
                if !Task.isCancelled {
                    onStatus(rule.id, .error(ForwardingError.classify(error, rule: rule)))
                    AppLogger.error(
                        "远程转发失败 \(rule.name)：\(error.localizedDescription)",
                        category: ForwardingLog.category)
                }
            }
        }
        tunnels[rule.id] = TunnelHandle(task: task, rule: rule, localListener: nil,
                                        socksListener: nil, counter: counter)
    }

    /// `-L` 本地：起 `LocalForwardListener`，bind 失败归类报 error。
    private func startLocal(_ rule: ForwardingRuleSnapshot, connected: ConnectedClient) {
        let counter = TunnelByteCounter()
        let listener = LocalForwardListener(
            connected: connected,
            listenHost: rule.listenHost, listenPort: rule.listenPort,
            destHost: rule.destHost ?? "127.0.0.1", destPort: rule.destPort,
            counter: counter,
            onChannelFailure: { [weak self] error in
                Task { await self?.handleForwardChannelFailure(rule, error: error) }
            },
            onTunnelClosed: { [weak self] outcome in
                Task { await self?.handleTunnelClosed(rule, outcome: outcome) }
            })
        let onStatus = self.onStatus
        // 驱动 Task：start() 抛错（bind 冲突）→ 归类报 error；成功 → active。
        let task = Task {
            do {
                try await listener.start()
                onStatus(rule.id, .active)
            } catch {
                onStatus(rule.id, .error(ForwardingError.classify(error, rule: rule)))
                AppLogger.error("本地转发失败 \(rule.name)：\(error.localizedDescription)",
                                category: ForwardingLog.category)
            }
        }
        tunnels[rule.id] = TunnelHandle(task: task, rule: rule, localListener: listener,
                                        socksListener: nil, counter: counter)
    }

    /// `-D` 动态：起 `SOCKS5ForwardListener`，bind 失败归类报 error。
    private func startDynamic(_ rule: ForwardingRuleSnapshot, connected: ConnectedClient) {
        let counter = TunnelByteCounter()
        let listener = SOCKS5ForwardListener(
            connected: connected,
            listenHost: rule.listenHost, listenPort: rule.listenPort,
            counter: counter,
            // 同 -L：开通道超时 / 传输层错误说明转发平面死了，拆掉整条会话重建（控制面的探活可能还通）。
            onChannelFailure: { [weak self] error in
                Task { await self?.handleForwardChannelFailure(rule, error: error) }
            })
        let onStatus = self.onStatus
        let task = Task {
            do {
                try await listener.start()
                onStatus(rule.id, .active)
            } catch {
                onStatus(rule.id, .error(ForwardingError.classify(error, rule: rule)))
                AppLogger.error("动态转发失败 \(rule.name)：\(error.localizedDescription)",
                                category: ForwardingLog.category)
            }
        }
        tunnels[rule.id] = TunnelHandle(task: task, rule: rule, localListener: nil,
                                        socksListener: listener, counter: counter)
    }

    /// 当前所有隧道的累计流量快照（按 ruleID）。`ForwardingCoordinator` 周期拉取算速率。
    func trafficSnapshot() -> [UUID: TunnelBytes] {
        var out: [UUID: TunnelBytes] = [:]
        for (id, handle) in tunnels {
            let s = handle.counter.snapshot
            out[id] = TunnelBytes(up: s.up, down: s.down)
        }
        return out
    }

    /// 停止一条规则：取消驱动 Task + 关闭其监听器。报回 inactive。
    func stop(_ ruleID: UUID) async {
        guard let handle = tunnels.removeValue(forKey: ruleID) else { return }
        handle.task.cancel()
        await handle.localListener?.close()
        await handle.socksListener?.close()
        // remote 隧道靠取消 Task 触发 withRemotePortForward 内部的 cancellation 请求。
        onStatus(ruleID, .inactive)
    }

    // MARK: - close

    /// 拆掉所有隧道并关闭底层连接。幂等。
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        for (ruleID, handle) in tunnels {
            handle.task.cancel()
            await handle.localListener?.close()
            await handle.socksListener?.close()
            onStatus(ruleID, .inactive)
        }
        tunnels.removeAll()
        // 关闭底层 SSH 连接（先目标、再跳板机）。connect 失败 / 从未连接时为 nil，无害。
        await connected?.close()
        connected = nil
        AppLogger.info("转发会话已关闭 \(self.profile.host):\(self.profile.port)",
                       category: ForwardingLog.category)
    }

    // MARK: - 存活探测

    /// 主动探测底层 SSH 传输是否存活（系统唤醒 / 网络恢复后由
    /// `ForwardingCoordinator.probeConnectionHealth` 调用）。
    ///
    /// 长时间待机断网形成的半死 TCP 上，本地监听端口还在，但新转发连接建不
    /// 起来或挂死，规则状态却停在 active。与 `SSHConnection.verifyConnectionAlive`
    /// 一致：在专用转发连接上开一次性 exec channel 跑 `true`（与隧道通道
    /// 多路复用、不影响在跑的转发）：
    /// - 任何应答（含服务器拒开 channel 等应用层失败）都证明传输活着，
    ///   只有超时 / 传输层错误才判死；
    /// - 判死 → 强制关闭底层连接（本地操作、立即完成，同时解除可能挂死的
    ///   探测子任务），再 `failTunnelsAfterTransportDeath()` 拆掉全部隧道。
    ///   此后本会话不可复用 —— 调用方负责丢弃它，使「重试」重建连接；
    /// - 连接尚未建立（connect 在飞或已失败）时无从探测，返回 true：在飞的
    ///   connect 会自行成功或经既有 start 路径报错，绝不能在这里误杀。
    func verifyConnectionAlive() async -> Bool {
        await verifyConnectionAlive(timeout: .seconds(10))
    }

    func verifyConnectionAlive(timeout: Duration) async -> Bool {
        guard !isClosed else { return false }
        guard let connected else { return true }
        do {
            _ = try await withForwardingTimeout(timeout) {
                try await connected.exec("true")
            }
            return true
        } catch {
            // 任何应用层拒开 exec channel 仍证明 SSH 传输活着；只有传输错误/超时判死。
            guard SSHTransportFailure.isTransportFailure(error) || error is ForwardingTimeoutError else {
                return true
            }
            await failTunnelsAfterTransportDeath()
            return false
        }
    }

    /// 单条入站连接无法打开 direct-tcpip 通道时的处理。普通目标拒绝/不可达只记录近期失败，
    /// 监听继续服务；但「开通道超时」和传输层错误说明 SSH forwarding plane 已经不可用：
    /// 控制面的 `exec true` 仍可能成功，不能再用它放过这个状态，否则就会出现“监听还在、
    /// UI 绿灯，但应用层永远连不上”。这类错误直接拆整条转发会话，让保持连接立即重建。
    private func handleForwardChannelFailure(_ rule: ForwardingRuleSnapshot, error: Error) async {
        guard !isClosed, tunnels[rule.id] != nil else { return }
        if Self.requiresSessionRestart(error) {
            AppLogger.error(
                "转发开通道失败，重建会话 \(rule.name)：\(FriendlyError.describe(error))",
                category: ForwardingLog.category)
            await failTunnelsAfterTransportDeath()
            return
        }

        let reason = FriendlyError.describe(error)
        // 规则仍 active、监听继续服务其他连接；把这次失败回报 UI，纠正「一直绿的已连接」误导。
        onConnectionIssue(rule.id, reason)
        AppLogger.info(
            "转发单连接开通道失败（目标侧问题，保留规则继续服务）\(rule.name)：\(reason)",
            category: ForwardingLog.category)
    }

    /// 一条隧道结束时的概况处理。识别「开通道成功但后端瞬间 0 字节 EOF」——`openDirectTCPIP`
    /// 在 CHANNEL_OPEN_CONFIRMATION 就 resolve（此时尚无数据），跳板机随后 upstream connect 目标
    /// 失败会立刻 EOF 该通道；`TunnelGlue.pipe` 把它当普通空隧道吞掉、`onChannelFailure`（只在
    /// 开通道失败时触发）从不被调用，于是规则一直显示已连接、访问却立刻 EOF、须重启才好。
    ///
    /// 处理：只做可见性、按目标侧失败回报 UI（amber），**不重建会话**——该失败在服务器/后端侧
    /// （跳板机到目标的 upstream connect 失败），重建本会话既不会让后端变可达、又会拖垮同主机
    /// 其它转发。有任何回程数据即视作转发正常，不误报（客户端主动断开 = 本地先关，也不算疑似）。
    private func handleTunnelClosed(_ rule: ForwardingRuleSnapshot, outcome: TunnelOutcome) async {
        guard !isClosed, tunnels[rule.id] != nil else { return }
        guard outcome.suspectsInstantClose else { return }
        let reason = String(localized: "目标连接被立即关闭（无数据返回），后端可能暂时不可用")
        onConnectionIssue(rule.id, reason)
        AppLogger.info(
            "转发开通道成功但远端 0 字节即关（后端侧问题，保留规则继续服务）\(rule.name)：\(reason)",
            category: ForwardingLog.category)
    }

    /// 是否需要重建整条转发会话：传输层错误，或 opening direct-tcpip 超时。
    private static func requiresSessionRestart(_ error: Error) -> Bool {
        SSHTransportFailure.isTransportFailure(error) || error is ForwardingTimeoutError
    }

    private func handleUnderlyingDisconnect() async {
        guard !isClosed else { return }
        AppLogger.error("转发 SSH 底层连接断开 \(self.profile.host):\(self.profile.port)",
                        category: ForwardingLog.category)
        await failTunnelsAfterTransportDeath()
    }

    /// 判死收尾：置 `isClosed`（后续 start 直接报错，不在死连接上挂死）、
    /// 拆掉全部隧道 —— 本地监听器关闭（半死端口不再静默吞新连接）、每条
    /// 规则报 `.error`（UI 行出现「重试」入口）。底层连接已在探测路径强制
    /// 关闭。与并发而至的 `close()` 互为幂等（先到者置 isClosed，后到者跳过）。
    private func failTunnelsAfterTransportDeath() async {
        guard !isClosed else { return }
        isClosed = true
        for (ruleID, handle) in tunnels {
            handle.task.cancel()
            await handle.localListener?.close()
            await handle.socksListener?.close()
            onStatus(ruleID, .error(.connectionLost(rule: handle.rule)))
        }
        tunnels.removeAll()
        await connected?.close()
        connected = nil
        AppLogger.error("转发连接判死 \(self.profile.host):\(self.profile.port)，已拆除全部隧道",
                        category: ForwardingLog.category)
        // 通知协调器立即驱逐+按期望规则重连（不必等看门狗 30s 心跳）。
        onTransportDeath()
    }
}

// MARK: - -R 的入站连接

/// 一条 -R 入站连接：连本机目标，然后和 forwarded-tcpip 通道双向泵。
nonisolated enum RemoteForwardBridge {
    /// 本机目标几秒连不上就放弃这条连接（目标是本机或局域网，正常是毫秒级）。
    static let connectTimeout: TimeAmount = .seconds(10)

    static func serve(
        _ inbound: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        destHost: String,
        destPort: Int,
        ruleName: String,
        counter: TunnelByteCounter
    ) async {
        let local: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            local = try await ClientBootstrap(group: inbound.channel.eventLoop)
                .connectTimeout(connectTimeout)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .connect(host: destHost, port: destPort)
                .flatMapThrowing { channel in
                    // flatMapThrowing 跑在 channel 的 EventLoop 上：wrappingChannelSynchronously 的前提。
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(isOutboundHalfClosureEnabled: true))
                }
                .get()
        } catch {
            AppLogger.error(
                "远程转发 \(ruleName)：连不上本机目标 \(destHost):\(destPort)（\(error.localizedDescription)）",
                category: ForwardingLog.category)
            // inbound 还没被消费：必须经 executeThenClose 收尾（它会 finish 出站 writer）。
            // 只 close 的话 writer 析构时没 finish → NIO preconditionFailure 把整个进程带走。
            try? await inbound.executeThenClose { _, _ in }
            return
        }
        // 上行 = 本机 → 远端，与 -L 的计数方向一致。
        await TunnelGlue.pipe(local, inbound, counter: counter)
    }
}
