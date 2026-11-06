import Foundation

nonisolated enum SSHAuthError: Error, Equatable {
    case missingPassword
    case missingPrivateKey
    /// 读取钥匙串失败（钥匙串被锁、`errSecAuthFailed` 等），不同于「条目不存在」。
    /// 借此把「真实的钥匙串错误」与「无密钥」区分开，连接失败时能明确提示是钥匙串问题。
    case keychainAccessFailed(String)
}

extension SSHAuthError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .missingPassword:
            return "未找到该主机的密码。请在「编辑主机」里重新填写密码后重试。"
        case .missingPrivateKey:
            return "未找到该主机的私钥。请确认密钥已通过 iCloud 钥匙串同步到本机，或在「编辑主机」里重新选择 / 导入私钥。"
        case .keychainAccessFailed(let detail):
            return "钥匙串访问失败：\(detail)。请确认已登录 iCloud 并开启「钥匙串」，且 App 已获得钥匙串访问权限。"
        }
    }
}

/// 解析后的认证材料 —— 纯数据，不含 Citadel 类型，便于单测。
/// `SSHConnection` 据此构造实际的 Citadel `SSHAuthenticationMethod`。
nonisolated enum ResolvedAuth: Equatable, Sendable {
    case password(username: String, password: String)
    case privateKey(username: String, pem: String, passphrase: String?)
}

/// 由 `ServerProfile` 与从 `KeychainStore` 取出的密钥，计算出 `ResolvedAuth`。
///
/// `nonisolated`：纯函数式工具，无 UI 状态，无需 MainActor 隔离。
nonisolated enum SSHAuthResolver {
    /// 解析认证用到的 `ServerProfile` 字段快照。`@Model` 不是 `Sendable`，
    /// 拍成值以后钥匙串读取才能离开主线程（见 `resolveOffMain`）。
    struct Lookup: Sendable {
        let id: UUID
        let keyID: UUID?
        let authMethod: AuthMethod
        let username: String

        init(_ profile: ServerProfile) {
            id = profile.id
            keyID = profile.keyID
            authMethod = profile.authMethod
            username = profile.username
        }
    }

    static func resolve(
        profile: ServerProfile,
        password: String?,
        privateKey: String?,
        passphrase: String?
    ) throws -> ResolvedAuth {
        try resolve(Lookup(profile), password: password, privateKey: privateKey, passphrase: passphrase)
    }

    static func resolve(
        _ profile: Lookup,
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
        keychain: some KeychainReading
    ) throws -> ResolvedAuth {
        try resolve(Lookup(profile), keychain: keychain)
    }

    nonisolated static func resolve(
        _ profile: Lookup,
        keychain: some KeychainReading
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
            profile,
            password: try load(keychain, profileID: profile.id, kind: .password),
            privateKey: privateKey,
            passphrase: passphrase)
    }

    /// 主线程调用方用：字段快照在主线程拍好，钥匙串那 3~5 次（有跳板机再翻倍）
    /// `SecItemCopyMatching` IPC 放到并发线程池里做，不和连接中页的入场动画抢主线程。
    /// 跳板机解析失败按「没有跳板机认证」处理，与各调用点原来的 `try?` 同义。
    @concurrent static func resolveOffMain(
        _ profile: Lookup,
        jump: Lookup?
    ) async throws -> (auth: ResolvedAuth, jump: ResolvedAuth?) {
        let keychain = KeychainStore()
        let auth = try resolve(profile, keychain: keychain)
        let jumpAuth = jump.flatMap { try? resolve($0, keychain: keychain) }
        return (auth, jumpAuth)
    }

    /// 新建连接用：跟 `resolveOffMain` 的区别是跳板机的凭据缺了要报错，不能悄悄当作没有。
    /// 钥匙串读取在并发线程池里做；规则本身见同名同步版。
    @concurrent static func resolveForConnect(
        _ profile: Lookup,
        jump: Lookup?
    ) async throws -> (auth: ResolvedAuth, jump: ResolvedAuth?) {
        try resolveForConnect(profile, jump: jump, keychain: KeychainStore())
    }

    /// 由已保存主机新建连接时解析凭据的**唯一规则**：目标与跳板机都必须解析成功。
    /// 终端、SFTP、端口转发、CLI 控制通道、Agent / 并行执行都经这里（或上面的异步版），
    /// 不要在调用点各自再拼一遍 `resolve` + 跳板机。
    ///
    /// 同步版在调用线程读钥匙串：给本身就是同步、拿到结果才能往下走的调用点用
    /// （端口转发的会话屏障、CLI 的建连输入）；能 `await` 的调用点用异步版。
    static func resolveForConnect(
        _ profile: Lookup,
        jump: Lookup?,
        keychain: some KeychainReading
    ) throws -> (auth: ResolvedAuth, jump: ResolvedAuth?) {
        let auth = try resolve(profile, keychain: keychain)
        return (auth, try resolveJump(jump, keychain: keychain))
    }

    /// 便捷重载：直接从一台已保存主机解析（字段快照在调用线程拍）。
    static func resolveForConnect(
        profile: ServerProfile,
        keychain: some KeychainReading
    ) throws -> (auth: ResolvedAuth, jump: ResolvedAuth?) {
        try resolveForConnect(Lookup(profile), jump: profile.jumpHost.map(Lookup.init), keychain: keychain)
    }

    /// 跳板机凭据：没配跳板机返回 nil；配了就必须解析成功，缺了报错——
    /// 新建连接绝不能悄悄绕过跳板机直连。目标凭据另有来源的调用点（表单里「测试连接」
    /// 用的是尚未保存的输入）单独用它。
    static func resolveJump(
        _ jump: Lookup?,
        keychain: some KeychainReading
    ) throws -> ResolvedAuth? {
        try jump.map { try resolve($0, keychain: keychain) }
    }

    /// 读取一条钥匙串密钥：条目不存在返回 `nil`（沿用 `KeychainStore.load` 的语义），
    /// 其余任何错误（钥匙串被锁等）包成 `SSHAuthError.keychainAccessFailed` 上抛。
    private nonisolated static func load(
        _ keychain: some KeychainReading,
        profileID: UUID,
        kind: SecretKind
    ) throws -> String? {
        do {
            return try keychain.load(profileID: profileID, kind: kind)
        } catch {
            throw SSHAuthError.keychainAccessFailed(error.localizedDescription)
        }
    }
}
