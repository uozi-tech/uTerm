import Foundation
import SwiftASN1
import Crypto

/// 解析明文 DER 私钥为 `ParsedPrivateKey`。
/// 用 SwiftASN1 的 `DER.parse` 得到节点树后手动遍历已知结构。
nonisolated enum DERKeyDecoder {

    // MARK: - OID 常量（点分字符串）

    enum OID {
        static let rsaEncryption  = "1.2.840.113549.1.1.1"
        static let ecPublicKey    = "1.2.840.10045.2.1"
        static let ed25519        = "1.3.101.112"
        static let dsa            = "1.2.840.10040.4.1"
        static let p256           = "1.2.840.10045.3.1.7"
        static let p384           = "1.3.132.0.34"
        static let p521           = "1.3.132.0.35"
    }

    // MARK: - 节点遍历助手

    /// 取构造型节点（SEQUENCE 等）的子节点数组。
    static func children(_ node: ASN1Node) throws -> [ASN1Node] {
        guard case .constructed(let collection) = node.content else {
            throw PrivateKeyImportError.malformedKey(reason: "DER：期望构造型节点")
        }
        return Array(collection)
    }

    /// 取原始型节点（INTEGER / OCTET STRING 等）的内容字节。
    static func primitiveBytes(_ node: ASN1Node) throws -> [UInt8] {
        guard case .primitive(let bytes) = node.content else {
            throw PrivateKeyImportError.malformedKey(reason: "DER：期望原始型节点")
        }
        return Array(bytes)
    }

    /// 取 INTEGER 节点的无符号大端幅值（去掉 DER 符号 0x00）。
    static func integerMagnitude(_ node: ASN1Node) throws -> [UInt8] {
        var bytes = try primitiveBytes(node)
        while bytes.count > 1, bytes.first == 0x00 { bytes.removeFirst() }
        return bytes
    }

    /// 把 OBJECT IDENTIFIER 节点解析为点分字符串。
    static func oidString(_ node: ASN1Node) throws -> String {
        do {
            let oid = try ASN1ObjectIdentifier(derEncoded: node, withIdentifier: .objectIdentifier)
            return oid.description
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: "DER：OID 解析失败")
        }
    }

    /// 解析顶层 DER 字节为节点。
    static func parse(_ der: [UInt8]) throws -> ASN1Node {
        do {
            return try DER.parse(der)
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: "DER 解析失败")
        }
    }
}

