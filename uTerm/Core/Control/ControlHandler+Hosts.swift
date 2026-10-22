import Foundation
import SwiftData

/// 主机组：`hosts` / `host-key` / `trust`（外加 misc 组的 `disconnect`，它也按主机走）。
///
/// 这个文件同时是**主机解析的唯一入口**：所有其它组要拿 `ServerProfile` 都得走
/// `resolveHost(_:)`，从而共享同一套三级匹配与歧义规则，也共享 `sftpOnly` 硬规则。
extension ControlHandler {

    func handleHosts(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .hosts:
            return await hostsResponse(request, deps)
        case .hostKey:
            return try hostKeyResponse(request, deps)
        case .trust:
            return try await trustResponse(request, deps)
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于主机组"
            )
        }
    }

    // MARK: - hosts

    private func hostsResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async -> ControlResponse {
        // `cliConnected` 必须问池（而不是读同步镜像）：这是列表动作，await 得起，
        // 而且用户看的就是这一列。
        let held = Set(await deps.pool.heldHostIDs())
        let snapshots = sortedProfiles(deps).map { hostSnapshot($0, held: held, deps) }
        return .success(
            id: request.id,
            message: snapshots.isEmpty
                ? "还没有保存任何主机（在 uTerm 里新建一台后再试）"
                : "共 \(snapshots.count) 台主机",
            hosts: snapshots
        )
    }

    // MARK: - host-key

    private func hostKeyResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) throws -> ControlResponse {
        let profile = try resolveHost(request.host ?? "")
        let endpoint = "\(profile.host):\(profile.port)"
        let known = knownHosts(host: profile.host, port: profile.port, deps)

        guard let newest = known.first else {
            return .success(
                id: request.id,
                message: "主机「\(profile.name)」的密钥尚未信任。跑一次 `run` 会拿到指纹，"
                    + "核对无误后用 `trust --fingerprint` 钉住。",
                hostKey: ControlHostKeyInfo(host: endpoint, status: "unknown")
            )
        }
        // CloudKit 同步能造出同 host:port 的多条记录。密钥不一致时 fail closed 报
        // `changed` —— 与 `HostKeyVerifier.classify` 的判断一致，绝不挑一条当真值。
        let consistent = known.allSatisfy { $0.keyBlob == newest.keyBlob }
        return .success(
            id: request.id,
            message: consistent
                ? "主机「\(profile.name)」的密钥已在信任库里"
                : "主机「\(profile.name)」在信任库里有 \(known.count) 条互相冲突的记录，请到 uTerm 界面里处理",
            hostKey: ControlHostKeyInfo(
                host: endpoint,
                algorithm: newest.keyTypeRaw.isEmpty ? nil : newest.keyTypeRaw,
                fingerprint: newest.fingerprint,
                firstTrustedAt: ControlProtocol.iso8601(newest.firstTrustedAt),
                status: consistent ? "known" : "changed"
            )
        )
    }

    // MARK: - trust

    /// 只接受与「最近一次该主机的建连质询」逐字一致的指纹。
    ///
    /// 三条硬规则：
    /// 1. 没有缓存质询 → `invalid_request`（先跑一次 `run` 触发建连，才有指纹可核对）；
    /// 2. 质询是**密钥变更** → `host_key_changed`，CLI 永远不给覆盖，必须回界面；
    /// 3. 指纹对不上 → `host_key_mismatch`。
    ///
    /// 真正的写入走 `HostKeyVerifier` 现成的 TOFU 路径：连接池按钉住的指纹重新握手，
    /// 服务器出示的密钥与指纹逐字相同才批准，USSHKit 随即把它记进 `KnownHost`。
    private func trustResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        let profile = try resolveHost(request.host ?? "")
        let endpoint = "\(profile.host):\(profile.port)"
        guard let fingerprint = Self.trimmed(request.fingerprint) else {
            throw ControlFailure(
                code: .invalid_request,
                message: "缺少 --fingerprint：trust 必须钉住一个指纹，不接受「信任任何新密钥」"
            )
        }

        guard let challenge = await deps.pool.lastHostKeyChallenge(hostID: profile.id) else {
            throw ControlFailure(
                code: .invalid_request,
                message: "还没有主机「\(profile.name)」的待信任指纹。"
                    + "先跑一次 `utermctl run -H \(profile.name) -- true` 触发建连拿到指纹，再来 trust。"
            )
        }

        if challenge.kind == .mismatch {
            return .failure(
                id: request.id,
                code: .host_key_changed,
                message: "主机「\(profile.name)」的密钥与信任库里的记录不一致（当前 \(challenge.newFingerprint)）。"
                    + "这可能是中间人攻击。CLI 不允许覆盖已信任的主机密钥，请由用户在 uTerm 界面里处理。",
                hostKey: ControlHostKeyInfo(
                    host: endpoint,
                    fingerprint: challenge.newFingerprint,
                    status: "changed"
                )
            )
        }

        guard challenge.newFingerprint == fingerprint else {
            return .failure(
                id: request.id,
                code: .host_key_mismatch,
                message: "指纹对不上：主机「\(profile.name)」当前出示的是 \(challenge.newFingerprint)，"
                    + "而你要钉住的是 \(fingerprint)。请让用户核对后重试。",
                hostKey: ControlHostKeyInfo(
                    host: endpoint,
                    fingerprint: challenge.newFingerprint,
                    status: "unknown"
                )
            )
        }

        do {
            let spec = try HostConnectionSpec.resolve(profile: profile, container: deps.modelContainer)
            try await deps.pool.trustHostKey(host: spec, fingerprint: fingerprint)
        } catch let error as ControlConnectError {
            return response(for: error, id: request.id, host: profile.name)
        }

        return .success(
            id: request.id,
            message: "已信任主机「\(profile.name)」的密钥 \(fingerprint)",
            hostKey: ControlHostKeyInfo(
                host: endpoint,
                fingerprint: fingerprint,
                firstTrustedAt: ControlProtocol.iso8601(Date()),
                status: "known"
            )
        )
    }

    // MARK: - disconnect（misc 组，但按主机走，故放这里）

    /// 松开 CLI 池对某主机的 exec / SFTP 持有。不给 `--host` 就全部释放。
    func handleDisconnect(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        guard let needle = Self.trimmed(request.host) else {
            await deps.pool.disconnectAll()
            return .success(id: request.id, message: "已释放 CLI 持有的全部主机连接")
        }
        let profile = try resolveHost(needle)
        await deps.pool.disconnect(hostID: profile.id)
        return .success(id: request.id, message: "已释放对主机「\(profile.name)」的连接")
    }

    // MARK: - 解析

    /// 名字 / UUID → `ServerProfile` 的三级解析：精确 → 忽略大小写 → 唯一前缀。
    ///
    /// 多条命中抛 `host_ambiguous`，并把候选（带 UUID）放进 `ControlFailure.hosts` ——
    /// CloudKit 同步下同名主机是常态，技能文档要教模型改用 UUID 重试。
    /// 纯匹配逻辑在 `HostResolver`（单测友好），本方法只负责取数据 + 包错。
    ///
    /// - Important: 所有需要主机的动作都必须经此入口，不要各自 fetch。
    func resolveHost(_ needle: String) throws(ControlFailure) -> ServerProfile {
        guard let deps = dependencies else {
            throw ControlFailure(code: .app_not_ready, message: "uTerm 尚未完成启动")
        }
        return try resolveHost(needle, in: sortedProfiles(deps), deps)
    }

    /// 同上，但吃**已经取好**的候选列表。
    ///
    /// `run-many` / `quick-run` 一次要解析 N 台主机，走上面那个重载等于 fetch + 排序
    /// N 遍（SwiftData 的 fetch 不是免费的）。批量路径先取一次，再逐个喂进来。
    func resolveHost(
        _ needle: String,
        in profiles: [ServerProfile],
        _ deps: Dependencies
    ) throws(ControlFailure) -> ServerProfile {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ControlFailure(
                code: .invalid_request,
                message: "缺少 --host（先跑 `utermctl hosts` 看有哪些主机）"
            )
        }
        let candidates = profiles.map { HostResolver.Candidate(id: $0.id, name: $0.name) }
        switch HostResolver.resolve(trimmed, in: candidates) {
        case .matched(let id):
            guard let profile = profiles.first(where: { $0.id == id }) else {
                throw ControlFailure(
                    code: .host_not_found,
                    message: "没有名为「\(trimmed)」的主机"
                )
            }
            return profile
        case .ambiguous(let matches):
            let ids = Set(matches.map(\.id))
            // 这里是同步路径，问不到连接池；候选的 `cliConnected` 由
            // `ControlHandler.handle` 在收口时统一补（那里 await 得起）。
            let snapshots = profiles
                .filter { ids.contains($0.id) }
                .map { hostSnapshot($0, held: [], deps) }
            throw ControlFailure(
                code: .host_ambiguous,
                message: "「\(trimmed)」匹配到 \(matches.count) 台主机："
                    + matches.map(\.name).joined(separator: "、")
                    + "。改用响应里的 UUID 重试。",
                hosts: snapshots
            )
        case .notFound:
            throw ControlFailure(
                code: .host_not_found,
                message: "没有名为「\(trimmed)」的主机（跑 `utermctl hosts` 看有哪些）"
            )
        }
    }

    /// 主机级硬规则：`sftpOnly` 的主机拒绝执行命令与终端操作。
    ///
    /// 这是用户在主机档案上做的定性，CLI 不绕 —— 各组在 `resolveHost` 之后**立刻**调用。
    func requireExecCapable(
        _ profile: ServerProfile,
        action: ControlAction
    ) throws(ControlFailure) {
        guard action.requiresExecCapableHost, profile.sftpOnly else { return }
        throw ControlFailure(
            code: .host_sftp_only,
            message: "主机「\(profile.name)」被标记为仅 SFTP，不允许执行命令或操作终端"
        )
    }

    // MARK: - 共用工具

    /// 与界面同序（`@Query(sort: \ServerProfile.sortOrder)`），同 `sortOrder` 时按名字定序。
    func sortedProfiles(_ deps: Dependencies) -> [ServerProfile] {
        let all = (try? deps.modelContainer.mainContext.fetch(FetchDescriptor<ServerProfile>())) ?? []
        return all.sorted {
            $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name
        }
    }

    func hostSnapshot(
        _ profile: ServerProfile,
        held: Set<UUID>,
        _ deps: Dependencies
    ) -> ControlHostSnapshot {
        ControlHostSnapshot(
            id: profile.id.uuidString,
            name: profile.name,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            authMethod: profile.authMethod.rawValue,
            group: (profile.group?.isEmpty == false) ? profile.group : nil,
            jumpHost: profile.jumpHost.map { $0.name.isEmpty ? $0.host : $0.name },
            sftpOnly: profile.sftpOnly,
            pinned: profile.isPinned,
            lastConnectedAt: ControlProtocol.iso8601(profile.lastConnectedAt),
            cliConnected: held.contains(profile.id),
            activeForwards: deps.forwardingCoordinator.activeCount(forServer: profile.id)
        )
    }

    /// 某 host:port 的信任记录，按信任时间倒序（与 `HostKeyVerifier.existing` 同序）。
    private func knownHosts(host: String, port: Int, _ deps: Dependencies) -> [KnownHost] {
        let descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate<KnownHost> { $0.host == host && $0.port == port },
            sortBy: [SortDescriptor(\.firstTrustedAt, order: .reverse)]
        )
        return (try? deps.modelContainer.mainContext.fetch(descriptor)) ?? []
    }

    /// `ControlConnectError` → 响应。主机密钥两态把指纹放进 `hostKey`，
    /// CLI 据此提示用户核对并 `trust`。
    func response(
        for error: ControlConnectError,
        id: String?,
        host: String
    ) -> ControlResponse {
        var info: ControlHostKeyInfo?
        if let fingerprint = error.fingerprint {
            info = ControlHostKeyInfo(
                host: host,
                algorithm: error.algorithm,
                fingerprint: fingerprint,
                status: error.code == .host_key_changed ? "changed" : "unknown"
            )
        }
        return .failure(
            id: id,
            code: error.code,
            message: error.message(host: host),
            hostKey: info
        )
    }

    /// 任意建连失败 → 响应（主机密钥两态带 `hostKey.fingerprint`）。
    ///
    /// `ControlFailure` 带不了 `hostKey`，所以建连路径一律**返回响应**而不是抛错 ——
    /// 技能文档教模型读 `hostKey.fingerprint` 去 `trust`，这个字段丢了模型就卡死。
    /// `run` / `run-many` / `trust` 直接用 `response(for:id:host:)`；
    /// SFTP / 转发那种手里只有 `Error` 的路径走这个包装。
    func connectFailureResponse(
        _ error: Error,
        id: String?,
        profile: ServerProfile
    ) -> ControlResponse {
        guard let connect = error as? ControlConnectError else {
            return .failure(
                id: id,
                code: .connect_failed,
                message: "连接「\(profile.name)」失败：\(FriendlyError.describe(error))"
            )
        }
        return response(for: connect, id: id, host: profile.name)
    }

    /// 去空白后的非空串，否则 nil。
    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
