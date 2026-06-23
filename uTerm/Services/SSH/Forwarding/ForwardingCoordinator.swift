import Foundation
import SwiftData

/// 转发协调器（app 级，注入 environment）。`@MainActor @Observable`。
///
/// - 每台主机一条专用 `ForwardingSession`（keyed by `serverID`）。
/// - 观察字典 `runtime: [ruleID: TunnelStatus]` 驱动 UI 行与标题栏徽章；
///   `ForwardingSession` 的 `onStatus` 回调在后台线程触发，统一用
///   `Task { @MainActor in }` 跳回主 actor 写字典（绝不用 DispatchQueue.async）。
/// - 认证解析在 `@MainActor` 完成（`KeychainStore` + `SSHAuthResolver` +
///   `HostKeyVerifier(modelContainer:)` + `relay.makeApprover()`），与
///   `FileBrowserModel.makeLiveSFTPProvider` 一致；解析出的 `ResolvedAuth`/闭包
///   都是 `Sendable`，可安全交给 actor。
@MainActor
@Observable
final class ForwardingCoordinator {

    /// 每台主机一条会话。
    @ObservationIgnored private var sessions: [UUID: ForwardingSession] = [:]
    /// 每条规则的最新状态（观察源）。
    private var runtime: [UUID: TunnelStatus] = [:]
    /// 规则 → 所属主机，供 `activeCount(forServer:)` 反查。
    @ObservationIgnored private var ruleServer: [UUID: UUID] = [:]
    /// 每台主机一条 connect 屏障（keyed by serverID）：所有 start 路径在调用
    /// `session.start` 前先 `await` 它。connect 只发生一次（并发 await 同一 Task），
    /// 消除「connect 还在挂起、start 先跑」导致的虚假「转发连接尚未建立」错误。
    @ObservationIgnored private var connectTasks: [UUID: Task<Void, Error>] = [:]
    /// 每台主机的「自动重连上下文」：重建会话所需的 server/relay/modelContainer + 当前
    /// **期望运行**的规则快照。看门狗判死后据此自动重连（见 `probeConnectionHealth`）。
    /// 规则在 start/autostart 时加入、stop 时移除、teardown 时整条清掉 —— 用户关掉的规则
    /// 或关掉的窗口不再自动重连。
    @ObservationIgnored private var reconnectContexts: [UUID: ReconnectContext] = [:]

    private struct ReconnectContext {
        let server: ServerProfile
        let relay: HostKeyChallengeRelay
        let modelContainer: ModelContainer
        var rules: [UUID: ForwardingRuleSnapshot]
    }

    init() {}

    // MARK: - 查询

    /// 某条规则的当前状态。未知规则视作 `.inactive`。
    func status(_ ruleID: UUID) -> TunnelStatus {
        runtime[ruleID] ?? .inactive
    }

    /// 某主机当前 active 的隧道数（驱动标题栏绿色徽章）。
    func activeCount(forServer serverID: UUID) -> Int {
        runtime.reduce(into: 0) { count, entry in
            guard ruleServer[entry.key] == serverID else { return }
            if entry.value == .active { count += 1 }
        }
    }

    /// 跨所有主机会话的累计流量快照（按 ruleID）。全局面板每秒拉一次算速率 + 累计。
    /// 逐会话 await（会话数很少）；ruleID 全局唯一，直接合并不会撞键。
    func trafficSnapshot() async -> [UUID: TunnelBytes] {
        var merged: [UUID: TunnelBytes] = [:]
        for session in sessions.values {
            for (id, bytes) in await session.trafficSnapshot() {
                merged[id] = bytes
            }
        }
        return merged
    }

    // MARK: - 会话生命周期

