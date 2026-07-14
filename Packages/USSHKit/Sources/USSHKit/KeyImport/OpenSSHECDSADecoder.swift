import Foundation
import Crypto

/// 解析 OpenSSH 容器中的 ECDSA 私钥（仅未加密）。
nonisolated enum OpenSSHECDSADecoder {

    static func decode(openSSHText: String) throws -> ParsedPrivateKey {
        let der = try extractBase64Body(openSSHText)

        // AUTH_MAGIC "openssh-key-v1\0"（16 字节，含 NUL）
        let magic = Array("openssh-key-v1\u{0}".utf8)
        guard der.count >= magic.count, Array(der.prefix(magic.count)) == magic else {
            throw PrivateKeyImportError.malformedKey(reason: "OpenSSH：缺少 magic")
        }
        var reader = SSHWireReader(Array(der.dropFirst(magic.count)))

        let cipherName = String(decoding: try reader.readString(), as: UTF8.self)
        guard cipherName == "none" else {
            throw PrivateKeyImportError.unsupportedFormat(
                label: "加密的 OpenSSH ECDSA（\(cipherName)）")
        }
        _ = try reader.readString()                    // kdfname
        _ = try reader.readString()                    // kdfoptions
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw PrivateKeyImportError.malformedKey(reason: "OpenSSH：密钥数量非 1")
        }
        _ = try reader.readString()                    // 公钥段（跳过）

        // 私钥段（cipher=none 时即明文）
        var priv = SSHWireReader(try reader.readString())
        let check1 = try priv.readUInt32()
        let check2 = try priv.readUInt32()
        guard check1 == check2 else {
            throw PrivateKeyImportError.malformedKey(reason: "OpenSSH：checkint 不一致")
        }
        let keyType = String(decoding: try priv.readString(), as: UTF8.self)
        // ecdsa-sha2-nistp256 等：curveName, Q(point), d(scalar mpint)
        guard keyType.hasPrefix("ecdsa-sha2-nistp") else {
            throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
        }
        _ = try priv.readString()                      // curve name
        _ = try priv.readString()                      // Q（公钥点）
        let scalar = try priv.readMPInt()              // d（私钥标量）

        let curveOID: String
        switch keyType {
        case "ecdsa-sha2-nistp256": curveOID = DERKeyDecoder.OID.p256
        case "ecdsa-sha2-nistp384": curveOID = DERKeyDecoder.OID.p384
        case "ecdsa-sha2-nistp521": curveOID = DERKeyDecoder.OID.p521
        default:
            throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
        }
        return try DERKeyDecoder.makeECKey(curveOID: curveOID, scalar: scalar)
    }

    /// 取 BEGIN/END 之间的 base64 并解码。
    private static func extractBase64Body(_ text: String) throws -> [UInt8] {
        let doc = try PEMDocument.parse(text)
        guard doc.label == "OPENSSH PRIVATE KEY" else {
            throw PrivateKeyImportError.malformedKey(reason: "非 OpenSSH 私钥")
        }
        return doc.der
    }
}
