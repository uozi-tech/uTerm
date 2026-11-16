import Foundation

// 移除之后（docs/remote-device-group-design.md §7.3）：
//
// 1. 请 Mac 撤销被移除的设备。本机认下的每条移除（自己做的、读名册读到的、连带的、离线期间别人做的、重装设备留下的
//    旧身份）都从本机的移除记录推出来（`trackRevocations`），不看是谁、怎么做的移除。对认下那一刻本机配对过的每台 Mac
//    各请一次（消息 52 / 53），进度存在本机（`RemoteGroupRevocation`）：撤了 / 本来就不认识 / 不是同一组的 = 做完；
//    连不上 60 秒后再问；Mac 太旧 6 小时后再问。和开通共用「每台 Mac 一次一个请求」（`RemoteGroupVouchTasks`），
//    撤销排在开通前面。被移除的设备自己什么都不做（`refresh()` 在这之前就返回了）。
// 2. 拿掉只凭被移除的组员开通才记下的 Mac（`rollBackAdoptedHosts`）：被偷的组员在移除之前可以签一条假结果，
//    让本机把攻击者的机器记成一台 Mac。

extension RemoteDeviceGroup {
    /// 「已移除的设备」里的一行：还有 Mac 没撤完的被移除设备。
    struct RemovedDevice: Identifiable, Equatable {
        /// 被移除的那把 Ed25519 钥匙。
        let id: Data
        let deviceID: UUID
        let name: String
        /// 还没撤的 Mac 的名字（按名字排）。
        let waitingHosts: [String]
    }

    // MARK: - 记下要撤的

    /// 每条移除（不含本机自己签的离开）一条撤销进度。同一把钥匙后来又被移除一次（重新加入之后），从头再撤一遍。
    /// 要问哪几台 Mac 在这一刻定下（之后才配对的不问）；还不知道本机配对了哪些 Mac 时先空着，下一轮补。
    /// 设备 ID 就是本机的（本机重装之前的那一份）：不去撤，那台设备已经不在了，本机也不该请 Mac 撤销自己的 ID。
    func trackRevocations(_ state: inout RemoteGroupLocalState, names: [Data: String]) {
        var cached: [UUID]??
        func paired() -> [UUID]? {
            if let cached { return cached }
            let value = hosts.map { $0.pairedHosts().map(\.id).filter { $0 != local.id }.sorted { $0.uuidString < $1.uuidString } }
            cached = .some(value)
            return value
        }
        func initialHosts(_ removal: RemoteGroupRemoval) -> [UUID]? {
            removal.deviceID == local.id ? [] : paired()
        }
        for removal in state.removals where removal.signingKey != local.signingKey {
            let name = names[removal.signingKey]
            guard let index = state.revocations.firstIndex(where: { $0.signingKey == removal.signingKey }) else {
                state.revocations.append(RemoteGroupRevocation(deviceID: removal.deviceID, name: name ?? "",
                                                               publicKey: removal.publicKey, signingKey: removal.signingKey,
                                                               removedAt: removal.removedAt, hosts: initialHosts(removal)))
                continue
            }
            var entry = state.revocations[index]
            if removal.removedAt > entry.removedAt {
                entry = RemoteGroupRevocation(deviceID: removal.deviceID, name: name ?? entry.name,
                                              publicKey: removal.publicKey, signingKey: removal.signingKey,
                                              removedAt: removal.removedAt, hosts: initialHosts(removal))
            } else if entry.hosts == nil {
                entry.hosts = initialHosts(removal)
            }
            if entry.name.isEmpty, let name { entry.name = name }
            if entry != state.revocations[index] { state.revocations[index] = entry }
        }
    }

    /// 此刻还配对着的 Mac 都做完了：记成处理完，不再问。
    func settleRevocations(_ state: inout RemoteGroupLocalState, paired: Set<UUID>) {
        for index in state.revocations.indices {
            let entry = state.revocations[index]
            guard entry.hosts != nil, !entry.isSettled, entry.outstanding(paired: paired).isEmpty else { continue }
            state.revocations[index].hosts = []
            state.revocations[index].finished = []
            state.revocations[index].retryAfter = [:]
            AppLogger.notice("设备组：「\(entry.name)」在各台 Mac 上都撤完了", category: RemoteLog.category)
        }
    }

    // MARK: - 撤

    /// 这台 Mac 上下一条要撤的：没做完、不在等重试，最早移除的先撤。
    func nextRevocation(at host: UUID, in state: RemoteGroupLocalState) -> RemoteGroupRevocation? {
        state.revocations
            .filter { $0.isUnfinished(at: host) && isDue($0.retryAfter[host]) }
            .min { ($0.removedAt, $0.signingKey.base64EncodedString()) < ($1.removedAt, $1.signingKey.base64EncodedString()) }
    }

    /// 到了再问的时候。写到了很远的将来的（钟往回拨过）不算数，免得永远不问。
    private func isDue(_ retryAfter: Date?) -> Bool {
        guard let retryAfter else { return true }
        let wait = retryAfter.timeIntervalSince(now())
        return wait <= 0 || wait > Self.vouchRefusedRetryInterval
    }

