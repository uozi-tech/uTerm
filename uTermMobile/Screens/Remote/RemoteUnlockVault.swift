import Foundation
import LocalAuthentication
import Security

/// 手机上保存的「某台 Mac 的登录密码」。密码只存在这台手机的钥匙串里，不随 iCloud 同步，取出时必须通过
/// Face ID / Touch ID，用于远程解锁那台 Mac 的锁屏。
///
/// 抽成协议是为了让测试用内存假件，不碰真实钥匙串与生物识别。
@MainActor
protocol RemoteUnlockPasswordStore {
    /// 取出某台 Mac 的密码（会触发一次 Face ID）；没存过返回 nil。
    func password(forMac macID: UUID, reason: String) async throws -> String?
    /// 存 / 覆盖某台 Mac 的密码。
    func save(_ password: String, forMac macID: UUID) throws
    /// 删掉某台 Mac 的密码（忘记这台 Mac、或用户要求清除时）。
    func remove(forMac macID: UUID)
    /// 是否已存过这台 Mac 的密码（决定界面显示「解锁」还是「先设置密码」）。不触发 Face ID。
    func hasPassword(forMac macID: UUID) -> Bool
}

enum RemoteUnlockVaultError: Error {
    case biometryUnavailable
    case keychain(OSStatus)

    /// 给人看的原因（带系统错误码，便于排查）。
    static func describe(_ error: Error) -> String {
        switch error as? RemoteUnlockVaultError {
        case .biometryUnavailable: return "这台手机没有可用的面容 ID 或触控 ID"
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "\(text)（\(status)）"
        case nil: return error.localizedDescription
        }
    }
}

/// 真钥匙串实现：条目绑生物识别（`.biometryCurrentSet`），录入新指纹 / 面容后旧条目自动失效；仅本机、不同步。
@MainActor
final class KeychainRemoteUnlockStore: RemoteUnlockPasswordStore {
    private let service = "com.uozi.uTerm.remote.unlock"

    private func account(_ macID: UUID) -> String { macID.uuidString }

    func password(forMac macID: UUID, reason: String) async throws -> String? {
        let context = LAContext()
        context.localizedReason = reason
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(macID),
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            throw RemoteUnlockVaultError.keychain(status)
        default:
            throw RemoteUnlockVaultError.keychain(status)
        }
    }

    func save(_ password: String, forMac macID: UUID) throws {
        remove(forMac: macID)
        guard let data = password.data(using: .utf8) else { return }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error) else {
            throw RemoteUnlockVaultError.biometryUnavailable
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(macID),
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw RemoteUnlockVaultError.keychain(status) }
    }

    func remove(forMac macID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(macID),
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func hasPassword(forMac macID: UUID) -> Bool {
        // 只读属性、不读密码本身，不需要验证身份。不能用 `kSecUseAuthenticationUISkip`：它会直接跳过需要
        // 验证的条目，绑了 Face ID 的密码因此永远查不到。再给一个不许交互的上下文兜底，保证这里绝不弹 Face ID；
        // 这种情况下条目存在会回 `errSecInteractionNotAllowed`，同样算「存过」。
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(macID),
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}

/// 内存实现：测试与预览用，不碰钥匙串、不触发生物识别。
@MainActor
final class MemoryRemoteUnlockStore: RemoteUnlockPasswordStore {
    private var passwords: [UUID: String] = [:]
    /// 模拟 Face ID 失败：置非 nil 时 `password(forMac:)` 抛这个错。
    var readError: Error?

    func password(forMac macID: UUID, reason: String) async throws -> String? {
        if let readError { throw readError }
        return passwords[macID]
    }

    func save(_ password: String, forMac macID: UUID) throws { passwords[macID] = password }
    func remove(forMac macID: UUID) { passwords[macID] = nil }
    func hasPassword(forMac macID: UUID) -> Bool { passwords[macID] != nil }
}
