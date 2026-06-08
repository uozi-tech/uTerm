import Foundation

nonisolated enum SSHAuthError: Error, Equatable {
    case missingPassword
    case missingPrivateKey
    /// 读取钥匙串失败（钥匙串被锁、`errSecAuthFailed` 等），不同于「条目不存在」。
    /// 借此把「真实的钥匙串错误」与「无密钥」区分开，连接失败时能明确提示是钥匙串问题。
    case keychainAccessFailed(String)
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
    ///
    /// 私钥认证时**优先**按 `profile.keyID`（密钥库条目）取私钥与口令；keyID 为 nil
    /// 或取不到时**回退**到按 `profile.id` 取 —— 兼容密钥库引入前直接存在 profile 名下
    /// 的旧私钥。密码始终按 `profile.id` 取。
    nonisolated static func resolve(
        profile: ServerProfile,
        keychain: KeychainStore
    ) throws -> ResolvedAuth {
        let privateKey: String?
        let passphrase: String?
        // keyID 指向密钥库条目：仅在该私钥**存在**时走密钥库；**取不到（条目不存在）**
        // 才回退到 profile.id 名下的旧私钥。但若钥匙串读取**抛错**（被锁 / errSecAuthFailed
        // 等），不能静默吞掉当作「无密钥」—— 那会让 SSH 误以为没配密钥而以泛化错误失败。
        // 故把真实错误包成 `keychainAccessFailed` 上抛，连接失败时能明确指向钥匙串问题。
        if let keyID = profile.keyID,
           let pk = try load(keychain, profileID: keyID, kind: .privateKey) {
            privateKey = pk
            passphrase = try load(keychain, profileID: keyID, kind: .passphrase)
        } else {
            privateKey = try load(keychain, profileID: profile.id, kind: .privateKey)
            passphrase = try load(keychain, profileID: profile.id, kind: .passphrase)
        }
        return try resolve(
            profile: profile,
            password: try load(keychain, profileID: profile.id, kind: .password),
            privateKey: privateKey,
            passphrase: passphrase)
    }

    /// 读取一条钥匙串密钥：条目不存在返回 `nil`（沿用 `KeychainStore.load` 的语义），
    /// 其余任何错误（钥匙串被锁等）包成 `SSHAuthError.keychainAccessFailed` 上抛。
    private nonisolated static func load(
        _ keychain: KeychainStore,
        profileID: UUID,
        kind: SecretKind
    ) throws -> String? {
        do {
            return try keychain.load(profileID: profileID, kind: kind)
        } catch {
            throw SSHAuthError.keychainAccessFailed("\(error)")
        }
    }
}
