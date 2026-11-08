import Foundation

/// 被控端要吊销、中继还没确认的成员证书，按中继分开存。中继此刻连不上也不丢：下次注册上就补发，
/// 中继回 `revoked` 才划掉。
nonisolated struct RemoteRelayRevocations {
    /// 每台中继最多记这么多；再多说明那台中继一直没回，旧的丢掉也只是少吊销几张早就不用的证书。
    static let limit = 256
    let defaults: UserDefaults

    func pending(relayID: String) -> [String] {
        all()[relayID] ?? []
    }

    func add(_ member: String, relayID: String) {
        var table = all()
        var list = table[relayID] ?? []
        guard !list.contains(member) else { return }
        list.append(member)
        table[relayID] = Array(list.suffix(Self.limit))
        defaults.set(table, forKey: DefaultsKey.remoteRelayPendingRevocations)
    }

    func confirm(_ member: String, relayID: String) {
        var table = all()
        guard var list = table[relayID], let index = list.firstIndex(of: member) else { return }
        list.remove(at: index)
        table[relayID] = list.isEmpty ? nil : list
        defaults.set(table, forKey: DefaultsKey.remoteRelayPendingRevocations)
    }

    private func all() -> [String: [String]] {
        defaults.dictionary(forKey: DefaultsKey.remoteRelayPendingRevocations) as? [String: [String]] ?? [:]
    }
}
