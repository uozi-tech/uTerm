import Foundation
import SwiftData

/// ServerProfile ordering helpers. `sortOrder` is global, while grouped views
/// display a filtered slice of that global order.
@MainActor
struct ServerProfileStore {
    let context: ModelContext

    func nextSortOrder() -> Int {
        let profiles = (try? context.fetch(FetchDescriptor<ServerProfile>())) ?? []
        return (profiles.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Reorders a visible filtered slice by replacing its original slots in
    /// the complete visible order, then compacts all profiles to 0...n.
    func reorderVisible(_ orderedVisible: [ServerProfile], within allProfiles: [ServerProfile]) {
        guard !orderedVisible.isEmpty else { return }
        let visibleIDs = Set(orderedVisible.map(\.id))
        var replacement = orderedVisible.makeIterator()
        var merged: [ServerProfile] = []

        for profile in allProfiles {
            if visibleIDs.contains(profile.id) {
                guard let next = replacement.next() else { return }
                merged.append(next)
            } else {
                merged.append(profile)
            }
        }

        guard replacement.next() == nil else { return }
        reorderAll(merged)
    }

    func reorderAll(_ ordered: [ServerProfile]) {
        var changed = false
        for (index, profile) in ordered.enumerated() where profile.sortOrder != index {
            profile.sortOrder = index
            changed = true
        }
        if changed { try? context.save() }
    }

    /// 删除一台主机及其附属数据，两端共用：
    /// - 钥匙串里**本主机自己**的 password / passphrase / 旧版按 `profile.id` 存的 privateKey；
    /// - 按 serverID 关联的端口转发规则（不删会成无主孤儿）；
    /// - 其它主机里把它当跳板机的 `jumpHost` 引用显式置空（否则留下指向已删服务器的悬空引用）。
    ///
    /// `jumpHost` 是「引用一台已有服务器」，被引用者本身仍是正常服务器——故绝不删
    /// `profile.jumpHost` 或它的 secrets / 规则。关会话等界面收尾由调用方在调用前做。
    func delete(_ profile: ServerProfile, keychain: KeychainStore = KeychainStore()) {
        let id = profile.id
        for kind in [SecretKind.password, .passphrase, .privateKey] {
            try? keychain.delete(profileID: id, kind: kind)
        }
        ForwardingRuleStore(context: context).deleteAll(forServer: id)
        let profiles = (try? context.fetch(FetchDescriptor<ServerProfile>())) ?? []
        for other in profiles where other.id != id && other.jumpHost?.id == id {
            other.jumpHost = nil
        }
        context.delete(profile)
        try? context.save()
    }
}
