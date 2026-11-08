import Foundation
import USSHKit

/// 「导入私钥」两端共用的核心：校验 → 后台解析 → 查重 → 写钥匙串 → 交回未插入的 `SSHKey`。
/// macOS `KeyImportView` 与 iOS `KeyImportSheet` 只画界面、管来源（粘贴 / 文件 / 拖放），
/// 判定与落钥匙串只在这一处。
///
/// 解析在后台线程跑（带口令的 OpenSSH 容器要跑 bcrypt_pbkdf，可达数百毫秒）。
enum KeyImport {

    /// 导入失败的几类，按界面要做的反应分：`needsPassphrase` 要露出口令框，其余只显示文案。
    nonisolated enum Failure: Error {
        /// 误贴了公钥（`.pub`）。
        case publicKeyPasted
        /// 私钥已加密而口令为空（或解析器明确要求口令）。
        case needsPassphrase
        /// 密钥库里已有同指纹的密钥。
        case duplicate(existingName: String)
        /// 其余失败，已是给用户看的文案。
        case failed(String)

        var message: String {
            switch self {
            case .publicKeyPasted:
                return "这是公钥（.pub），不是私钥。粘贴 -----BEGIN … PRIVATE KEY----- 开头的私钥内容。"
            case .needsPassphrase:
                return "此私钥已加密，填写口令后再导入。"
            case .duplicate(let existingName):
                return "密钥库里已有这把密钥：「\(existingName)」。"
            case .failed(let message):
                return message
            }
        }
    }

    /// 解析 `normalizedText`（已经过 `KeyPasteText.normalize`），成功后私钥写进钥匙串，
    /// 返回**未插入**模型上下文的 `SSHKey`——由调用方 insert + save。
    static func run(
        normalizedText text: String,
        name: String,
        passphrase: String,
        existingKeys: [SSHKey],
        keyStore: KeyStore = KeyStore()
    ) async -> Result<SSHKey, Failure> {
        guard !text.isEmpty else { return .failure(.failed("先粘贴或读取私钥内容")) }
        if KeyPasteText.isPublicKeyLine(text) { return .failure(.publicKeyPasted) }
        let pass: String? = passphrase.isEmpty ? nil : passphrase

        let material: KeyImportInspector.Material
        do {
            material = try await Task.detached(priority: .userInitiated) {
                try inspect(text: text, passphrase: pass)
            }.value
        } catch PrivateKeyImportError.encryptedKeyNeedsPassphrase {
            return .failure(.needsPassphrase)
        } catch PrivateKeyImportError.incorrectPassphrase where pass == nil {
            return .failure(.needsPassphrase)
        } catch {
            return .failure(.failed(KeyImportErrorMessage.message(
                for: error,
                fallback: pass == nil ? "无法识别该私钥" : "口令错误或私钥无法解析")))
        }

        if let dup = existingKeys.first(where: { $0.fingerprint == material.fingerprint }) {
            return .failure(.duplicate(existingName: dup.name))
        }
        let key = SSHKey()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        key.name = trimmedName.isEmpty ? "imported-key" : trimmedName
        key.type = material.type
        key.bits = material.bits
        key.fingerprint = material.fingerprint
        key.publicKey = material.publicKey
        key.hasPassphrase = pass != nil
        do {
            try keyStore.save(keyID: key.id, privateKey: text, passphrase: pass)
        } catch {
            return .failure(.failed(KeyImportErrorMessage.message(for: error, fallback: "无法写入钥匙串")))
        }
        return .success(key)
    }

    /// 读私钥文件失败时给用户看的文案。
    static func fileReadMessage(fileName: String, error: Error) -> String {
        KeyImportErrorMessage.message(
            for: NSError(domain: "uTerm.keys", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无法读取私钥文件",
                NSLocalizedFailureReasonErrorKey: "读取 \(fileName) 时失败：\(FriendlyError.describe(error))",
                NSLocalizedRecoverySuggestionErrorKey: "确认文件仍存在、当前用户有读取权限，并且它是文本格式的 SSH 私钥。",
            ]),
            fallback: "无法读取私钥文件"
        )
    }

    /// 解析 + 生成公钥 / 指纹元数据。后台线程调用。
    private nonisolated static func inspect(text: String, passphrase: String?) throws -> KeyImportInspector.Material {
        let parsed = try SSHPrivateKeyParser.parse(pem: text, passphrase: passphrase)
        do {
            return try KeyImportInspector.inspect(rawText: text, parsed: parsed, comment: "")
        } catch {
            throw NSError(domain: "uTerm.keys", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法加入密钥库",
                NSLocalizedFailureReasonErrorKey: "私钥解析成功，但无法生成密钥库所需的公钥或指纹元数据。",
                NSLocalizedRecoverySuggestionErrorKey: "确认密钥算法为 RSA、Ed25519 或 ECDSA；如果仍失败，可用 ssh-keygen -y -f <key> 检查该私钥。",
            ])
        }
    }
}
