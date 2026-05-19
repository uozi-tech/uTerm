import Foundation

enum SSHAuthError: Error, Equatable {
    case missingPassword
    case missingPrivateKey
}

/// 解析后的认证材料 —— 纯数据，不含 Citadel 类型，便于单测。
/// `SSHConnection` 据此构造实际的 Citadel `SSHAuthenticationMethod`。
enum ResolvedAuth: Equatable {
    case password(username: String, password: String)
    case privateKey(username: String, pem: String, passphrase: String?)
}

/// 由 `ServerProfile` 与从 `KeychainStore` 取出的密钥，计算出 `ResolvedAuth`。
enum SSHAuthResolver {
    static func resolve(
        profile: ServerProfile,
        password: String?,
        privateKey: String?,
        passphrase: String?
    ) throws -> ResolvedAuth {
        switch profile.authMethod {
        case .password:
            guard let password, !password.isEmpty else {
                throw SSHAuthError.missingPassword
            }
            return .password(username: profile.username, password: password)
        case .privateKey:
            guard let privateKey, !privateKey.isEmpty else {
                throw SSHAuthError.missingPrivateKey
            }
            return .privateKey(
                username: profile.username,
                pem: privateKey,
                passphrase: (passphrase?.isEmpty == false) ? passphrase : nil
            )
        }
    }
}
