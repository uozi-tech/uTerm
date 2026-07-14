import Foundation

/// 私钥导入失败原因。`Equatable` 只比较 case，不比较关联文本（便于测试）。
public nonisolated enum PrivateKeyImportError: Error, LocalizedError, Equatable {
    case malformedPEM(reason: String)
    case unsupportedFormat(label: String)
    case dsaUnsupported
    case encryptedKeyNeedsPassphrase
    case incorrectPassphrase
    case unsupportedCipher(name: String)
    case unsupportedKDF(name: String)
    case malformedKey(reason: String)

    public var errorDescription: String? {
        switch self {
        case .malformedPEM(let reason):
            return "私钥内容无法识别：\(reason)"
        case .unsupportedFormat(let label):
            return "不支持的私钥格式（\(label)）：仅支持 RSA / Ed25519 / ECDSA 私钥"
        case .dsaUnsupported:
            return "DSA 私钥不受支持，请改用 RSA / Ed25519 / ECDSA 密钥"
        case .encryptedKeyNeedsPassphrase:
            return "私钥已加密，请填写密钥口令"
        case .incorrectPassphrase:
            return "私钥口令错误，无法解密"
        case .unsupportedCipher(let name):
            return "不支持的私钥加密算法：\(name)"
        case .unsupportedKDF(let name):
            return "不支持的私钥密钥派生算法：\(name)"
        case .malformedKey(let reason):
            return "私钥结构损坏：\(reason)"
        }
    }

    public var failureReason: String? {
        switch self {
        case .malformedPEM:
            return "文件不是可识别的 PEM 私钥，或 BEGIN/END 标记不完整。"
        case .unsupportedFormat(let label):
            return "检测到 \(label)，当前只支持 RSA / Ed25519 / ECDSA 私钥。"
        case .dsaUnsupported:
            return "DSA 已不再作为受支持的 SSH 私钥算法。"
        case .encryptedKeyNeedsPassphrase:
            return "该私钥受口令保护，导入前需要先解密。"
        case .incorrectPassphrase:
            return "输入的私钥口令无法解密此文件。"
        case .unsupportedCipher(let name):
            return "加密算法 \(name) 当前未实现。"
        case .unsupportedKDF(let name):
            return "密钥派生算法 \(name) 当前未实现。"
        case .malformedKey:
            return "文件结构损坏，或内容与声明的私钥算法不匹配。"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .malformedPEM:
            return "请选择私钥文件（如 id_ed25519、id_rsa），不要选择 .pub 公钥；确认文件以 -----BEGIN ... PRIVATE KEY----- 开头，且一次只导入一把私钥。"
        case .unsupportedFormat:
            return "如果这是公钥或证书，请改选对应私钥；如为 PuTTY .ppk，请先转换为 OpenSSH/PEM 格式。"
        case .dsaUnsupported:
            return "请重新生成 Ed25519、RSA 或 ECDSA 密钥，并在服务器上换用新公钥。"
        case .encryptedKeyNeedsPassphrase:
            return "请输入创建该私钥时设置的 passphrase；这不是服务器登录密码。"
        case .incorrectPassphrase:
            return "请检查大小写和输入法，或在终端用 ssh-keygen -y -f <key> 验证口令。"
        case .unsupportedCipher:
            return "请用 ssh-keygen 重新导出为常见 OpenSSH/PEM 格式后再导入。"
        case .unsupportedKDF:
            return "请改用 PBES2/PBKDF2 等常见 PEM 加密格式，或重新导出为 OpenSSH 私钥后再导入。"
        case .malformedKey:
            return "请确认文件未被截断、复制时没有丢行；也不要粘贴 .pub 公钥内容。"
        }
    }

    public nonisolated static func == (lhs: PrivateKeyImportError, rhs: PrivateKeyImportError) -> Bool {
        switch (lhs, rhs) {
        case (.malformedPEM, .malformedPEM), (.unsupportedFormat, .unsupportedFormat),
             (.dsaUnsupported, .dsaUnsupported),
             (.encryptedKeyNeedsPassphrase, .encryptedKeyNeedsPassphrase),
             (.incorrectPassphrase, .incorrectPassphrase),
             (.unsupportedCipher, .unsupportedCipher),
             (.unsupportedKDF, .unsupportedKDF), (.malformedKey, .malformedKey):
            return true
        default:
            return false
        }
    }
}
