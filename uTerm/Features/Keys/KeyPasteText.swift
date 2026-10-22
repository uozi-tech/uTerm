import Foundation

/// 「粘贴私钥内容」导入前的文本预处理。纯函数，与视图解耦便于单测。
///
/// 粘贴来的文本比文件脏：网页 / 聊天工具会带 CRLF、行首缩进，甚至把整段 PEM
/// 压成一行（换行变空格）。解析器只容忍首尾空白与 CRLF，这里先把这些情形规整回
/// 标准多行 PEM，再交给 `SSHPrivateKeyParser`。
nonisolated enum KeyPasteText {

    /// 规整成解析器 / 钥匙串存储用的标准形态：LF 换行、逐行去首尾空白、
    /// 单行 PEM 重新折行、末尾恰好一个换行。
    static func normalize(_ raw: String) -> String {
        var unified = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // 富文本来源（文档、聊天、开了「智能破折号」的输入框）会把 `-----` 换成 — / –，
        // 解析器就找不到 BEGIN / END 标记了。base64 正文里没有破折号，只修标记两侧。
        unified = unified.replacingOccurrences(
            of: "[-\u{2013}\u{2014}]+(BEGIN|END) ([A-Z0-9 ]+?)[-\u{2013}\u{2014}]+",
            with: "-----$1 $2-----",
            options: .regularExpression)
        let lines = unified
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let reflowed = reflowSingleLinePEM(text) { text = reflowed }
        return text.isEmpty ? "" : text + "\n"
    }

    /// 误贴了公钥 / OpenSSH 证书（`.pub`、`-cert.pub` 的单行格式）。
    static func isPublicKeyLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("-----BEGIN ") else { return false }
        return publicKeyPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// 文本是否是加密私钥（需要口令）。用来提前露出口令框，免得用户先撞一次错。
    /// 判不出时返回 false——最终以解析器的 `encryptedKeyNeedsPassphrase` 为准。
    static func looksEncrypted(_ text: String) -> Bool {
        if text.contains("Proc-Type: 4,ENCRYPTED") || text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") {
            return true
        }
        guard let body = pemBody(of: text, label: "OPENSSH PRIVATE KEY"),
              let data = Data(base64Encoded: body) else { return false }
        return openSSHCipherName(data).map { $0 != "none" } ?? false
    }

    // MARK: - 私有

    private static let publicKeyPrefixes = [
        "ssh-rsa ", "ssh-ed25519 ", "ssh-dss ", "ecdsa-sha2-", "sk-ssh-", "sk-ecdsa-",
        "ssh-rsa-cert-", "ssh-ed25519-cert-",
    ]

    /// 整段 PEM 挤在一行时（`-----BEGIN X----- AAAA BBBB -----END X-----`）重新折行。
    /// 带 `Proc-Type` 等头部的传统加密 PEM 压成一行后头部与正文已无法可靠切分，原样放行。
    private static func reflowSingleLinePEM(_ text: String) -> String? {
        guard !text.contains("\n"),
              let label = firstLabel(in: text),
              !text.contains(":"),
              let body = pemBody(of: text, label: label) else { return nil }
        let width = label == "OPENSSH PRIVATE KEY" ? 70 : 64
        var wrapped: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let end = body.index(index, offsetBy: width, limitedBy: body.endIndex) ?? body.endIndex
            wrapped.append(String(body[index..<end]))
            index = end
        }
        return (["-----BEGIN \(label)-----"] + wrapped + ["-----END \(label)-----"]).joined(separator: "\n")
    }

    private static func firstLabel(in text: String) -> String? {
        guard let begin = text.range(of: "-----BEGIN ") else { return nil }
        let rest = text[begin.upperBound...]
        guard let end = rest.range(of: "-----") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    /// BEGIN / END 之间去掉全部空白后的 base64 正文。
    private static func pemBody(of text: String, label: String) -> String? {
        guard let begin = text.range(of: "-----BEGIN \(label)-----"),
              let end = text.range(of: "-----END \(label)-----", range: begin.upperBound..<text.endIndex)
        else { return nil }
        return text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
    }

    /// `openssh-key-v1\0` 魔数之后紧跟 `uint32 长度 + 加密算法名`。
    private static func openSSHCipherName(_ data: Data) -> String? {
        let magic = Data("openssh-key-v1\0".utf8)
        let bytes = [UInt8](data)
        guard bytes.count >= magic.count + 4, Data(bytes[0..<magic.count]) == magic else { return nil }
        let lengthStart = magic.count
        let length = bytes[lengthStart..<lengthStart + 4].reduce(0) { ($0 << 8) | Int($1) }
        let nameStart = lengthStart + 4
        guard length > 0, nameStart + length <= bytes.count else { return nil }
        return String(bytes: bytes[nameStart..<nameStart + length], encoding: .utf8)
    }
}
