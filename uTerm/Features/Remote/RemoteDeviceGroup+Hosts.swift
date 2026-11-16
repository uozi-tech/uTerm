import CryptoKit
import Foundation

// 组里的 Mac（docs/remote-device-group-design.md §7.2）。每轮 `refresh()` 算完组员名单之后：
//
// 1. 发 `host`：本机配对过的每台 Mac 一条，本机签；不再配对的删掉。只有自己一台（不在组里）时一条都不留。
// 2. 清理：本机签的 `grant` 里，对象已不是组员的、Mac 已不再配对的，删掉。
// 3. 收：对象是本机、签名者是我认的组员的 `grant`，可用就打开中继包、交给 `hosts.adopt`；算出「还没通的 Mac」。
// 4. 问：对每台别的组员 D、每台本机此刻问得到的 Mac H（D 不是 H），名册里没有任何我认的组员签的、针对
//    (D 现在的钥匙, H 现在的公钥) 的有定论的结果，就请 H 记下 D（消息 50 / 51），结果签好写成 `grant`。
//    不同的 Mac 并行问，同一台 Mac 一次只问一个组员。连不上不写、60 秒后再问；不允许、版本太旧写下、6 小时后再问。
//
// G3（§7.3）：同一格「每台 Mac 一次一个请求」里，请 Mac 撤销被移除的设备排在开通前面
// （`RemoteDeviceGroup+Revoke.swift`）；本机是 Mac 时先处理它自己的被控端（`RemoteDeviceGroup+LocalHost.swift`）；
// 收下的结果记着凭谁，签名者被移除后回滚。
//
// 被移出的设备什么都不做（`refresh()` 在这之前就返回了，还在问的请求一并取消）。

extension RemoteDeviceGroup {
    /// 组里的一台 Mac，本机还不能用。
    struct PendingHost: Identifiable, Equatable {
        enum Reason: Hashable {
            /// Mac 上关了「允许已配对的设备开通主人的其它设备」。
            case notAllowed
            /// Mac 上的 uTerm 太旧，不认担保。
            case tooOld
            /// Mac 不肯记（这台设备在那台 Mac 上被撤销过、换过钥匙）。
            case rejected
            /// 本机记着一台同 ID、公钥不同的 Mac。
            case conflict
            /// 你在这台设备上忘记过它。
            case forgotten
        }

        enum Status: Hashable {
            /// 组里知道这台 Mac，替本机开通的结果还没到。
            case opening
            /// 要在这台设备上单独配对。
            case needsPairing(Reason)
        }

        let id: UUID
        let name: String
        let status: Status
    }

    /// 上一次交给 `hosts.adopt` 的是哪条结果、那时本机记着的公钥、结果如何。
    struct AdoptionMemo {
        let signature: Data
        let pairedKey: Data?
        let result: RemoteGroupAdoption
    }

    /// 连不上的 Mac 隔这么久再问。
    static let vouchRetryInterval: TimeInterval = 60
    /// Mac 不允许、版本太旧：隔这么久再问（Mac 的主人可能会打开开关、更新 uTerm）。
    static let vouchRefusedRetryInterval: TimeInterval = 6 * 3600
    /// 刚进组、或开始问 Mac 之后，这么久里读名册保持快的。
    static let hostFastPollingWindow: TimeInterval = 10 * 60

    static func askKey(_ device: RemoteGroupDevice, _ host: UUID) -> String {
        device.signingKey.base64EncodedString() + "." + host.uuidString
    }

    /// 正在问的 Mac 有几台（测试用）。
    var vouchesInFlight: Int { vouches.count }

    // MARK: - 每一轮

