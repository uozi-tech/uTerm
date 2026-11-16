import Foundation

/// 组员名单怎么算（docs/remote-device-group-design.md §7.1「组员名单怎么算」）。纯函数：本机状态 + 名册 → 新的本机状态。
///
/// - 一台设备（按 Ed25519 公钥认）是组员，当且仅当有一条本机认的 `admit`，它的加入时间晚于本机记下的、
///   针对这把钥匙的最晚一条移除。
/// - 「本机认的」记录 = 签名者是本机此刻认的组员（或本机自己），并且是它进组之后签的（`Signers`）。
///   名册里的签名本身在解码时就验过了（`RemoteGroupRecord.decode`）。
/// - 每一遍先处理 `remove`、再处理 `admit`，反复到不再变化。`remove` 按时间先后一条条应用、每条都按此刻的
///   组员判断签名者；`admit` 按这一阶段开始时的组员判断。结果与记录在名册里的先后无关。
/// - `admit` 里写的最初添加者，签名在解码时验过；这里再要求添加者是本机认得的设备（`Signers.knowsAdmitter`）。
/// - 认过的组员不会因为它的添加者后来被移除而失去资格（各组员互相补签就是为了这个）。
nonisolated enum RemoteGroupMembership {
    static func resolve(_ state: RemoteGroupLocalState, snapshot: RemoteGroupSnapshot,
                        local: RemoteGroupDevice) -> RemoteGroupLocalState {
        var state = state
        // 按时间先后处理、每应用一条就重新看签名者：一台设备被移除之后它再签的移除不算，离线很久的设备
        // 同时读到两条时也一样。
        let removes = snapshot.removes
            .filter { $0.signingKey != local.signingKey }
            .sorted { ($0.removedAt, $0.signerKey.base64EncodedString()) < ($1.removedAt, $1.signerKey.base64EncodedString()) }
        // 每一遍至少多认一台或多记一条移除，记录有限，所以一定停得下来；上限只是保险。
        for _ in 0...(snapshot.admits.count + snapshot.removes.count) {
            var changed = false
            for remove in removes {
                let signers = Signers(state: state, local: local)
                guard signers.accepts(remove.signer, key: remove.signerKey, at: remove.removedAt),
                      appliesAsLeave(remove, state: state) else { continue }
                if state.recordRemoval(removal(remove, state: state, signers: signers)) {
                    changed = true
                    state.dropRemovedMembers()
                }
            }

            let admitters = Signers(state: state, local: local)
            var admitted: [Data: RemoteGroupMember] = [:]
            for admit in snapshot.admits {
                let key = admit.device.signingKey
                guard key != local.signingKey, state.member(signingKey: key) == nil,
                      admitters.accepts(admit.signer, key: admit.signerKey, at: admit.signedAt),
                      admitters.knowsAdmitter(admit.admission) else { continue }
                if let removal = state.latestRemoval(of: key), removal >= admit.admission.admittedAt { continue }
                let member = RemoteGroupMember(device: admit.device, admission: admit.admission)
                if let current = admitted[key], !prefers(member, over: current) { continue }
                admitted[key] = member
            }
            if !admitted.isEmpty {
                state.members += admitted.values.sorted { $0.device.signingKey.lexicographicallyPrecedes($1.device.signingKey) }
                changed = true
            }
            if !changed { break }
        }
        if isSelfRemoved(state, snapshot: snapshot, local: local) { state.selfRemoved = true }
        return state
    }

    /// 自己签的移除（离开）只对它带着的那一次加入生效：设备在核对通过、已经被新组记下之后才签离开，
    /// 离开记录的时间晚于新组给它的加入时间，按时间比就会把它从新组里也去掉。本机没把它当成那一次加入的
    /// 组员时（新组的设备、或还没认它的设备），这条什么都不做，也不记成移除。
    /// 别人签的移除照旧只按时间比：不同设备可能按不同的 admit 认了同一台（被偷的组员能各写一份），
    /// 按加入信息匹配的话，在这台设备上移除就移不到那台上。
    private static func appliesAsLeave(_ remove: RemoteGroupRemove, state: RemoteGroupLocalState) -> Bool {
        guard remove.signerKey == remove.signingKey else { return true }
        guard let admission = remove.admission, let member = state.member(signingKey: remove.signingKey) else { return false }
        return member.admission == admission
    }

    /// 本机要记的那条移除。被移除者在本机名单里，就记本机那份加入信息；不在（本机没赶上它进组），就用移除记录
    /// 里带的那份，前提是添加者本机认得、不是它自己（「我是第一台」只有当过它的组员的设备才知道是真的）。
    /// 被偷的组员现造一把钥匙、自己签一份「我加的」、再移除它：这台钥匙算认得的添加者，但它在被偷组员的
    /// 移除连带链条上，躲不掉。
    private static func removal(_ remove: RemoteGroupRemove, state: RemoteGroupLocalState,
                                signers: Signers) -> RemoteGroupRemoval {
        var admission = state.member(signingKey: remove.signingKey)?.admission
        if admission == nil, let carried = remove.verifiedAdmission, !carried.isSelfAdmission(of: remove.signingKey),
           signers.knowsAdmitter(carried) {
            admission = carried
        }
        return RemoteGroupRemoval(deviceID: remove.deviceID, publicKey: remove.publicKey, signingKey: remove.signingKey,
                                  removedAt: remove.removedAt, admission: admission)
    }

    /// 同一把钥匙有几条可认的 `admit`（重新加入过、或补签时内容不同）：取最近那次加入，再按添加者排定。
    private static func prefers(_ lhs: RemoteGroupMember, over rhs: RemoteGroupMember) -> Bool {
        if lhs.admission.admittedAt != rhs.admission.admittedAt {
            return lhs.admission.admittedAt > rhs.admission.admittedAt
        }
        return lhs.admission.admitterKey.lexicographicallyPrecedes(rhs.admission.admitterKey)
    }

    /// 本机被移出：本机认的组员（不是本机自己——离开时自己签的那条不算）签了一条针对本机钥匙的 `remove`，
    /// 时间不早于本机这一次加入。没有加入时间（一直只有自己一台）时谁都移不了本机：认的组员也没有。
    static func isSelfRemoved(_ state: RemoteGroupLocalState, snapshot: RemoteGroupSnapshot,
                              local: RemoteGroupDevice) -> Bool {
        let joinedAt = state.selfAdmission?.admittedAt ?? .distantPast
        let signers = Signers(state: state, local: local)
        return snapshot.removes.contains { remove in
            remove.signingKey == local.signingKey && remove.signerKey != local.signingKey
                && remove.removedAt >= joinedAt
                && signers.accepts(remove.signer, key: remove.signerKey, at: remove.removedAt)
        }
    }

    /// 某一刻本机认的签名者：本机自己 + 认的组员，各带它进组的时间；另记着本机移除过的设备。
    struct Signers {
        private var joinedAt: [Data: (id: UUID, at: RemoteGroupTime)] = [:]
        private var removed: [Data: UUID] = [:]

        init(state: RemoteGroupLocalState, local: RemoteGroupDevice) {
            for member in state.members {
                joinedAt[member.device.signingKey] = (member.device.id, member.admission.admittedAt)
            }
            joinedAt[local.signingKey] = (local.id, state.selfAdmission?.admittedAt ?? .distantPast)
            for removal in state.removals where removal.admission != nil { removed[removal.signingKey] = removal.deviceID }
        }

        /// `admit` 里写的最初添加者本机认得：是本机、本机认的组员，或本机确认当过组员、后来被移除的设备
        /// （移除记录带着它的加入信息，见 `RemoteGroupRemoval.admission`；添加者后来被移除，它加的设备照样由补签
        /// 留在组里），而且 ID 与钥匙对得上本机记的那台。
        ///
        /// 从没见过的钥匙不认：被偷的组员可以现造一把钥匙、给它加的设备签一份「由这把钥匙添加」，
        /// 让这台设备不在自己的移除连带里。一时不认得（添加者的 `admit` 还没同步到）的，等添加者先被认下，下一遍再看。
        func knowsAdmitter(_ admission: RemoteGroupAdmission) -> Bool {
            if let entry = joinedAt[admission.admitterKey] { return entry.id == admission.admitterID }
            return removed[admission.admitterKey] == admission.admitterID
        }

        /// 签名者 ID 与钥匙都对得上，而且这条是它进组之后签的。
        func accepts(_ signer: UUID, key: Data, at time: RemoteGroupTime) -> Bool {
            guard let entry = joinedAt[key], entry.id == signer else { return false }
            return time >= entry.at
        }
    }
}