    /// 窗口打开时调用：确保该主机会话存在，并拉起所有 autostart 规则。
    func ensureSession(for server: ServerProfile,
                       autostart rules: [ForwardingRuleSnapshot],
                       relay: HostKeyChallengeRelay,
                       modelContainer: ModelContainer) {
        let autostart = rules.filter(\.autostart)
        guard let session = obtainSession(for: server, relay: relay, modelContainer: modelContainer)
        else {
            // 认证解析失败：把待自启规则全部标成分类后的 error（而非静默卡住）。
            for rule in autostart {
                ruleServer[rule.id] = server.id
                runtime[rule.id] = .error(ForwardingError.classify(authResolutionError(server), rule: rule))
            }
            return
        }
        for rule in autostart {
            ruleServer[rule.id] = server.id
            runtime[rule.id] = .starting
            rememberForReconnect(rule, server: server, relay: relay, modelContainer: modelContainer)
        }
        // 单 Task：先 await connect 屏障，再依次开各隧道；connect 失败 → 把这批
        // 自启规则统一标成分类后的 .error（真实原因），不再卡在 generic 状态。
        Task { @MainActor in
            do {
                try await self.ensureConnected(server.id)
                for rule in autostart { await session.start(rule) }
            } catch {
                let e = error
                for rule in autostart {
                    self.runtime[rule.id] = .error(ForwardingError.classify(e, rule: rule))
                }
                self.evictSession(server.id)
            }
        }
    }

    /// 启动单条规则（行开关打开 / 新建后立即启动）。
    func start(_ rule: ForwardingRuleSnapshot,
               on server: ServerProfile,
               relay: HostKeyChallengeRelay,
               modelContainer: ModelContainer) {
        guard let session = obtainSession(for: server, relay: relay, modelContainer: modelContainer)
        else {
            // 认证解析失败：把这条规则标成分类后的 error（而非静默返回）。
            ruleServer[rule.id] = server.id
            runtime[rule.id] = .error(ForwardingError.classify(authResolutionError(server), rule: rule))
            return
        }
        ruleServer[rule.id] = server.id
        runtime[rule.id] = .starting
        rememberForReconnect(rule, server: server, relay: relay, modelContainer: modelContainer)
        // 单 Task：先 await connect 屏障，再开隧道；只有 connect 失败才在此处分类报 error
        // （隧道自身的 active/error 由 session.start 经 onStatus 回报）。
        Task { @MainActor in
            do {
                try await self.ensureConnected(server.id)
                await session.start(rule)
            } catch {
                self.runtime[rule.id] = .error(ForwardingError.classify(error, rule: rule))
                self.evictSession(server.id)
            }
        }
    }

    /// 停止单条规则（行开关关闭）。
    func stop(_ ruleID: UUID) {
        // 用户主动停 → 不再是「期望运行」，从自动重连上下文移除。
        if let serverID = ruleServer[ruleID] {
            reconnectContexts[serverID]?.rules[ruleID] = nil
        }
        guard let serverID = ruleServer[ruleID], let session = sessions[serverID] else {
            runtime[ruleID] = .inactive
            return
        }
        runtime[ruleID] = .inactive
        Task { await session.stop(ruleID) }
    }

    /// 重试（error 行的「重试」按钮）。
    func retry(_ rule: ForwardingRuleSnapshot,
               on server: ServerProfile,
               relay: HostKeyChallengeRelay,
               modelContainer: ModelContainer) {
        start(rule, on: server, relay: relay, modelContainer: modelContainer)
    }

    /// 拆掉某主机会话（窗口关 / 主机断）。
    func teardown(serverID: UUID) {
        // 取消并丢弃 connect 屏障，使重新打开时重新发起连接。
        connectTasks.removeValue(forKey: serverID)?.cancel()
        // 窗口关 / 主机断 → 不再自动重连该主机。
        reconnectContexts[serverID] = nil
        guard let session = sessions.removeValue(forKey: serverID) else { return }
        // 清理该主机所有规则的运行时状态。
        for (ruleID, owner) in ruleServer where owner == serverID {
            runtime[ruleID] = .inactive
            ruleServer[ruleID] = nil
        }
        Task { await session.close() }
    }

