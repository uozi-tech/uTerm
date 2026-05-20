import Foundation

/// 解析后的 PEM 信封（纯解析，无密码学）。
nonisolated struct PEMDocument {
    /// BEGIN/END 之间的标签，如 "RSA PRIVATE KEY"。
    let label: String
    /// RFC 1421 头（如 Proc-Type、DEK-Info）。无则为空。
    let headers: [String: String]
    /// base64 正文解码后的 DER 字节。
    let der: [UInt8]

    static func parse(_ text: String) throws -> PEMDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let beginRange = normalized.range(of: "-----BEGIN ") else {
            throw PrivateKeyImportError.malformedPEM(reason: "未找到 -----BEGIN ----- 标记")
        }
        let afterBegin = normalized[beginRange.upperBound...]
        guard let labelEnd = afterBegin.range(of: "-----") else {
            throw PrivateKeyImportError.malformedPEM(reason: "BEGIN 行格式错误")
        }
        let label = String(afterBegin[..<labelEnd.lowerBound])
        guard let endRange = afterBegin.range(of: "-----END \(label)-----") else {
            throw PrivateKeyImportError.malformedPEM(reason: "未找到匹配的 -----END \(label)----- 标记")
        }
        let body = afterBegin[labelEnd.upperBound..<endRange.lowerBound]

        var headers: [String: String] = [:]
        var base64Lines: [String] = []
        var inHeaders = true
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // A blank line ends the header block only if we've already seen headers;
                // otherwise it's just the leading newline after "-----" and we skip it.
                if !headers.isEmpty { inHeaders = false }
                continue
            }
            if inHeaders, let colon = line.firstIndex(of: ":"),
               line.range(of: "[A-Za-z-]+:", options: .regularExpression)?.lowerBound == line.startIndex {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            } else {
                inHeaders = false
                base64Lines.append(line)
            }
        }

        let base64 = base64Lines.joined()
        guard !base64.isEmpty, let data = Data(base64Encoded: base64) else {
            throw PrivateKeyImportError.malformedPEM(reason: "base64 正文无法解码")
        }
        return PEMDocument(label: label, headers: headers, der: [UInt8](data))
    }
}
