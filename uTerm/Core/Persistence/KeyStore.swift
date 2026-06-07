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

    func privateKey(keyID: UUID) -> String? {
        try? keychain.load(profileID: keyID, kind: .privateKey)
    }

    func passphrase(keyID: UUID) -> String? {
        try? keychain.load(profileID: keyID, kind: .passphrase)
    }

    /// 删除一把密钥的全部钟匙串条目（删除密钥时调用）。
    func delete(keyID: UUID) {
        try? keychain.delete(profileID: keyID, kind: .privateKey)
        try? keychain.delete(profileID: keyID, kind: .passphrase)
    }
}
