import Foundation

/// 被控端要吊销、中继还没确认的成员证书，按中继分开存（成员公钥 → 证书到期时间）。中继此刻连不上也不丢：
/// 下次注册上就补发，中继回 `revoked` 才划掉。证书已经过期的不用再发，直接划掉。
nonisolated struct RemoteRelayRevocations {
    /// 每台中继最多记这么多，满了丢最快到期的。证书最长 90 天就过期，这里只会在 90 天里吊销上千张时才满。
    /// 换了另一台中继（relayID 变了）时，旧中继的待发吊销没有连接可发，留到证书过期自己清掉。
    static let limit = 1024
    let defaults: UserDefaults
    var now: () -> Date = Date.init

    struct Pending: Equatable {
        var member: String
        /// 证书到期时间（Unix 秒）；1.2.x 发的证书没有，中继按最长有效期记。
        var expires: Int64?
    }

    func pending(relayID: String) -> [Pending] {
        (all()[relayID] ?? [:]).map { Pending(member: $0.key, expires: $0.value > 0 ? $0.value : nil) }
            .sorted { $0.member < $1.member }
    }

    func add(_ member: String, relayID: String, expires: Int64?) {
        var table = all()
        var list = table[relayID] ?? [:]
        let value = expires ?? 0
        // 续过期的证书再吊销时，按更晚的到期时间记。
        if let current = list[member], current == 0 || (value != 0 && current >= value) { return }
        list[member] = value
        if list.count > Self.limit {
            let dropped = list.filter { $0.key != member }
                .sorted { ($0.value == 0 ? Int64.max : $0.value, $0.key) < ($1.value == 0 ? Int64.max : $1.value, $1.key) }
                .prefix(list.count - Self.limit)
            for entry in dropped { list[entry.key] = nil }
        }
        table[relayID] = list
        save(table)
    }

    func confirm(_ member: String, relayID: String) {
        var table = all()
        guard var list = table[relayID], list[member] != nil else { return }
        list[member] = nil
        table[relayID] = list.isEmpty ? nil : list
        save(table)
    }

    /// 读出来时顺手划掉证书已过期的：中继本来就不认了。
    private func all() -> [String: [String: Int64]] {
        let raw = defaults.dictionary(forKey: DefaultsKey.remoteRelayPendingRevocations) as? [String: [String: Int64]]
            ?? [:]
        let cutoff = Int64(now().timeIntervalSince1970)
        return raw.compactMapValues { list in
            let live = list.filter { $0.value == 0 || $0.value > cutoff }
            return live.isEmpty ? nil : live
        }
    }

    private func save(_ table: [String: [String: Int64]]) {
        defaults.set(table, forKey: DefaultsKey.remoteRelayPendingRevocations)
    }
}