    // MARK: - 私有

    /// connect 屏障：所有 start 路径在调用 `session.start` 前先 await 它。
    /// 等一个已完成的 Task 会立即返回；并发调用者 await 同一个 Task（connect 只跑一次）。
    /// 连接失败时把 connect 抛出的错误向上 rethrow，由调用方分类成各规则的 `.error`。
    private func ensureConnected(_ serverID: UUID) async throws {
        try await connectTasks[serverID]?.value
    }

    /// 清掉缓存的会话与连接屏障，使下一次 start/retry 能重建连接并真正重连。
    /// 两个调用点：①连接阶段失败（此时该 server 名下不可能有在跑的隧道）；
    /// ②看门狗判死（会话已在 actor 内部拆光隧道并把各规则翻成 `.error`）。
    /// 只动 `connectTasks`/`sessions`，不碰 `runtime`/`ruleServer`（保留刚写入的 `.error` 给 UI）。
    private func evictSession(_ serverID: UUID) {
        connectTasks[serverID]?.cancel()
        connectTasks[serverID] = nil
        sessions[serverID] = nil
    }

    /// 记住一条「期望运行」的规则 + 其重建上下文，供看门狗判死后自动重连。
    private func rememberForReconnect(_ rule: ForwardingRuleSnapshot,
                                     server: ServerProfile,
                                     relay: HostKeyChallengeRelay,
                                     modelContainer: ModelContainer) {
        if var ctx = reconnectContexts[server.id] {
            ctx.rules[rule.id] = rule
            reconnectContexts[server.id] = ctx
        } else {
            reconnectContexts[server.id] = ReconnectContext(
                server: server, relay: relay, modelContainer: modelContainer,
                rules: [rule.id: rule])
        }
    }

    /// 认证解析失败的兜底错误：交给 `ForwardingError.classify` 归类成 `.auth`。
    private func authResolutionError(_ server: ServerProfile) -> Error {
        NSError(domain: "ForwardingAuth", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "authenticationFailed: \(server.host)"
        ])
    }

    /// 取已有会话，或在 `@MainActor` 解析认证后构造一条新会话并建立 connect 屏障。
    /// 认证解析失败返回 nil —— 调用方据此把受影响规则标成分类后的 `.error`。
    /// 连接本身由 `connectTasks[serverID]` 这条屏障独占发起（不再单独 detach connect）。
    private func obtainSession(for server: ServerProfile,
                               relay: HostKeyChallengeRelay,
                               modelContainer: ModelContainer) -> ForwardingSession? {
        // 注册到看门狗（幂等、弱引用）：系统唤醒 / 网络恢复后主动探测各主机的
        // 专用转发连接，半死隧道不再顶着 active 徽标静默挂着。放在会话创建的
        // 单一漏斗处 —— 从未用过转发的用户不触发注册。
        ConnectionWatchdog.shared.register(self)
        if let existing = sessions[server.id] { return existing }

        // 认证解析 —— 镜像 FileBrowserModel.makeLiveSFTPProvider（@MainActor）。
        let keychain = KeychainStore()
        let auth: ResolvedAuth
        var jumpAuth: ResolvedAuth?
        do {
            auth = try SSHAuthResolver.resolve(profile: server, keychain: keychain)
            if let jump = server.jumpHost {
                jumpAuth = try SSHAuthResolver.resolve(profile: jump, keychain: keychain)
            }
        } catch {
            AppLogger.error("转发认证解析失败 \(server.host)：\(error.localizedDescription)",
                            category: ForwardingLog.category)
            return nil
        }

        let verifier = HostKeyVerifier(modelContainer: modelContainer)
        let approver = relay.makeApprover()

        // onStatus：后台线程触发 → 跳回主 actor 写观察字典（绝不用 DispatchQueue.async）。
        let onStatus: @Sendable (UUID, TunnelStatus) -> Void = { [weak self] ruleID, status in
            Task { @MainActor in
                self?.runtime[ruleID] = status
            }
        }

        let session = ForwardingSession(
            profile: SSHConnection.ProfileSnapshot(server),
            auth: auth,
            jumpHostAuth: jumpAuth,
            hostKeyVerifier: verifier,
            hostKeyApprover: approver,
            onStatus: onStatus)
        sessions[server.id] = session

        // 建立 connect 屏障（每台主机一条，connect 只在此发起一次）。所有 start 路径
        // 经 `ensureConnected(_:)` await 它后才调用 `session.start`，从而保证 start
        // 总在 connect 成功之后运行 —— 消除「连接尚未建立」的虚假错误。失败时把错误
        // 向上 rethrow，由各 start 路径分类成受影响规则的 `.error`（真实原因）。
        connectTasks[server.id] = Task {
            do {
                try await session.connect()
            } catch {
                AppLogger.error("转发会话连接失败 \(server.host)：\(error.localizedDescription)",
                                category: ForwardingLog.category)
                throw error
            }
        }
        return session
    }

    // MARK: - 测试 seam

    /// 仅测试用：绕过认证解析 / SwiftData，直接把现成会话挂到指定主机名下。
    func injectSessionForTesting(_ session: ForwardingSession, serverID: UUID) {
        sessions[serverID] = session
    }

    /// 仅测试用：某主机是否仍持有缓存会话（探测后被驱逐与否的观察点）。
    func hasSessionForTesting(serverID: UUID) -> Bool {
        sessions[serverID] != nil
    }
}

