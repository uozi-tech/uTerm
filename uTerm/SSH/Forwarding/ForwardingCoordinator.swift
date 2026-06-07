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

    /// 连接失败后清掉缓存的会话与连接屏障，使下一次 start/retry 能重建连接并真正重连。
    /// 仅在「连接阶段」失败时调用——此时该 server 名下不可能有在跑的隧道。
    /// 只动 `connectTasks`/`sessions`，不碰 `runtime`/`ruleServer`（保留刚写入的 `.error` 给 UI）。
    private func evictSession(_ serverID: UUID) {
        connectTasks[serverID]?.cancel()
        connectTasks[serverID] = nil
        sessions[serverID] = nil
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
}
