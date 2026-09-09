import Foundation
import SwiftData

/// 端口转发组：`forward-list` / `forward-start` / `forward-stop`。
///
/// 硬约束：规则**只在界面里建**，CLI 只启停与查状态（协议里没有增删改字段）。
/// `forward-start` 走非交互 host-key 路径 —— 挑战一来就拒绝并把 fingerprint 回给
/// CLI，绝不自动 TOFU；端口冲突用 `PortConflictChecker` + 一次真实 bind 探测判成
/// `port_in_use`，不要让 NIO 的 EADDRINUSE 冒成通用失败。
extension ControlHandler {

    func handleForward(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .forwardList:
            return try await forwardList(request, deps)
        case .forwardStart:
            return try await forwardStart(request, deps)
        case .forwardStop:
            return try await forwardStop(request, deps)
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于转发组"
            )
        }
    }

    // MARK: - forward-list

    private func forwardList(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        // `--host` 可选：给了就只列该主机的规则（走同一套主机解析）。
        var serverFilter: UUID?
        if let needle = request.host?.trimmingCharacters(in: .whitespaces), !needle.isEmpty {
            serverFilter = try resolveHost(needle).id
        }

        let rules = forwardingRules(deps).filter { serverFilter == nil || $0.serverID == serverFilter }
        let names = serverNames(deps)
        let traffic = await deps.forwardingCoordinator.trafficSnapshot()

        let snapshots = rules.map { rule in
            snapshot(of: rule, names: names, traffic: traffic, deps)
        }
        return .success(
            id: request.id,
            message: "\(snapshots.count) 条转发规则",
            rules: snapshots
        )
    }

    // MARK: - forward-start

    private func forwardStart(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        let rule = try resolveRule(request, deps)
        let names = serverNames(deps)
        let traffic = await deps.forwardingCoordinator.trafficSnapshot()

        // 已在跑 → 幂等返回 ok。
        let current = deps.forwardingCoordinator.status(rule.id)
        if current == .active || current == .starting {
            return .success(
                id: request.id,
                message: "规则「\(rule.name)」已在运行",
                rules: [snapshot(of: rule, names: names, traffic: traffic, deps)]
            )
        }

        guard let profile = serverProfile(rule.serverID, deps) else {
            throw ControlFailure(
                code: .host_not_found,
                message: "规则「\(rule.name)」关联的主机档案已不存在"
            )
        }

        if let occupied = portConflict(for: rule, deps) {
            throw ControlFailure(code: .port_in_use, message: occupied)
        }

        // 非交互 host-key：不弹 sheet，也不自动信任 —— 挑战一来就记下 fingerprint 并拒绝。
        let relay = HostKeyChallengeRelay()
        let ruleSnapshot = rule.snapshot
        deps.forwardingCoordinator.start(
            ruleSnapshot,
            on: profile,
            relay: relay,
            modelContainer: deps.modelContainer
        )

        let outcome = await waitForStart(ruleID: ruleSnapshot.id, relay: relay, deps)
        let after = deps.forwardingCoordinator.status(ruleSnapshot.id)
        let latestTraffic = await deps.forwardingCoordinator.trafficSnapshot()
        let snap = ControlForwardSnapshotBuilder.make(
            rule: ruleSnapshot,
            serverName: names[ruleSnapshot.serverID] ?? "",
            status: after,
            connectionIssue: deps.forwardingCoordinator.connectionIssue(ruleSnapshot.id)?.reason,
            bytes: latestTraffic[ruleSnapshot.id]
        )

        switch outcome {
        case .started:
            return .success(
                id: request.id,
                message: "规则「\(ruleSnapshot.name)」已启动",
                rules: [snap]
            )

        case .hostKey(let challenge):
            let changed = challenge.kind == .mismatch
            return .failure(
                id: request.id,
                code: changed ? .host_key_changed : .host_key_unknown,
                message: changed
                    ? "主机「\(profile.name)」的密钥与信任库不一致，请回 uTerm 界面处理"
                    : "主机「\(profile.name)」的密钥尚未信任；核对后用 trust --fingerprint \(challenge.newFingerprint) 钉住",
                hostKey: ControlHostKeyInfo(
                    host: challenge.host,
                    fingerprint: challenge.newFingerprint,
                    status: changed ? "changed" : "unknown"),
                rules: [snap]
            )

        case .failed(let failure):
            return .failure(
                id: request.id,
                code: failure.kind == .conflict ? .port_in_use : .forward_failed,
                message: failure.message,
                rules: [snap]
            )

        case .timedOut(let seconds):
            return .failure(
                id: request.id,
                code: .forward_failed,
                message: "规则「\(ruleSnapshot.name)」\(seconds) 秒内未完成启动（仍在连接中）",
                rules: [snap]
            )
        }
    }

    /// `forward-start` 的等待策略：`ForwardingCoordinator.start` 是同步返回、异步建连的，
    /// 所以这里轮询 `status(_:)` 直到离开 `.starting`。每一拍顺带看一眼 relay ——
    /// 有挑战就记下 fingerprint 并**立刻拒绝**（非交互路径不做 TOFU），让建连尽快失败。
    ///
    /// 上限取「设置 ▸ 高级」的 `sshConnectTimeout`（默认 30 s），与 app 自己建连的耐心一致。
    private func waitForStart(
        ruleID: UUID,
        relay: HostKeyChallengeRelay,
        _ deps: Dependencies
    ) async -> ForwardStartOutcome {
        let timeout = Self.startTimeoutSeconds
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var challenge: HostKeyChallenge?

        while Date() < deadline {
            if let pending = relay.pendingChallenge {
                challenge = pending
                relay.resolve(false)
            }
            switch deps.forwardingCoordinator.status(ruleID) {
            case .active:
                return .started
            case .error(let failure):
                if let challenge { return .hostKey(challenge) }
                return .failed(failure)
            case .inactive, .starting:
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let challenge { return .hostKey(challenge) }
        return .timedOut(timeout)
    }

    private enum ForwardStartOutcome {
        case started
        case hostKey(HostKeyChallenge)
        case failed(ForwardingError)
        case timedOut(Int)
    }

    /// `sshConnectTimeout`（设置 ▸ 高级）；缺省 30 s，与 `SSHClientFactory` 同源。
    private static var startTimeoutSeconds: Int {
        let stored = UserDefaults.standard.object(forKey: "sshConnectTimeout") as? Int
        return max(1, stored ?? 30)
    }

    // MARK: - forward-stop

    private func forwardStop(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        let rule = try resolveRule(request, deps)
        let names = serverNames(deps)
        let wasRunning = deps.forwardingCoordinator.status(rule.id) != .inactive
        if wasRunning {
            deps.forwardingCoordinator.stop(rule.id)
        }
        let traffic = await deps.forwardingCoordinator.trafficSnapshot()
        return .success(
            id: request.id,
            message: wasRunning ? "规则「\(rule.name)」已停止" : "规则「\(rule.name)」本来就没在运行",
            rules: [snapshot(of: rule, names: names, traffic: traffic, deps)]
        )
    }

    // MARK: - 端口预检

    /// 两道预检，都在把请求交给 NIO 之前做，让占用变成明确的 `port_in_use`：
    /// 1. **规则之间**：`PortConflictChecker` 对当前在跑的同侧规则查重（知名端口那一
    ///    支交给下面的真实探测判，界面里也只是警告而非拦截）；
    /// 2. **别的进程**：本地绑定侧（`-L` / `-D`）真绑一下 listenHost:listenPort。
    ///    `-R` 的口开在远端，本机探不到，交给远端报错。
    private func portConflict(for rule: ForwardingRule, _ deps: Dependencies) -> String? {
        let running = forwardingRules(deps)
            .filter { $0.id != rule.id }
            .filter { deps.forwardingCoordinator.status($0.id) != .inactive }
            .map(\.snapshot)

        if let clash = PortConflictChecker.conflict(
            kind: rule.kind,
            listenPort: rule.listenPort,
            excluding: rule.id,
            against: running
        ), PortConflictChecker.wellKnownPorts[clash.port] != clash.occupant {
            return "端口 \(clash.port) 已被规则「\(clash.occupant)」占用"
        }

        if rule.kind != .remote,
           ControlLocalPortProbe.isBusy(host: rule.listenHost, port: rule.listenPort) {
            return "本机 \(rule.listenHost):\(rule.listenPort) 已被其它进程占用"
        }
        return nil
    }

    // MARK: - 取数

    private func forwardingRules(_ deps: Dependencies) -> [ForwardingRule] {
        ForwardingRuleStore(context: deps.modelContainer.mainContext).allRules()
    }

    private func serverProfile(_ id: UUID, _ deps: Dependencies) -> ServerProfile? {
        let descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.id == id })
        return (try? deps.modelContainer.mainContext.fetch(descriptor))?.first
    }

    private func serverNames(_ deps: Dependencies) -> [UUID: String] {
        let profiles = (try? deps.modelContainer.mainContext
            .fetch(FetchDescriptor<ServerProfile>())) ?? []
        return Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func snapshot(
        of rule: ForwardingRule,
        names: [UUID: String],
        traffic: [UUID: TunnelBytes],
        _ deps: Dependencies
    ) -> ControlForwardSnapshot {
        ControlForwardSnapshotBuilder.make(
            rule: rule.snapshot,
            serverName: names[rule.serverID] ?? "",
            status: deps.forwardingCoordinator.status(rule.id),
            connectionIssue: deps.forwardingCoordinator.connectionIssue(rule.id)?.reason,
            bytes: traffic[rule.id]
        )
    }

    // MARK: - 规则解析

    /// `--rule`（或 `--name`）→ `ForwardingRule`：UUID 直达 → 名字精确 → 忽略大小写
    /// → 唯一前缀。给了 `--host` 时只在该主机的规则里找（同名规则跨主机是常态）。
    private func resolveRule(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) throws -> ForwardingRule {
        let needle = (request.rule ?? request.name ?? "").trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 需要 --rule"
            )
        }

        var pool = forwardingRules(deps)
        if let host = request.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty {
            let serverID = try resolveHost(host).id
            pool = pool.filter { $0.serverID == serverID }
        }

        let candidates = pool.map {
            ControlForwardRuleResolver.Candidate(id: $0.id, name: $0.name)
        }
        switch ControlForwardRuleResolver.resolve(needle, in: candidates) {
        case .matched(let id):
            guard let rule = pool.first(where: { $0.id == id }) else {
                throw ControlFailure(code: .rule_not_found, message: "找不到转发规则「\(needle)」")
            }
            return rule
        case .ambiguous(let matches):
            let listed = matches.map { "\($0.name)（\($0.id.uuidString)）" }.joined(separator: "、")
            throw ControlFailure(
                code: .rule_ambiguous,
                message: "「\(needle)」匹配到多条规则：\(listed)；请改用 UUID"
            )
        case .notFound:
            throw ControlFailure(code: .rule_not_found, message: "找不到转发规则「\(needle)」")
        }
    }
}