    func startRevoke(_ revocation: RemoteGroupRevocation, at target: RemoteGroupVouchTarget,
                     hosts: any RemoteGroupHostAccess) {
        let token = UUID()
        let task = Task { [weak self] in
            let outcome: Result<RemoteSiblingRevokeResult, any Error>
            do {
                outcome = .success(try await hosts.revokeSibling(revocation.deviceID, publicKey: revocation.publicKey,
                                                                 at: target.id))
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.vouches.finish(target.id, token: token), !Task.isCancelled else { return }
            self.finishRevoke(revocation, at: target, outcome)
        }
        vouches.start(target.id, token: token, at: now(), task: task)
        AppLogger.info("设备组：请「\(target.name)」撤销「\(revocation.name)」", category: RemoteLog.category)
    }

    private func finishRevoke(_ revocation: RemoteGroupRevocation, at target: RemoteGroupVouchTarget,
                              _ outcome: Result<RemoteSiblingRevokeResult, any Error>) {
        var retry: TimeInterval?
        switch outcome {
        case .success(let reply):
            hostFailures[target.id] = nil
            switch reply.kind {
            case .revoked:
                retry = nil
                // Mac 连带撤掉了由它担保的设备，里面可能有正常的组员：这台 Mac 上的开通结果从现在起重新算。
                revalidateFrom[target.id] = RemoteGroupTime(now())
            case .notTrusted, .notInFamily:
                retry = nil
            case nil:
                // 不认识的结果（以后的版本多一种）：当成这一版还撤不了，过一阵再问。
                retry = Self.vouchRefusedRetryInterval
            }
            AppLogger.notice("设备组：「\(target.name)」撤销「\(revocation.name)」的结果 \(reply.outcome)",
                             category: RemoteLog.category)
        case .failure(let error):
            if error is CancellationError { return }
            if case .rejected? = error as? RemoteAttachError {
                // Mac 上的 uTerm 太旧，不认撤销。
                retry = Self.vouchRefusedRetryInterval
            } else {
                hostFailures[target.id] = now()
                retry = Self.vouchRetryInterval
                AppLogger.info("设备组：请「\(target.name)」撤销「\(revocation.name)」没连上：\(error.localizedDescription)",
                               category: RemoteLog.category)
            }
        }
        guard var state = loadState(), !state.selfRemoved,
              let index = state.revocations.firstIndex(where: {
                  $0.signingKey == revocation.signingKey && $0.removedAt == revocation.removedAt
              }), state.revocations[index].isUnfinished(at: target.id) else { return }
        let original = state
        if let retry {
            state.revocations[index].retryAfter[target.id] = now().addingTimeInterval(retry)
        } else {
            state.revocations[index].finished.append(target.id)
            state.revocations[index].retryAfter[target.id] = nil
        }
        guard persist(state, from: original) else { return }
        refresh()
    }

    // MARK: - 给界面

    func updateRemovedDevices(_ state: RemoteGroupLocalState, paired: [RemoteGroupVouchTarget]) {
        let names = Dictionary(paired.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let rows = state.revocations.compactMap { entry -> RemovedDevice? in
            let waiting = entry.outstanding(paired: Set(names.keys))
            guard !waiting.isEmpty else { return nil }
            return RemovedDevice(id: entry.signingKey, deviceID: entry.deviceID,
                                 name: entry.name.isEmpty ? RemoteDeviceGroupCopy.unnamedDevice : entry.name,
                                 waitingHosts: waiting.compactMap { names[$0] }.sorted())
        }
        .sorted { ($0.name, $0.deviceID.uuidString) < ($1.name, $1.deviceID.uuidString) }
        setRemovedDevices(rows)
    }

    // MARK: - 回滚收下的 Mac

    /// 因为结果才收下的 Mac：凭的组员都被移除了，此刻也没有别的还在组里的组员开通过同一把钥匙，就从本机拿掉（不拉黑）。
    /// 你在这台设备上重新配对过（公钥或记下的时间变了）、忘记过（已经不在信任表里）的，不再归设备组管。
    func rollBackAdoptedHosts(_ snapshot: RemoteGroupSnapshot, _ state: inout RemoteGroupLocalState,
                              hosts: any RemoteGroupHostAccess) {
        guard !state.adoptedHosts.isEmpty else { return }
        let backed = Set(acceptedGrants(snapshot, state).filter(\.grant.isUsable).map {
            $0.grant.host.id.uuidString + "." + $0.grant.host.publicKey.base64EncodedString()
        })
        var kept: [RemoteGroupAdoptedHost] = []
        for adopted in state.adoptedHosts {
            guard let trusted = hosts.trustedHost(adopted.hostID),
                  trusted.matches(publicKey: adopted.hostKey, pairedAt: adopted.pairedAt) else { continue }
            let stillBacked = backed.contains(adopted.hostID.uuidString + "." + adopted.hostKey.base64EncodedString())
                || adopted.signers.contains { state.member(signingKey: $0) != nil }
            let allRemoved = adopted.signers.allSatisfy { state.latestRemoval(of: $0) != nil }
            guard !stillBacked, allRemoved else {
                kept.append(adopted)
                continue
            }
            if hosts.dropAdoptedHost(adopted.hostID, publicKey: adopted.hostKey, pairedAt: adopted.pairedAt) {
                adoptions[adopted.hostID] = nil
                AppLogger.notice("设备组：拿掉只凭被移除的组员开通的 Mac \(adopted.hostID.uuidString.prefix(8))",
                                 category: RemoteLog.category)
            } else {
                kept.append(adopted)
            }
        }
        if kept != state.adoptedHosts { state.adoptedHosts = kept }
    }
}
