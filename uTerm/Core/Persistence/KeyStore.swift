import Foundation

/// 密钥库的私钥 / 口令存取层。薄封装 `KeychainStore` —— 以 `SSHKey.id` 为
/// account 前缀（与 `ServerProfile` 的密钥存储同一套约定，复用 `SecretKind`）。
///
/// 私钥正文与导入口令永不进 SwiftData / CloudKit 明文，只走钟匙串（系统加密 +
/// iCloud Keychain e2e 同步）。
nonisolated struct KeyStore {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    /// 写入一把密钥的私钥正文（OpenSSH / PEM 文本），可选导入口令。
    func save(keyID: UUID, privateKey: String, passphrase: String?) throws {
        try keychain.save(privateKey, profileID: keyID, kind: .privateKey)
        if let passphrase, !passphrase.isEmpty {
            try keychain.save(passphrase, profileID: keyID, kind: .passphrase)
        } else {
            try keychain.delete(profileID: keyID, kind: .passphrase)
        }
    }

    /// 读取私钥正文。条目不存在返回 `nil`（沿用 `KeychainStore.load` 语义）；
    /// 钥匙串读取失败（被锁 / `errSecAuthFailed` 等）则上抛，调用方据此区分
    /// 「没存私钥」与「钥匙串访问出错」，不再被 `try?` 静默吞成 `nil`。
    func privateKey(keyID: UUID) throws -> String? {
        try keychain.load(profileID: keyID, kind: .privateKey)
    }

    /// 读取导入口令。语义同 `privateKey(keyID:)`：不存在返回 `nil`，访问出错上抛。
    func passphrase(keyID: UUID) throws -> String? {
        try keychain.load(profileID: keyID, kind: .passphrase)
    }

    /// 删除一把密钥的全部钟匙串条目（删除密钥时调用）。
    func delete(keyID: UUID) {
        try? keychain.delete(profileID: keyID, kind: .privateKey)
        try? keychain.delete(profileID: keyID, kind: .passphrase)
    }
}