// MARK: - 连接健康探测（ConnectionWatchdog）

extension ForwardingCoordinator: ConnectionHealthProbing {
    /// 周期心跳（30s）/ 系统唤醒 / 网络恢复后由 `ConnectionWatchdog` 调用。两步：
    /// ① 并发探测各主机的专用转发连接，判死的驱逐（会话已在 actor 内部拆光隧道、关闭
    ///    本地监听、把各规则翻成 `.error`）。在飞的 connect（connected==nil）探测视作存活，
    ///    不会误杀。
    /// ② **自动重连**：对「有期望运行的规则、但当前无会话」的主机（刚被判死驱逐 / 上轮重连
    ///    失败被驱逐），走既有 `start()` 路径重建连接并拉起这些规则。每轮心跳重试一次 ——
    ///    天然 30s 退避；规则被用户停掉(stop)或窗口关闭(teardown)即从上下文移除、不再重连。
    ///    转连成功即恢复 active；仍失败则停在 `.error`（「重试」仍可手点），下轮再自动试。
    func probeConnectionHealth() async {
        // ① 探活 + 判死驱逐。
        if !sessions.isEmpty {
            // 镜像 `ConnectionWatchdog.sweep`：非结构化 Task 数组并发起跑、逐个等完
            // （region 隔离检查器不认 for-in + addTask 的捕获模式）。
            let probes = sessions.map { serverID, session in
                Task { (serverID, await session.verifyConnectionAlive()) }
            }
            for probe in probes {
                let (serverID, alive) = await probe.value
                if !alive { evictSession(serverID) }
            }
        }

        // ② 自动重连：先快照（start() 会回写 reconnectContexts/sessions，不能边迭代边改）。
        let toReconnect = reconnectContexts.filter { serverID, ctx in
            sessions[serverID] == nil && !ctx.rules.isEmpty
        }
        for (_, ctx) in toReconnect {
            AppLogger.info(
                "转发自动重连 \(ctx.server.host)：\(ctx.rules.count) 条规则",
                category: ForwardingLog.category)
            for rule in ctx.rules.values {
                start(rule, on: ctx.server, relay: ctx.relay, modelContainer: ctx.modelContainer)
            }
        }
    }
}
