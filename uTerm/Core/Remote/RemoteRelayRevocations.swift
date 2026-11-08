import Foundation

/// 被控端要吊销、中继还没确认的成员证书，按中继分开存。中继此刻连不上也不丢：下次注册上就补发，
/// 中继回 `revoked` 才划掉。
nonisolated struct RemoteRelayRevocations {
    /// 每台中继最多记这么多。超出时丢最旧的：那张证书在中继上就一直有效，但只能在中继上找到这台 Mac，
    /// 配对身份早已删除，连不进来。换了另一台中继（relayID 变了）时，旧中继的待发吊销没有连接可发，留着不动。
    static let limit = 1024
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