    /// 每一轮最后一步。会改本机状态（撤销进度、收下的 Mac），改了就存。
    func syncHosts(_ snapshot: RemoteGroupSnapshot, _ state: inout RemoteGroupLocalState) {
        let original = state
        defer { persist(state, from: original) }
        // 本机是 Mac：把组员记成自己的主控端、撤掉被移除的（不需要配对过任何 Mac）。
        syncLocalHost(snapshot, state)
        guard let hosts else {
            updateHostState(pending: [], opening: isOpening(state))
            updateRemovedDevices(state, paired: [])
            return
        }
        let paired = hosts.pairedHosts().filter { $0.id != local.id }
        let pairedIDs = Set(paired.map(\.id))
        settleRevocations(&state, paired: pairedIDs)
        let inGroup = !state.members.isEmpty
        publishHostRecords(snapshot, state, paired: inGroup ? paired : [])
        cleanUpGrants(snapshot, state, paired: pairedIDs)
        let pending = inGroup ? receiveGrants(snapshot, &state, hosts: hosts, paired: paired) : []
        rollBackAdoptedHosts(snapshot, &state, hosts: hosts)
        // 撤销不看在不在组里（移除了最后一台别的组员，本机就只剩自己一台）；开通要在组里，而且有远控身份私钥
        // （封不了中继包就不替别人问：没有私钥 = 不担保、不开包）。
        scheduleHostWork(snapshot, state, hosts: hosts, vouching: inGroup && identityKey != nil)
        updateHostState(pending: pending, opening: isOpening(state))
        updateRemovedDevices(state, paired: paired)
    }

    /// 本机被移出、或服务停了：取消还在问的请求（取消的那一次什么都不写），「还没通的 Mac」「已移除的设备」清空。
    func haltHostWork() {
        vouches.cancelAll()
        updateHostState(pending: [], opening: false)
        if !removedDevices.isEmpty { updateRemovedDevices(RemoteGroupLocalState(), paired: []) }
    }

    /// iOS 退到后台（`RemoteDeviceGroupService.stop`）：取消还在问的请求。下一轮回到前台再问。
    func cancelHostWork() {
        vouches.cancelAll()
        updateHostState(pending: pendingHosts, opening: false)
    }

    /// 轮询该快：本机刚由别的设备加进组（10 分钟内，等各台 Mac 的结果过来），或者本机正在替别人问 Mac
    /// （10 分钟内开始的；卡住的请求不会让轮询一直快下去）。时间差按绝对值算：钟不准、或加入时间被写到了将来，
    /// 也只快 10 分钟。
    private func isOpening(_ state: RemoteGroupLocalState) -> Bool {
        let window = Self.hostFastPollingWindow
        if vouches.hasAttempt(startedWithin: window, of: now()) { return true }
        guard let admission = state.selfAdmission, admission.admitterKey != local.signingKey else { return false }
        return abs(now().timeIntervalSince(admission.admittedAt.date)) <= window
    }

    // MARK: - host

