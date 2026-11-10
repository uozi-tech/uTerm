import Foundation

/// 按网络类型记最近几次打洞成败，决定下次等直连多久。
///
/// 蜂窝网络多半是对称 NAT，实测 IPv4 打洞 0/6（调研 §15）。每次都等满 3 秒再走中继，弱网下连一次就白等 3 秒。
/// 中继与打洞同时开始拨（`RemotePathDialer`），所以等多久只决定「直连有多少时间抢在中继前面」：
/// 这种网络上最近连着几次都没打通，就只给它一小段；有一次通了就恢复成完整的时间。
nonisolated struct RemoteDirectHistory: Sendable {
    /// 每种网络记几次。
    static let depth = 5
    /// 连着失败几次就缩短。
    static let failuresBeforeShortening = 3
    static let fullWindow: Duration = .seconds(3)
    static let shortWindow: Duration = .milliseconds(800)
    static let standard = RemoteDirectHistory(defaults: RemoteLocalState.defaults)
    private static let key = DefaultsKey.remoteDirectOutcomes
    private static let lock = NSLock()

    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 最近的结果，新的在后。
    func outcomes(on network: String) -> [Bool] {
        load()[network] ?? []
    }

    func record(_ succeeded: Bool, on network: String) {
        Self.lock.withLock {
            var all = load()
            all[network] = Array(((all[network] ?? []) + [succeeded]).suffix(Self.depth))
            if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
        }
    }

    /// 这次等直连多久。
    func window(on network: String) -> Duration {
        let recent = outcomes(on: network).suffix(Self.failuresBeforeShortening)
        let shorten = recent.count == Self.failuresBeforeShortening && !recent.contains(true)
        return shorten ? Self.shortWindow : Self.fullWindow
    }

    private func load() -> [String: [Bool]] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: [Bool]].self, from: data)) ?? [:]
    }
}
