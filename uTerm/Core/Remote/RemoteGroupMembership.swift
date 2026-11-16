import Foundation

/// 组员名单怎么算（docs/remote-device-group-design.md §7.1「组员名单怎么算」）。纯函数：本机状态 + 名册 → 新的本机状态。
///
/// - 一台设备（按 Ed25519 公钥认）是组员，当且仅当有一条本机认的 `admit`，它的加入时间晚于本机记下的、
///   针对这把钥匙的最晚一条移除。
/// - 「本机认的」记录 = 签名者是本机此刻认的组员（或本机自己），并且是它进组之后签的（`Signers`）。
///   名册里的签名本身在解码时就验过了（`RemoteGroupRecord.decode`）。
/// - 每一遍先处理 `remove`、再处理 `admit`，反复到不再变化。`remove` 按时间先后一条条应用、每条都按此刻的
///   组员判断签名者；`admit` 按这一阶段开始时的组员判断。结果与记录在名册里的先后无关。
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
            for remove in removes where Signers(state: state, local: local)
                .accepts(remove.signer, key: remove.signerKey, at: remove.removedAt) {
                if state.recordRemoval(remove.removal) {
                    changed = true
                    state.dropRemovedMembers()
                }
            }

            let admitters = Signers(state: state, local: local)
            var admitted: [Data: RemoteGroupMember] = [:]
            for admit in snapshot.admits {
                let key = admit.device.signingKey
                guard key != local.signingKey, state.member(signingKey: key) == nil,
                      admitters.accepts(admit.signer, key: admit.signerKey, at: admit.signedAt) else { continue }
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

    /// 某一刻本机认的签名者：本机自己 + 认的组员，各带它进组的时间。
    struct Signers {
        private var joinedAt: [Data: (id: UUID, at: RemoteGroupTime)] = [:]

        init(state: RemoteGroupLocalState, local: RemoteGroupDevice) {
            for member in state.members {
                joinedAt[member.device.signingKey] = (member.device.id, member.admission.admittedAt)
            }
            joinedAt[local.signingKey] = (local.id, state.selfAdmission?.admittedAt ?? .distantPast)
        }

        /// 签名者 ID 与钥匙都对得上，而且这条是它进组之后签的。
        func accepts(_ signer: UUID, key: Data, at time: RemoteGroupTime) -> Bool {
            guard let entry = joinedAt[key], entry.id == signer else { return false }
            return time >= entry.at
        }
    }
}
