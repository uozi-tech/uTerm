import Foundation

/// 把 RSA 私钥分量编码为 OpenSSH 私钥文件字符串（cipher="none"）。
nonisolated enum OpenSSHRSAEncoder {

    private static let authMagic: [UInt8] = Array("openssh-key-v1\u{0}".utf8)

    /// 各参数为无符号大端幅值（可含前导零，内部会按 mpint 规范化）。
    static func encode(n: [UInt8], e: [UInt8], d: [UInt8],
                       iqmp: [UInt8], p: [UInt8], q: [UInt8]) -> String {
        // 公钥段：ssh-rsa, e, n
        var pub = SSHWireWriter()
        pub.writeString("ssh-rsa")
        pub.writeMPInt(e)
        pub.writeMPInt(n)

        // 私钥段：check, check, ssh-rsa, n, e, d, iqmp, p, q, comment, padding
        var priv = SSHWireWriter()
        let check: UInt32 = 0x756D5400            // 任意校验值，两份相同即可
        priv.writeUInt32(check)
        priv.writeUInt32(check)
        priv.writeString("ssh-rsa")
        priv.writeMPInt(n)
        priv.writeMPInt(e)
        priv.writeMPInt(d)
        priv.writeMPInt(iqmp)
        priv.writeMPInt(p)
        priv.writeMPInt(q)
        priv.writeString("uterm")                  // comment
        // 填充到 8 字节块（cipher "none" 的块大小）。
        var pad: UInt8 = 1
        while priv.bytes.count % 8 != 0 {
            priv.writeRawBytes([pad]); pad &+= 1
        }

        // 顶层容器
        var top = SSHWireWriter()
        top.writeRawBytes(authMagic)
        top.writeString("none")                    // ciphername
        top.writeString("none")                    // kdfname
        top.writeString([])                        // kdfoptions（空）
        top.writeUInt32(1)                         // number of keys
        top.writeString(pub.bytes)
        top.writeString(priv.bytes)

        let base64 = Data(top.bytes).base64EncodedString()
        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var idx = base64.startIndex
        while idx < base64.endIndex {
            let end = base64.index(idx, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[idx..<end]))
            idx = end
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        return lines.joined(separator: "\n") + "\n"
    }
}