    /// 本机配对过的每台 Mac 一条本机签的 `host`；内容变了、或是本机进组之前签的（别的组员不认），重签。
    private func publishHostRecords(_ snapshot: RemoteGroupSnapshot, _ state: RemoteGroupLocalState,
                                    paired: [RemoteGroupVouchTarget]) {
        let joinedAt = state.selfAdmission?.admittedAt ?? .distantPast
        let mine = snapshot.hosts.filter { $0.signer == local.id }
        let wanted = Dictionary(paired.map { ($0.id, $0.hostInfo) }, uniquingKeysWith: { first, _ in first })
        for record in mine where wanted[record.host.id] == nil {
            roster.delete(account: record.account)
        }
        for (_, info) in wanted.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard !mine.contains(where: { $0.host == info && $0.signerKey == local.signingKey && $0.signedAt >= joinedAt })
            else { continue }
            do {
                write(.host(try RemoteGroupHost.make(host: info, signer: local, signedAt: max(RemoteGroupTime(now()), joinedAt),
                                                     key: signingKey)))
            } catch {
                fail(error)
            }
        }
    }

    // MARK: - 清理

    /// 本机签的 `grant`：对象已不是组员（被移除了、换了钥匙）、Mac 已不再配对的删掉。只有自己一台时全删。
    /// 本机是 Mac、写的是自己对组员的结果（`RemoteDeviceGroup+LocalHost.swift`）时不看配对，看本机此刻还认不认它：
    /// 你在这台 Mac 上撤销了（拉黑）就删掉。
    private func cleanUpGrants(_ snapshot: RemoteGroupSnapshot, _ state: RemoteGroupLocalState, paired: Set<UUID>) {
        for grant in snapshot.grants where grant.signer == local.id {
            let isMember = state.members.contains { grant.isFor($0.device) }
            let isCurrent = grant.host.id == local.id ? !isStaleLocalGrant(grant) : paired.contains(grant.host.id)
            if !isMember || !isCurrent {
                roster.delete(account: grant.account)
            }
        }
    }

    // MARK: - 收

    /// 写给本机、签名者是本机认的另一台组员、它进组之后签的结果，按 Mac 分好（同一台 Mac 的几条都在）。
    /// Mac 本身是组员时（它自己签、或别的组员替它签），结果里的公钥必须就是那台组员的远控公钥：
    /// 被偷的组员可以签一条冒用组里那台 Mac 的 ID、公钥换成自己的结果，这里挡掉。
    func acceptedGrants(_ snapshot: RemoteGroupSnapshot,
                        _ state: RemoteGroupLocalState) -> [(grant: RemoteGroupHostGrant, signer: RemoteGroupMember)] {
        let signers = RemoteGroupMembership.Signers(state: state, local: local)
        return snapshot.grants.compactMap { grant in
            guard grant.isFor(local), grant.host.id != local.id, grant.signerKey != local.signingKey,
                  signers.accepts(grant.signer, key: grant.signerKey, at: grant.signedAt),
                  let member = state.member(signingKey: grant.signerKey) else { return nil }
            let macMembers = state.members.filter { $0.device.id == grant.host.id }
            if !macMembers.isEmpty, !macMembers.contains(where: { $0.device.publicKey == grant.host.publicKey }) { return nil }
            return (grant, member)
        }
    }

    /// 收别的组员写给本机的结果，返回「还没通的 Mac」。因为结果才收下的 Mac 记进 `state.adoptedHosts`（回滚用）。
    private func receiveGrants(_ snapshot: RemoteGroupSnapshot, _ state: inout RemoteGroupLocalState,
                               hosts: any RemoteGroupHostAccess, paired: [RemoteGroupVouchTarget]) -> [PendingHost] {
        let signers = RemoteGroupMembership.Signers(state: state, local: local)
        /// 签名者是本机认的另一台组员、是它进组之后签的；返回那台组员（开中继包要用它在本机名单里的公钥）。
        func signer(_ id: UUID, _ key: Data, at time: RemoteGroupTime) -> RemoteGroupMember? {
            guard key != local.signingKey, signers.accepts(id, key: key, at: time) else { return nil }
            return state.member(signingKey: key)
        }

        // 几台组员都问过同一台 Mac：可用的那条优先，其次最新的。
        let accepted = acceptedGrants(snapshot, state)
        var chosen: [UUID: (grant: RemoteGroupHostGrant, signer: RemoteGroupMember)] = [:]
        for (grant, member) in accepted {
            if let current = chosen[grant.host.id]?.grant, !Self.prefers(grant, over: current) { continue }
            chosen[grant.host.id] = (grant, member)
        }

        // 组里知道的 Mac：我认的组员签的 `host`，加上写给本机的结果里的 Mac。名字取最新的那条。
        var known: [UUID: (info: RemoteGroupHostInfo, at: RemoteGroupTime)] = [:]
        func note(_ info: RemoteGroupHostInfo, at time: RemoteGroupTime) {
            guard info.id != local.id else { return }
            if let current = known[info.id], current.at >= time { return }
            known[info.id] = (info, time)
        }
        for record in snapshot.hosts where signer(record.signer, record.signerKey, at: record.signedAt) != nil {
            note(record.host, at: record.signedAt)
        }
        for (grant, _) in chosen.values { note(grant.host, at: grant.signedAt) }

        let pairedKeys = Dictionary(paired.map { ($0.id, $0.publicKey) }, uniquingKeysWith: { first, _ in first })
        var adoptionByHost: [UUID: RemoteGroupAdoption] = [:]
        for (hostID, entry) in chosen where entry.grant.isUsable {
            let result = adopt(entry.grant, from: entry.signer, pairedKey: pairedKeys[hostID], hosts: hosts)
            adoptionByHost[hostID] = result
            // 本机因为这条结果才记下它（之前不认识）：记下凭谁，签名者以后被移除时好回滚。
            if result == .added, !state.adoptedHosts.contains(where: { $0.hostID == hostID }),
               let trusted = hosts.trustedHost(hostID), trusted.publicKey == entry.grant.host.publicKey {
                state.adoptedHosts.append(RemoteGroupAdoptedHost(hostID: hostID, hostKey: trusted.publicKey,
                                                                 pairedAt: trusted.pairedAt,
                                                                 signers: [entry.grant.signerKey]))
            }
        }
        // 别的组员也开通过同一把钥匙的，一并记上：其中一台被移除，别的还在就不回滚。
        for index in state.adoptedHosts.indices {
            let adopted = state.adoptedHosts[index]
            for (grant, _) in accepted where grant.isUsable && grant.isAbout(adopted.hostID, key: adopted.hostKey)
                && !adopted.signers.contains(grant.signerKey) {
                state.adoptedHosts[index].signers.append(grant.signerKey)
            }
        }
        // 结果已经不在了（被删、签名者被移除）的 Mac 不再记着。
        adoptions = adoptions.filter { chosen[$0.key] != nil }

        var pending: [PendingHost] = []
        for (hostID, entry) in known {
            let status: PendingHost.Status?
            if let grant = chosen[hostID]?.grant {
                if grant.isUsable {
                    switch adoptionByHost[hostID] {
                    case .conflict: status = .needsPairing(.conflict)
                    case .forgotten: status = .needsPairing(.forgotten)
                    case .added, .alreadyKnown, nil: status = nil
                    }
                } else {
                    // Mac 不肯，但本机自己配对过它：照样能用。
                    status = pairedKeys[hostID] != nil ? nil : .needsPairing(Self.reason(for: grant.outcome))
                }
            } else {
                status = pairedKeys[hostID] != nil ? nil : .opening
            }
            if let status { pending.append(PendingHost(id: hostID, name: entry.info.name, status: status)) }
        }
        return pending.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    /// 同一台 Mac 有几条结果时取哪条：能用的优先，其次签得晚的，再按签名者排定。
    private static func prefers(_ lhs: RemoteGroupHostGrant, over rhs: RemoteGroupHostGrant) -> Bool {
        if lhs.isUsable != rhs.isUsable { return lhs.isUsable }
        if lhs.signedAt != rhs.signedAt { return lhs.signedAt > rhs.signedAt }
        return lhs.signerKey.lexicographicallyPrecedes(rhs.signerKey)
    }

    private static func reason(for outcome: String) -> PendingHost.Reason {
        switch outcome {
        case RemoteVouchResult.Outcome.notAllowed.rawValue: return .notAllowed
        case RemoteGroupGrant.unsupported: return .tooOld
        default: return .rejected
        }
    }

    /// 交给 `hosts.adopt`。同一条结果、本机记着的公钥也没变时不重复交（每次都要读本机钥匙串）。
    /// 中继包打不开（不是封给本机的、被改过、本机没有远控私钥）就不带中继，Mac 照样收下。
    private func adopt(_ grant: RemoteGroupHostGrant, from signer: RemoteGroupMember, pairedKey: Data?,
                       hosts: any RemoteGroupHostAccess) -> RemoteGroupAdoption {
        if let memo = adoptions[grant.host.id], memo.signature == grant.signature, memo.pairedKey == pairedKey {
            return memo.result
        }
        let relay = grant.relay.flatMap { openRelay($0, grant: grant, signer: signer) }
        if grant.relay != nil, relay == nil {
            AppLogger.notice("设备组：「\(signer.device.name)」替本机开通「\(grant.host.name)」带的中继包打不开，不带中继收下",
                             category: RemoteLog.category)
        }
        let result = hosts.adopt(grant.plain(relay: relay))
        adoptions[grant.host.id] = AdoptionMemo(signature: grant.signature, pairedKey: pairedKey, result: result)
        if pairedKey == nil || result != .alreadyKnown {
            AppLogger.notice("设备组：「\(signer.device.name)」替本机开通了「\(grant.host.name)」，收下的结果 \(result)",
                             category: RemoteLog.category)
        }
        return result
    }

    /// 用签名者在本机名单里的远控公钥（不是记录里自报的）开包。
    private func openRelay(_ box: Data, grant: RemoteGroupHostGrant, signer: RemoteGroupMember) -> RemoteRelayConfig? {
        guard let identityKey,
              let key = try? RemoteGroupRelaySeal.key(local: identityKey, remote: signer.device.publicKey) else { return nil }
        return RemoteGroupRelaySeal.open(box, key: key, signer: grant.signer, target: local.id, host: grant.host.id)
    }

    // MARK: - 问

    /// 每台此刻问得到、没在问、没在 60 秒冷却里的 Mac：有没撤完的移除先撤（`RemoteDeviceGroup+Revoke.swift`），
    /// 否则挑一个还需要问的组员去开通。刚进组的排前面。同一个设备 ID 在这台 Mac 上还有没撤完的，先不开通它
    /// （重装过的设备：先撤旧钥匙、再开新的）；组里同一个 ID 有两份钥匙时（旧的那份的移除还没读到）也先不开通。
    private func scheduleHostWork(_ snapshot: RemoteGroupSnapshot, _ state: RemoteGroupLocalState,
                                  hosts: any RemoteGroupHostAccess, vouching: Bool) {
        let signers = RemoteGroupMembership.Signers(state: state, local: local)
        let results = snapshot.grants.filter { signers.accepts($0.signer, key: $0.signerKey, at: $0.signedAt) }
        let members = state.members.sorted {
            ($0.admission.admittedAt, $0.device.id.uuidString) > ($1.admission.admittedAt, $1.device.id.uuidString)
        }
        for target in hosts.vouchTargets() where target.id != local.id && !vouches.isAsking(target.id) {
            if isCoolingDown(target.id) { continue }
            if let revocation = nextRevocation(at: target.id, in: state) {
                startRevoke(revocation, at: target, hosts: hosts)
                continue
            }
            guard vouching else { continue }
            let revoking = Set(state.revocations.filter { $0.isUnfinished(at: target.id) }.map(\.deviceID))
            // 组员就是这台 Mac 时不问；自称本机 ID 的组员（只有被偷的组员加得进来）也不问。
            guard let member = members.first(where: { $0.device.id != target.id && $0.device.id != local.id
                && !revoking.contains($0.device.id) && !hasTwin($0, in: state)
                && needsVouch($0.device, at: target, results: results) }) else { continue }
            startVouch(member.device, at: target, hosts: hosts)
        }
    }

    /// 这台 Mac 刚连不上过（60 秒内谁都不问它）。
    func isCoolingDown(_ host: UUID) -> Bool {
        guard let failed = hostFailures[host] else { return false }
        let age = now().timeIntervalSince(failed)
        return age >= 0 && age < Self.vouchRetryInterval
    }

    /// 组里还有一台同一个设备 ID、钥匙不同的组员（重装过的设备，旧的那份的移除还没读到）：先不替它开通，
    /// 不然 Mac 会以「换过钥匙」拒绝、写下有定论的结果，之后谁都不再问。
    func hasTwin(_ member: RemoteGroupMember, in state: RemoteGroupLocalState) -> Bool {
        state.members.contains { $0.device.id == member.device.id && $0.device.signingKey != member.device.signingKey }
    }

    /// 名册里没有我认的组员签的、针对 (这台组员现在的钥匙, 这台 Mac 现在的公钥) 的有定论的结果；不允许、版本太旧
    /// 的结果 6 小时内也不再问（不管是哪台组员问的：那是 Mac 的设置）。
    private func needsVouch(_ device: RemoteGroupDevice, at target: RemoteGroupVouchTarget,
                            results: [RemoteGroupHostGrant]) -> Bool {
        // 刚问过（结果写进去了，或被钥匙串圈里的人删了）：60 秒内不再问同一对，免得结果读不回来时一直问。
        if let asked = lastAsked[Self.askKey(device, target.id)] {
            let age = now().timeIntervalSince(asked)
            if age >= 0, age < Self.vouchRetryInterval { return false }
        }
        let relevant = results.filter { $0.isFor(device) && $0.isAbout(target.id, key: target.publicKey) }
        if relevant.contains(where: \.isFinal) { return false }
        if let latest = relevant.map(\.signedAt).max() {
            // 写到了将来很远的不算（钟不准、或被写坏了），免得永远不问。
            let age = now().timeIntervalSince(latest.date)
            if abs(age) < Self.vouchRefusedRetryInterval { return false }
        }
        return true
    }

    private func startVouch(_ device: RemoteGroupDevice, at target: RemoteGroupVouchTarget,
                            hosts: any RemoteGroupHostAccess) {
        let token = UUID()
        let task = Task { [weak self] in
            let outcome: Result<RemoteVouchResult, any Error>
            do {
                outcome = .success(try await hosts.vouch(device, at: target.id))
            } catch {
                outcome = .failure(error)
            }
            // 被取消的（模型释放、服务停了、本机被移出）什么都不写；令牌对不上说明这一次已经作废。
            guard let self, self.vouches.finish(target.id, token: token), !Task.isCancelled else { return }
            self.finishVouch(device, at: target, outcome)
        }
        vouches.start(target.id, token: token, at: now(), task: task)
        AppLogger.info("设备组：替「\(device.name)」问「\(target.name)」", category: RemoteLog.category)
    }

    private func finishVouch(_ device: RemoteGroupDevice, at target: RemoteGroupVouchTarget,
                             _ outcome: Result<RemoteVouchResult, any Error>) {
        var result = RemoteGroupGrant(hostID: target.id, hostName: target.name, hostKey: target.publicKey,
                                      hostModel: target.model, hostPlatform: target.platform, outcome: "")
        switch outcome {
        case .success(let reply):
            result.outcome = reply.outcome
            result.reason = reply.reason
            result.internetAccess = reply.internetAccess
            // Mac 发的成员证书优先；没有就交本机给这台 Mac 单独记的中继（默认中继新设备经 iCloud 钥匙串本来就有）。
            result.relay = reply.relay ?? (reply.internetAccess == true ? target.relay : nil)
        case .failure(let error):
            if case .rejected(let reason)? = error as? RemoteAttachError {
                // Mac 上的 uTerm 太旧，不认担保（`RemoteMacClient.vouch(for:)`）。
                result.outcome = RemoteGroupGrant.unsupported
                result.reason = reason
            } else {
                if error is CancellationError { return }
                // 连不上：不写，这台 Mac 60 秒后再问。
                hostFailures[target.id] = now()
                AppLogger.info("设备组：替「\(device.name)」问「\(target.name)」没连上：\(error.localizedDescription)",
                               category: RemoteLog.category)
                return
            }
        }
        guard !result.outcome.isEmpty else { return }
        hostFailures[target.id] = nil
        lastAsked[Self.askKey(device, target.id)] = now()
        // 问的这段时间里本机被移出、或它已经不是组员（被移除、换了钥匙）：不写。
        guard let state = loadState(), !state.selfRemoved, !state.members.isEmpty,
              let member = state.members.first(where: { $0.device.sameKeys(as: device) }) else {
            AppLogger.notice("设备组：「\(target.name)」对「\(device.name)」的结果回来时它已不在组里，不写",
                             category: RemoteLog.category)
            return
        }
        var box: Data?
        if let relay = result.relay, let identityKey {
            box = try? RemoteGroupRelaySeal.seal(relay, key: RemoteGroupRelaySeal.key(local: identityKey,
                                                                                      remote: member.device.publicKey),
                                                 signer: local.id, target: member.device.id, host: target.id)
        }
        let joinedAt = state.selfAdmission?.admittedAt ?? .distantPast
        do {
            try roster.save(.grant(try RemoteGroupHostGrant.make(device: member.device, host: target.hostInfo,
                                                                 outcome: result.outcome, reason: result.reason,
                                                                 internetAccess: result.internetAccess, relay: box,
                                                                 signer: local, signedAt: max(RemoteGroupTime(now()), joinedAt),
                                                                 key: signingKey)))
        } catch {
            // 写不进去：这台 Mac 也冷却 60 秒，不然下一轮立刻又问一遍。
            fail(error)
            hostFailures[target.id] = now()
            return
        }
        AppLogger.notice("设备组：「\(target.name)」对「\(device.name)」的开通结果 \(result.outcome)", category: RemoteLog.category)
        refresh()
    }

    // MARK: - 量一跳的耗时

    /// 别的设备写给本机的 `answer` / `done` / `admit` / `grant` 第一次读到时记一行「写入后 N 秒读到」。
    /// 模型建好后第一轮就在的不记（那不是这一跳）。写入时间是对方的钟，差值里含两台的钟差。
    func noteArrivals(_ snapshot: RemoteGroupSnapshot) {
        var current: [Data: (kind: String, writer: UUID, at: Date)] = [:]
        for answer in snapshot.answers where answer.candidate == local.id && answer.member.id != local.id {
            current[answer.confirmation] = ("answer", answer.member.id, answer.createdAt)
        }
        for done in snapshot.dones where done.member == local.id && done.candidate != local.id {
            current[done.confirmation] = ("done", done.candidate, done.createdAt)
        }
        for admit in snapshot.admits where admit.device.signingKey == local.signingKey && admit.signer != local.id {
            current[admit.signature] = ("admit", admit.signer, admit.signedAt.date)
        }
        for grant in snapshot.grants where grant.isFor(local) && grant.signer != local.id {
            current[grant.signature] = ("grant", grant.signer, grant.signedAt.date)
        }
        defer { arrivals = Set(current.keys) }
        guard let seen = arrivals else { return }
        for (key, record) in current where !seen.contains(key) {
            let seconds = now().timeIntervalSince(record.at)
            AppLogger.notice("设备组：读到 \(record.writer.uuidString.prefix(8)) 写给本机的 \(record.kind)，写入后 "
                             + String(format: "%.1f", seconds) + " 秒读到", category: RemoteLog.category)
        }
    }
}

