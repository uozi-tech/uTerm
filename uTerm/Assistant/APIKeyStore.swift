import Foundation

/// 把用户的 Anthropic API Key 存进 macOS 钥匙串的单条全局条目。
/// 委托给 `KeychainStore`，条目同样 `kSecAttrSynchronizable = true`，
/// 经 iCloud Keychain 端到端加密同步。
nonisolated struct APIKeyStore {
    private static let account = "anthropic-api-key"
    private let store: KeychainStore

    init(service: String = "com.uozi.uTerm") {
        store = KeychainStore(service: service)
    }

    func save(_ key: String) throws {
        try store.save(key, account: Self.account)
    }

    func load() -> String? {
        (try? store.load(account: Self.account)) ?? nil
    }

    func delete() throws {
        try store.delete(account: Self.account)
    }
}
