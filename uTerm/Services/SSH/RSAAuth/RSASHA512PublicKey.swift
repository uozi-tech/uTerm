import Foundation
import NIOCore
import NIOSSH

/// `rsa-sha2-512` 公钥 blob 的 NIOSSH 表示。blob 体 = `mpint e` + `mpint n`。
nonisolated struct RSASHA512PublicKey: NIOSSHPublicKeyProtocol {
    /// 该 fork 的 userauth 把"公钥算法名"字段取自 publicKeyPrefix，且公钥 blob 内部
    /// 类型也用它 —— 二者绑定同一个值，无法分开。因此这里必须是 "rsa-sha2-512"
    /// （而非 RFC 8332 严格意义上的 "ssh-rsa"），否则服务器收到的算法名是 ssh-rsa(SHA-1)
    /// 会被现代 OpenSSH 拒绝。现代 OpenSSH 的 userauth 路径接受 rsa-sha2-512 作为
    /// blob 类型标识。
    static let publicKeyPrefix = "rsa-sha2-512"

    let modulus: [UInt8]
    let publicExponent: [UInt8]

    init(modulus: [UInt8], publicExponent: [UInt8]) {
        self.modulus = modulus
        self.publicExponent = publicExponent
    }

    var rawRepresentation: Data {
        var w = SSHWireWriter()
        w.writeMPInt(publicExponent)
        w.writeMPInt(modulus)
        return Data(w.bytes)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        var w = SSHWireWriter()
        w.writeMPInt(publicExponent)
        w.writeMPInt(modulus)
        return buffer.writeBytes(w.bytes)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let sig = signature as? RSASHA512Signature else { return false }
        return RSASHA512Signer.isValidSignature(
            [UInt8](sig.rawRepresentation), for: data,
            modulus: modulus, publicExponent: publicExponent)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA512PublicKey {
        var reader = SSHWireReader([UInt8](buffer.readableBytesView))
        let e = try reader.readMPInt()
        let n = try reader.readMPInt()
        buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
        return RSASHA512PublicKey(modulus: n, publicExponent: e)
    }
}
