import Foundation
import Security

/// 一个密钥条目的用途。与 `ServerProfile.id` 组合成钥匙串 account。
enum SecretKind: String, Sendable {
    case password
    case passphrase
    /// 私钥文件的完整内容（PEM/OpenSSH 文本）。
    case privateKey
}

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
    case dataEncodingFailed
}

/// 对 macOS 钥匙串的封装。所有写入条目设 `kSecAttrSynchronizable = true`，
/// 从而通过 iCloud Keychain 端到端加密同步到用户的其它设备。
///
/// `nonisolated`：纯非 UI 工具类型，仅与 Security 框架交互，无需 MainActor 隔离。
nonisolated struct KeychainStore {
    private let service: String

    init(service: String = "com.uozi.uTerm") {
        self.service = service
    }

    private func account(_ profileID: UUID, _ kind: SecretKind) -> String {
        "\(profileID.uuidString)/\(kind.rawValue)"
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
    }

    // MARK: - 按 account 字符串的通用读写

    func save(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }
        try delete(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func load(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue!
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - 按服务器 profile + 用途的条目

    func save(_ value: String, profileID: UUID, kind: SecretKind) throws {
        try save(value, account: account(profileID, kind))
    }

    func load(profileID: UUID, kind: SecretKind) throws -> String? {
        try load(account: account(profileID, kind))
    }

    func delete(profileID: UUID, kind: SecretKind) throws {
        try delete(account: account(profileID, kind))
    }
}
