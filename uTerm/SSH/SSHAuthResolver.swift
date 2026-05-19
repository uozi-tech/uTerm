import Foundation

nonisolated enum SSHAuthError: Error, Equatable {
    case missingPassword
    case missingPrivateKey
}

/// 解析后的认证材料 —— 纯数据，不含 Citadel 类型，便于单测。
/// `SSHConnection` 据此构造实际的 Citadel `SSHAuthenticationMethod`。
nonisolated enum ResolvedAuth: Equatable {
    case password(username: String, password: String)
    case privateKey(username: String, pem: String, passphrase: String?)
}

/// 由 `ServerProfile` 与从 `KeychainStore` 取出的密钥，计算出 `ResolvedAuth`。
///
/// `nonisolated`：纯函数式工具，无 UI 状态，无需 MainActor 隔离。
nonisolated enum SSHAuthResolver {
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

    /// 便捷重载：自行从 `KeychainStore` 取出密码 / 私钥 / 口令，再解析。
    /// `PaneModel` 与 `FileBrowserModel` 共用，省去各自一份相同的取钥串逻辑。
    nonisolated static func resolve(
        profile: ServerProfile,
        keychain: KeychainStore
    ) throws -> ResolvedAuth {
        try resolve(
            profile: profile,
            password: try? keychain.load(profileID: profile.id, kind: .password),
            privateKey: try? keychain.load(profileID: profile.id, kind: .privateKey),
            passphrase: try? keychain.load(profileID: profile.id, kind: .passphrase))
    }
}