nonisolated extension DERKeyDecoder {

    /// 解析明文 DER。`label` 为 PEM 信封标签（决定结构）。
    static func decode(der: [UInt8], label: String) throws -> ParsedPrivateKey {
        switch label {
        case "RSA PRIVATE KEY":
            return try decodePKCS1RSA(der)
        case "EC PRIVATE KEY":
            return try decodeSEC1EC(der)
        case "PRIVATE KEY":
            return try decodePKCS8(der)
        case "DSA PRIVATE KEY":
            throw PrivateKeyImportError.dsaUnsupported
        default:
            throw PrivateKeyImportError.unsupportedFormat(label: label)
        }
    }

    /// SEC1 ECPrivateKey ::= SEQUENCE {
    ///   version INTEGER, privateKey OCTET STRING,
    ///   parameters [0] EXPLICIT OID OPTIONAL, publicKey [1] EXPLICIT BIT STRING OPTIONAL }
    /// `curveOIDOverride` 用于 PKCS#8 包裹时曲线在外层 AlgorithmIdentifier 的情形。
    static func decodeSEC1EC(_ der: [UInt8], curveOIDOverride: String? = nil) throws -> ParsedPrivateKey {
        let root = try parse(der)
        let fields = try children(root)
        guard fields.count >= 2 else {
            throw PrivateKeyImportError.malformedKey(reason: "SEC1 EC：字段不足")
        }
        let scalar = try primitiveBytes(fields[1])      // privateKey OCTET STRING

        // 曲线 OID：优先用外层覆盖；否则找 [0] EXPLICIT 上下文标签里的 OID。
        var curveOID = curveOIDOverride
        if curveOID == nil {
            for node in fields.dropFirst(2) {
                if case .constructed(let inner) = node.content,
                   let oidNode = Array(inner).first,
                   let parsed = try? oidString(oidNode) {
                    curveOID = parsed
                    break
                }
            }
        }
        // Fallback: infer curve from scalar length for explicit-parameter keys
        // (explicit params embed full curve spec, no named OID in [0]).
        if curveOID == nil {
            switch scalar.count {
            case 32: curveOID = OID.p256
            case 48: curveOID = OID.p384
            case 66: curveOID = OID.p521
            default: break
            }
        }
        guard let oid = curveOID else {
            throw PrivateKeyImportError.malformedKey(reason: "SEC1 EC：缺少曲线信息")
        }
        return try makeECKey(curveOID: oid, scalar: scalar)
    }

    /// 按曲线 OID 把原始标量左补零到字段宽度后构造 swift-crypto 密钥。
    static func makeECKey(curveOID: String, scalar: [UInt8]) throws -> ParsedPrivateKey {
        func padded(_ bytes: [UInt8], to width: Int) throws -> [UInt8] {
            var s = bytes
            while s.count > width, s.first == 0x00 { s.removeFirst() }
            guard s.count <= width else {
                throw PrivateKeyImportError.malformedKey(reason: "EC 标量超长")
            }
            return Array(repeating: 0, count: width - s.count) + s
        }
        do {
            switch curveOID {
            case OID.p256:
                return .p256(try P256.Signing.PrivateKey(
                    rawRepresentation: try padded(scalar, to: 32)))
            case OID.p384:
                return .p384(try P384.Signing.PrivateKey(
                    rawRepresentation: try padded(scalar, to: 48)))
            case OID.p521:
                return .p521(try P521.Signing.PrivateKey(
                    rawRepresentation: try padded(scalar, to: 66)))
            default:
                throw PrivateKeyImportError.unsupportedFormat(label: "EC 曲线 \(curveOID)")
            }
        } catch let e as PrivateKeyImportError {
            throw e
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: "EC 私钥构造失败")
        }
    }

    /// PKCS#8 PrivateKeyInfo ::= SEQUENCE {
    ///   version INTEGER,
    ///   privateKeyAlgorithm AlgorithmIdentifier,   -- SEQUENCE { OID, params OPTIONAL }
    ///   privateKey OCTET STRING }
    static func decodePKCS8(_ der: [UInt8]) throws -> ParsedPrivateKey {
        let root = try parse(der)
        let fields = try children(root)
        guard fields.count >= 3 else {
            throw PrivateKeyImportError.malformedKey(reason: "PKCS#8：字段不足")
        }
        let algFields = try children(fields[1])
        guard let algOIDNode = algFields.first else {
            throw PrivateKeyImportError.malformedKey(reason: "PKCS#8：缺少算法标识")
        }
        let algOID = try oidString(algOIDNode)
        let inner = try primitiveBytes(fields[2])      // privateKey OCTET STRING 内容

        switch algOID {
        case OID.rsaEncryption:
            return try decodePKCS1RSA(inner)            // 内层即 PKCS#1
        case OID.dsa:
            throw PrivateKeyImportError.dsaUnsupported
        case OID.ed25519:
            // inner 本身是一个 DER OCTET STRING，再包 32 字节种子。
            let seedNode = try parse(inner)
            let seed = try primitiveBytes(seedNode)
            guard seed.count == 32 else {
                throw PrivateKeyImportError.malformedKey(reason: "Ed25519 种子长度非 32")
            }
            do {
                return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
            } catch {
                throw PrivateKeyImportError.malformedKey(reason: "Ed25519 私钥构造失败")
            }
        case OID.ecPublicKey:
            // algFields[1]（EC 参数）可能是命名曲线 OID（primitive 节点），
            // 也可能是显式 ECParameters SEQUENCE（constructed 节点）。
            // 仅对 primitive 节点尝试解析为 OID；显式参数时留空，
            // 由 decodeSEC1EC 依据内层 SEC1 标量长度推断曲线。
            var curveOID: String? = nil
            if algFields.count >= 2, case .primitive = algFields[1].content {
                curveOID = try? oidString(algFields[1])
            }
            return try decodeSEC1EC(inner, curveOIDOverride: curveOID)
        default:
            throw PrivateKeyImportError.unsupportedFormat(label: "算法 OID \(algOID)")
        }
    }

    /// PKCS#1 RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }
    static func decodePKCS1RSA(_ der: [UInt8]) throws -> ParsedPrivateKey {
        return .rsa(try RSAKeyComponents.fromPKCS1DER(der))
    }
}
