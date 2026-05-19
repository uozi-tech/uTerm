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

    private func baseQuery(_ profileID: UUID, _ kind: SecretKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(profileID, kind),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
    }

    func save(_ value: String, profileID: UUID, kind: SecretKind) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }
        try delete(profileID: profileID, kind: kind)
        var query = baseQuery(profileID, kind)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func load(profileID: UUID, kind: SecretKind) throws -> String? {
        var query = baseQuery(profileID, kind)
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

    func delete(profileID: UUID, kind: SecretKind) throws {
        let status = SecItemDelete(baseQuery(profileID, kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
