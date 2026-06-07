import Foundation

/// 私钥导入失败原因。`Equatable` 只比较 case，不比较关联文本（便于测试）。
nonisolated enum PrivateKeyImportError: Error, LocalizedError, Equatable {
    case malformedPEM(reason: String)
    case unsupportedFormat(label: String)
    case dsaUnsupported
    case encryptedKeyNeedsPassphrase
    case incorrectPassphrase
    case unsupportedCipher(name: String)
    case unsupportedKDF(name: String)
    case malformedKey(reason: String)

    var errorDescription: String? {
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

    nonisolated static func == (lhs: PrivateKeyImportError, rhs: PrivateKeyImportError) -> Bool {
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
