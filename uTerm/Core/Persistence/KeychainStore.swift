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

extension KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "未知"
            return "钥匙串错误 \(status)（\(msg)）"
        case .dataEncodingFailed:
            return "密钥数据编码失败"
        }
    }
}

/// 读取一条钥匙串密钥的最小可注入接口。`SSHAuthResolver` 据此解析认证材料，
/// 单测可注入抛错 / not-found 的桩，端到端驱动「钥匙串被锁」与「条目不存在」两条路径。
nonisolated protocol KeychainReading {
    /// 条目不存在返回 `nil`；其余错误（钥匙串被锁、`errSecAuthFailed` 等）抛出。
    func load(profileID: UUID, kind: SecretKind) throws -> String?
}

/// 对钥匙串的封装。写入条目设 `kSecAttrSynchronizable = true`，因而经 iCloud 钥匙串
/// 端到端加密同步到用户的其它设备（保底通道）。凭据正文**不进**局域网快照。
///
/// `nonisolated`：纯非 UI 工具类型，仅与 Security 框架交互，无需 MainActor 隔离。
nonisolated struct KeychainStore: KeychainReading {
    /// SSH 密码、私钥与 Provider key 只应在设备已解锁时可用。`AfterFirstUnlock`
    /// 会让锁屏后的后台进程继续读取凭据，与应用锁的执行边界相冲突。
    static let accessibility = kSecAttrAccessibleWhenUnlocked as String

    private let service: String

    init(service: String = "com.uozi.uTerm") {
        self.service = service
    }

    private func account(_ profileID: UUID, _ kind: SecretKind) -> String {
        "\(profileID.uuidString)/\(kind.rawValue)"
    }

    /// 条目的公共匹配键。
    ///
    /// ⚠️ `kSecAttrSynchronizable` **参与匹配**：以 `true` 写入的条目，用 `false` 查询查不到，
    /// 反之亦然。曾因把该值从 `true` 翻成 `false` 而没有迁移，导致升级后读不到任何已存凭据。
    /// 因此这里定死规矩：**读取与删除一律用 `kSecAttrSynchronizableAny`**（两种形态都命中），
    /// 只有 `save` 写入时才挑一个具体值。
    private func baseQuery(account: String,
                           synchronizable: Any = kSecAttrSynchronizableAny) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
        ]
    }

    // MARK: - 按 account 字符串的通用读写

    func save(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }
        // delete 用 Any 匹配，连同历史上以 synchronizable=false 写入的条目一并清掉，
        // 于是每次保存都把该 account 收敛成唯一一条可同步条目。
        try delete(account: account)
        var query = baseQuery(account: account, synchronizable: kCFBooleanTrue!)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = Self.accessibility
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