/// 正在问的 Mac：每台一次只有一个请求。`nonisolated` 好让它在模型释放时（`deinit`）取消还在问的请求；
/// 平时只在主线程上用。
nonisolated final class RemoteGroupVouchTasks {
    private struct Attempt {
        let token: UUID
        let startedAt: Date
        let task: Task<Void, Never>
    }

    private var attempts: [UUID: Attempt] = [:]

    var count: Int { attempts.count }

    func isAsking(_ host: UUID) -> Bool { attempts[host] != nil }

    func start(_ host: UUID, token: UUID, at date: Date, task: Task<Void, Never>) {
        attempts[host]?.task.cancel()
        attempts[host] = Attempt(token: token, startedAt: date, task: task)
    }

    /// 这一次问完了。令牌对不上（已被取消、换成了新的一次）返回 false。
    func finish(_ host: UUID, token: UUID) -> Bool {
        guard attempts[host]?.token == token else { return false }
        attempts[host] = nil
        return true
    }

    func hasAttempt(startedWithin window: TimeInterval, of now: Date) -> Bool {
        attempts.values.contains { abs(now.timeIntervalSince($0.startedAt)) <= window }
    }

    func cancelAll() {
        for attempt in attempts.values { attempt.task.cancel() }
        attempts = [:]
    }

    deinit {
        for attempt in attempts.values { attempt.task.cancel() }
    }
}
