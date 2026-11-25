import Foundation
import SwiftData

/// 一条规则「最近一次单连接开通道失败」：规则仍在服务（监听未拆、状态仍 active），但近期
/// 有入站连接开通道失败（如目标暂时不可达 / 服务器暂拒转发）。用于 UI 把「一直绿的已连接」
/// 纠正为「已连接·近期失败」，消除 wedge 期「显示已连接却连不上」的误导。
nonisolated struct ForwardingConnectionIssue: Sendable, Equatable {
    let reason: String
    let at: Date
}

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
    /// 每台主机**当前**的 host-key 审批 relay。每次 `start` / `ensureSession` / `retry`
    /// 都覆写（`obtainSession` 的第一件事）。
    ///
    /// 为什么要这张表：会话是按主机缓存的，第二次 `start` 会直接复用已有会话，传进来的
    /// relay 从此石沉大海。会话若捕获创建时那个 relay，挑战就会弹到**当初**那个 sheet
    /// 上 —— 窗口可能早关了，CLI 的 `forward-start` 更是每次都新造一个 relay。改成经
    /// `approveHostKey(serverID:challenge:)` 间接取当前 relay 后，UI 与 CLI 都拿得到挑战。
    @ObservationIgnored private var relays: [UUID: HostKeyChallengeRelay] = [:]
    /// 每台主机最近一个**有人回答**的 relay（窗口的 sheet；`HostKeyChallengeRelay.isInteractive`）。
    /// 后台重连只把问题投到这里，没有就直接拒绝：命令行 `forward-start` 的一次性 relay 请求一结束就没人轮询，
    /// 问题投进去会让建连永远等着、规则一直 `.starting`。
    @ObservationIgnored private var interactiveRelays: [UUID: HostKeyChallengeRelay] = [:]
    /// 每条规则的最新状态（观察源）。
    private var runtime: [UUID: TunnelStatus] = [:]
    /// 每条规则「最近一次单连接开通道失败」（观察源）。仅在规则仍 active 时写入，
    /// 状态转非 active / stop / teardown 时清除；读取时按 2 分钟窗口过期。
    private var connectionIssues: [UUID: ForwardingConnectionIssue] = [:]
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
    /// 探测/重连进行中标志：串行化 `probeConnectionHealth`（防心跳重入），并让「即时重连」
    /// 在心跳探测在跑时让路（交给探测的 step ② 处理），避免两路同时驱逐/重建互踩。
    @ObservationIgnored private var isProbing = false
    /// 仅测试用的流量注入（见 `injectTrafficForTesting`）。nil = 生产路径，零开销。
    @ObservationIgnored private var injectedTraffic: [UUID: TunnelBytes]?

    private struct ReconnectContext {
        let server: ServerProfile
        // 不存 relay：重连时问 `interactiveRelays` 要界面当前的那个（见 `reconnectRelay`）。以前存的是建上下文
        // 那一刻的 relay，第一个是命令行 `forward-start` 的一次性 relay 时，之后重连的问题就投进没人看的地方。
        let modelContainer: ModelContainer
        var rules: [UUID: ForwardingRuleSnapshot]
    }

    init() {}

    // MARK: - 查询

    /// 某条规则的当前状态。未知规则视作 `.inactive`。
    func status(_ ruleID: UUID) -> TunnelStatus {
        runtime[ruleID] ?? .inactive
    }

    /// 某规则最近一次单连接开通道失败（仅在近 2 分钟内有意义）。nil = 无近期失败。
    /// UI 据此在「已连接」旁提示近期失败，让 wedge 期「显示已连接却连不上」不再无声。
    func connectionIssue(_ ruleID: UUID) -> ForwardingConnectionIssue? {
        guard let issue = connectionIssues[ruleID] else { return nil }
        guard Date().timeIntervalSince(issue.at) < 120 else { return nil }
        return issue
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
        var merged: [UUID: TunnelBytes] = injectedTraffic ?? [:]
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
            rememberForReconnect(rule, server: server, modelContainer: modelContainer)
        }
        // 单 Task：先 await connect 屏障，再依次开各隧道；connect 失败 → 把这批
        // 自启规则统一标成分类后的 .error（真实原因），不再卡在 generic 状态。
        Task { @MainActor in
            do {
                try await self.ensureConnected(server.id)
                guard self.sessions[server.id] === session else { return }
                for rule in autostart { await session.start(rule) }
            } catch {
                // 窗口关了（teardown 取消了建连）或会话已经换成了新的：这批状态不归它管了，什么都不写。
                guard !(error is CancellationError), self.sessions[server.id] === session else { return }
                let e = error
                for rule in autostart {
                    self.runtime[rule.id] = .error(ForwardingError.classify(e, rule: rule))
                    self.stopAutoReconnectIfPermanent(e, ruleID: rule.id, serverID: server.id)
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
        start(rule, on: server, optionalRelay: relay, modelContainer: modelContainer)
    }

    /// `relay` 为 nil：后台重连、没有界面可问，主机密钥 / 连接方式的问题一律拒绝（规则停在 `.error`，不挂住）。
    private func start(_ rule: ForwardingRuleSnapshot,
                       on server: ServerProfile,
                       optionalRelay relay: HostKeyChallengeRelay?,
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
        rememberForReconnect(rule, server: server, modelContainer: modelContainer)
        // 单 Task：先 await connect 屏障，再开隧道；只有 connect 失败才在此处分类报 error
        // （隧道自身的 active/error 由 session.start 经 onStatus 回报）。
        Task { @MainActor in
            do {
                try await self.ensureConnected(server.id)
                guard self.sessions[server.id] === session else { return }
                await session.start(rule)
            } catch {
                guard !(error is CancellationError), self.sessions[server.id] === session else { return }
                self.runtime[rule.id] = .error(ForwardingError.classify(error, rule: rule))
                self.stopAutoReconnectIfPermanent(error, ruleID: rule.id, serverID: server.id)
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
        connectionIssues[ruleID] = nil
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
        // 窗口关 / 主机断 → 不再自动重连该主机，当前 relay 也随之作废
        //（留着只会让下一次挑战弹到一个已经不在屏幕上的 sheet）。
        reconnectContexts[serverID] = nil
        relays[serverID] = nil
        interactiveRelays[serverID] = nil
        guard let session = sessions.removeValue(forKey: serverID) else { return }
        // 清理该主机所有规则的运行时状态。
        for (ruleID, owner) in ruleServer where owner == serverID {
            runtime[ruleID] = .inactive
            connectionIssues[ruleID] = nil
            ruleServer[ruleID] = nil
        }
        Task { await session.close() }
    }

    // MARK: - host-key 审批

    /// 会话的 host-key 审批出口：把挑战交给该主机**当前**的 relay。
    ///
    /// 会话在 `obtainSession` 里捕获的是这个方法（经一个 `@Sendable` 闭包），不是创建时
    /// 那个 relay —— 于是「已有会话被复用」时挑战也能弹到最新的 sheet / CLI relay 上。
    /// 没有登记 relay（主机已 teardown）时一律拒绝，绝不静默 TOFU。
    func approveHostKey(serverID: UUID, challenge: HostKeyChallenge) async -> Bool {
        guard let relay = relays[serverID] else { return false }
        return await relay.makeApprover()(challenge)
    }

    /// 命令行 `forward-start` 等完了：它的一次性 relay 不再有人轮询。还是「当前 relay」的话换回界面的那个
    /// （没有就是没人可问，之后的问题一律拒绝），免得重连、复用会话时的问题投进去把建连挂住。
    func releaseRelay(_ relay: HostKeyChallengeRelay, serverID: UUID) {
        guard relays[serverID] === relay else { return }
        relays[serverID] = interactiveRelays[serverID]
    }

    /// 后台重连用的 relay：界面当前的那个，没有就 nil（问题一律拒绝）。
    private func reconnectRelay(_ serverID: UUID) -> HostKeyChallengeRelay? {
        interactiveRelays[serverID]
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

    /// 会话经数据通路确认判死、自拆后调用（`ForwardingSession.onTransportDeath`）：立即驱逐
    /// 并按「期望运行」规则重连，不必等看门狗 30s 心跳。守卫：
    /// - `isProbing`：心跳探测正在跑 → 让路（其 step ② 会处理这台被判死的主机），防互踩；
    /// - `sessions[serverID] == nil`：已被驱逐 / 已重连过 → 跳过，防重复重连。
    /// 本方法同步执行（无 await，@MainActor 原子），`start()` 内部再异步建连。
    private func reconnectAfterDeath(_ serverID: UUID) {
        guard !isProbing, sessions[serverID] != nil else { return }
        evictSession(serverID)
        guard let ctx = reconnectContexts[serverID], !ctx.rules.isEmpty else { return }
        AppLogger.info("转发即时重连 \(ctx.server.host)：\(ctx.rules.count) 条规则",
                       category: ForwardingLog.category)
        for rule in ctx.rules.values {
            start(rule, on: ctx.server, optionalRelay: reconnectRelay(serverID), modelContainer: ctx.modelContainer)
        }
    }

    /// 建连失败是重试也不会好的那种（凭据被拒、主机密钥被拒、握手协商不成）：这条规则不再跟着看门狗每 30 秒
    /// 自动重连，停在 `.error` 等用户处理后点「重试」（`retry` → `start` 会重新登记）。
    private func stopAutoReconnectIfPermanent(_ error: Error, ruleID: UUID, serverID: UUID) {
        guard SSHTransportFailure.isPermanentConnectFailure(error) else { return }
        reconnectContexts[serverID]?.rules[ruleID] = nil
    }

    /// 记住一条「期望运行」的规则 + 其重建上下文，供看门狗判死后自动重连。
    private func rememberForReconnect(_ rule: ForwardingRuleSnapshot,
                                     server: ServerProfile,
                                     modelContainer: ModelContainer) {
        if var ctx = reconnectContexts[server.id] {
            ctx.rules[rule.id] = rule
            reconnectContexts[server.id] = ctx
        } else {
            reconnectContexts[server.id] = ReconnectContext(
                server: server, modelContainer: modelContainer,
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
                               relay: HostKeyChallengeRelay?,
                               modelContainer: ModelContainer) -> ForwardingSession? {
        // 注册到看门狗（幂等、弱引用）：系统唤醒 / 网络恢复后主动探测各主机的
        // 专用转发连接，半死隧道不再顶着 active 徽标静默挂着。放在会话创建的
        // 单一漏斗处 —— 从未用过转发的用户不触发注册。
        ConnectionWatchdog.shared.register(self)
        // 先记下**这一次**传进来的 relay：会话复用时也要更新，否则挑战会弹到上一个
        // relay（可能是已关窗口的 sheet，或 CLI 上一次 forward-start 的临时 relay）。
        relays[server.id] = relay
        if let relay, relay.isInteractive { interactiveRelays[server.id] = relay }
        if let existing = sessions[server.id] { return existing }

        // 认证解析：与终端 / CLI 同一条规则（跳板机凭据缺了报错，不直连）。
        // 同步读钥匙串 —— 会话必须在这里同步登记进 `sessions`，后来的 start 才能复用同一条屏障。
        let resolved: (auth: ResolvedAuth, jump: ResolvedAuth?)
        do {
            resolved = try SSHAuthResolver.resolveForConnect(profile: server, keychain: KeychainStore())
        } catch {
            AppLogger.error("转发认证解析失败 \(server.host)：\(error.localizedDescription)",
                            category: ForwardingLog.category)
            return nil
        }

        let verifier = HostKeyVerifier(modelContainer: modelContainer)
        // 间接层：会话捕获的是「问协调器要当前 relay」这个动作，而不是当下这个 relay 对象。
        let approverServerID = server.id
        let approver: @Sendable (HostKeyChallenge) async -> Bool = { [weak self] challenge in
            guard let self else { return false }
            return await self.approveHostKey(serverID: approverServerID, challenge: challenge)
        }

        // onStatus：后台线程触发 → 跳回主 actor 写观察字典（绝不用 DispatchQueue.async）。
        let onStatus: @Sendable (UUID, TunnelStatus) -> Void = { [weak self] ruleID, status in
            Task { @MainActor in
                self?.runtime[ruleID] = status
                // 非 active（重启/失败/停止）→ 清掉「近期连接失败」提示，让更强的状态接管。
                if status != .active { self?.connectionIssues[ruleID] = nil }
            }
        }
        // 单连接开通道失败（规则仍 active、监听继续服务）→ 记录，供行内「已连接·近期失败」提示。
        let onConnectionIssue: @Sendable (UUID, String) -> Void = { [weak self] ruleID, reason in
            Task { @MainActor in
                guard self?.runtime[ruleID] == .active else { return }
                self?.connectionIssues[ruleID] = ForwardingConnectionIssue(reason: reason, at: Date())
            }
        }

        // 会话经数据通路确认判死、自拆后：立即驱逐 + 按期望规则重连（不必等 30s 心跳）。
        let serverID = server.id
        let onTransportDeath: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.reconnectAfterDeath(serverID) }
        }
        let session = ForwardingSession(
            profile: SSHConnection.ProfileSnapshot(server),
            auth: resolved.auth,
            jumpHostAuth: resolved.jump,
            hostKeyVerifier: verifier,
            hostKeyApprover: approver,
            onStatus: onStatus,
            onTransportDeath: onTransportDeath,
            onConnectionIssue: onConnectionIssue)
        sessions[server.id] = session

        // 建立 connect 屏障（每台主机一条，connect 只在此发起一次）。所有 start 路径
        // 经 `ensureConnected(_:)` await 它后才调用 `session.start`，从而保证 start
        // 总在 connect 成功之后运行 —— 消除「连接尚未建立」的虚假错误。失败时把错误
        // 向上 rethrow，由各 start 路径分类成受影响规则的 `.error`（真实原因）。
        connectTasks[server.id] = Task {
            do {
                try await session.connect()
            } catch is CancellationError {
                throw CancellationError()          // 窗口关了：不是失败，不记错误
            } catch {
                AppLogger.error("转发会话连接失败 \(server.host)：\(error.localizedDescription)",
                                category: ForwardingLog.category)
                throw error
            }
        }
        return session
    }

    // MARK: - 测试 seam

    /// 仅测试用：把建连屏障换成给定的任务（模拟还在握手的连接）。
    func injectConnectTaskForTesting(_ task: Task<Void, Error>, serverID: UUID) {
        connectTasks[serverID] = task
    }

    /// 仅测试用：绕过认证解析 / SwiftData，直接把现成会话挂到指定主机名下。
    func injectSessionForTesting(_ session: ForwardingSession, serverID: UUID) {
        sessions[serverID] = session
    }

    /// 仅测试用：某主机是否仍持有缓存会话（探测后被驱逐与否的观察点）。
    func hasSessionForTesting(serverID: UUID) -> Bool {
        sessions[serverID] != nil
    }

    /// 仅测试用：直接写一条规则的运行态。性能探针要在**没有任何真实会话**的前提下
    /// 造出 active / error 混排的行（`active` 才画流量列、`error` 才把状态徽标换成
    /// `Button`），否则量到的是一屏「未连接」，比真实界面便宜。
    func setStatusForTesting(_ status: TunnelStatus, for ruleID: UUID) {
        runtime[ruleID] = status
    }

    /// 仅测试用：让 `trafficSnapshot()` 额外返回一份注入的累计字节。
    /// 全局面板每秒拉一次快照算速率 —— 没有真实会话时快照恒空、行上永远不画流量列，
    /// 每秒那一拍的开销也就量不准。nil（默认）时零额外开销。
    func injectTrafficForTesting(_ bytes: [UUID: TunnelBytes]?) {
        injectedTraffic = bytes
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
        // 串行化：心跳重入 / 与「即时重连」并发会互踩驱逐。在跑就跳过（在跑的那次或下次心跳覆盖）。
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }
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
        for (serverID, ctx) in toReconnect {
            AppLogger.info(
                "转发自动重连 \(ctx.server.host)：\(ctx.rules.count) 条规则",
                category: ForwardingLog.category)
            for rule in ctx.rules.values {
                start(rule, on: ctx.server, optionalRelay: reconnectRelay(serverID), modelContainer: ctx.modelContainer)
            }
        }
    }
}
