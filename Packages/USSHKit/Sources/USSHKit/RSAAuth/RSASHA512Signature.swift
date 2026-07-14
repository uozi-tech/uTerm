import Foundation
import NIOCore
import NIOSSH

/// `rsa-sha2-512` 签名的 NIOSSH 表示。线格式：签名字节按 SSH `string` 写入
/// （与 Citadel `Insecure.RSA.Signature` 一致 —— `signaturePrefix` 由 NIOSSH 外层加）。
nonisolated struct RSASHA512Signature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "rsa-sha2-512"

    let rawRepresentation: Data

    init(rawRepresentation: Data) {
        self.rawRepresentation = rawRepresentation
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        let bytes = [UInt8](rawRepresentation)
        var written = buffer.writeInteger(UInt32(bytes.count))   // SSH string 长度前缀
        written += buffer.writeBytes(bytes)
        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA512Signature {
        guard let length: UInt32 = buffer.readInteger(),
              let bytes = buffer.readBytes(length: Int(length)) else {
            throw PrivateKeyImportError.malformedKey(reason: "RSA 签名线格式损坏")
        }
        return RSASHA512Signature(rawRepresentation: Data(bytes))
    }
}
