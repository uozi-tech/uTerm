import Foundation

/// 把每个 AIProvider 的 API key 存进钥匙串。account 用 provider.id.uuidString，
/// 委托给 KeychainStore，同样 kSecAttrSynchronizable = true，经 iCloud 钥匙串
/// 端到端加密同步。API key 正文**不进**局域网快照。
nonisolated struct AgentKeychain {
    private let store: KeychainStore

    init(service: String = "com.uozi.uTerm") {
        self.store = KeychainStore(service: service)
    }

    func save(_ key: String, for providerID: UUID) throws {
        try store.save(key, account: providerID.uuidString)
    }

    func load(for providerID: UUID) -> String? {
        (try? store.load(account: providerID.uuidString)) ?? nil
    }

    func delete(for providerID: UUID) throws {
        try store.delete(account: providerID.uuidString)
    }

    /// 启动时静默清理 M5 残留的单 key 条目（account == "anthropic-api-key"）。
    /// 失败不抛错——条目不存在是正常情况。
    static func purgeLegacy(service: String = "com.uozi.uTerm") {
        let s = KeychainStore(service: service)
        try? s.delete(account: "anthropic-api-key")
    }
}
