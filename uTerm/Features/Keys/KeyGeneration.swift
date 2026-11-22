import Foundation
import USSHKit

/// 「生成新密钥」两端共用的核心：后台生成 → 写钥匙串 → 交回未插入的 `SSHKey`。
/// macOS `KeyGeneratorView` 与 iOS `KeyGenSheet` 只画界面、挑类型，生成与落钥匙串只在这一处。
///
/// 生成的密钥**不带口令**——私钥明文只进钥匙串（系统加密 + iCloud Keychain e2e）。
/// 生成在后台线程跑（RSA-4096 要一到三秒）。
enum KeyGeneration {

    nonisolated enum Failure: Error, Equatable {
        /// 调用方的任务在生成期间被取消（例如抽屉被下滑关掉）：什么都没写，界面静默收尾即可。
        case cancelled
        /// 其余失败，已是给用户看的文案。
        case failed(String)
    }

    /// 生成一把 `kind` 类型的密钥，成功后私钥写进钥匙串，返回**未插入**模型上下文的 `SSHKey`——
    /// 由调用方 insert + save。`bits` 只对 RSA 生效；其余类型的位数由类型决定。
    ///
    /// 生成期间任务被取消就返回 `.cancelled`，不写钥匙串：否则「取消了却多了一把钥匙」。
    static func run(
        kind: SSHKeyKind,
        bits: Int,
        name: String,
        comment: String,
        keyStore: KeyStore = KeyStore()
    ) async -> Result<SSHKey, Failure> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.failed(String(localized: "名称不能为空"))) }
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)

        let generated: SSHKeyGenerator.GeneratedKey
        do {
            generated = try await Task.detached(priority: .userInitiated) {
                try generate(kind: kind, bits: bits, comment: trimmedComment)
            }.value
        } catch {
            return .failure(.failed(message(for: error)))
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }

        let key = SSHKey()
        key.name = trimmedName
        key.type = kind
        key.bits = keyBits(kind: kind, rsaBits: bits)
        key.comment = trimmedComment
        key.fingerprint = generated.fingerprint
        key.publicKey = generated.publicKey
        key.hasPassphrase = false
        // 先写钥匙串、成功了才交给调用方插入：反过来的话钥匙串写失败时，已插入的空私钥
        // 记录会被下一次任意 save 一并落盘。
        do {
            try keyStore.save(keyID: key.id, privateKey: generated.privateKeyText, passphrase: nil)
        } catch {
            return .failure(.failed(message(for: error)))
        }
        return .success(key)
    }

    /// 入库记录的位数：RSA 用所选位数，其余由类型决定。
    nonisolated static func keyBits(kind: SSHKeyKind, rsaBits: Int) -> Int {
        switch kind {
        case .ed25519: 256
        case .rsa: rsaBits
        case .ecdsaP256: 256
        case .ecdsaP384: 384
        case .ecdsaP521: 521
        }
    }

    /// 给用户看的失败文案：优先取 `LocalizedError.errorDescription`。
    nonisolated static func message(for error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return String(localized: "生成失败：\(detail)")
    }

    private nonisolated static func generate(
        kind: SSHKeyKind,
        bits: Int,
        comment: String
    ) throws -> SSHKeyGenerator.GeneratedKey {
        switch kind {
        case .ed25519:
            return SSHKeyGenerator.generateEd25519(comment: comment)
        case .rsa:
            return try SSHKeyGenerator.generateRSA(bits: bits, comment: comment)
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            return try SSHKeyGenerator.generateECDSA(type: kind, comment: comment)
        }
    }
}
