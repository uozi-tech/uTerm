import Foundation

/// 远程文件搜索：组装/解析服务端 find，经 SFTP exec 跑。纯函数部分可单测。
nonisolated struct RemoteHit: Equatable, Sendable {
    let path: String
    let isDirectory: Bool
}

nonisolated enum RemoteFileSearch {
    /// query 以 / 或 ~ 开头 → 拆 (root=目录部分, pattern=末段)；否则 (home, query)。
    static func resolveRoot(query: String, home: String) -> (root: String, pattern: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if q == "~" {
            return (home, "")                           // 裸 ~ → 列 home 目录
        } else if q.hasPrefix("~/") {
            expanded = home + String(q.dropFirst(1))    // "~/x" → home + "/x"
        } else if q.hasPrefix("/") {
            expanded = q
        } else {
            return (home, q)
        }
        if let slash = expanded.lastIndex(of: "/") {
            let dir = String(expanded[..<slash])
            let last = String(expanded[expanded.index(after: slash)...])
            return (dir.isEmpty ? "/" : dir, last)
        }
        return (home, expanded)
    }

    /// 单引号转义：包 '…'，内部 ' → '\''。
    static func shSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// find <root> -maxdepth N \( -type f -o -type d \) -iname '*<pat>*' -printf '%y\t%p\n' 2>/dev/null | head -n L
    static func buildFindCommand(root: String, pattern: String,
                                 maxDepth: Int = 8, limit: Int = 200) -> String {
        let rootQ = shSingleQuote(root)
        let pat = pattern.isEmpty ? "*" : "*\(pattern)*"
        let patQ = shSingleQuote(pat)
        return "find \(rootQ) -maxdepth \(maxDepth) \\( -type f -o -type d \\) "
            + "-iname \(patQ) -printf '%y\\t%p\\n' 2>/dev/null | head -n \(limit)"
    }

    /// 解析 "<type>\t<path>"：d→目录，其余→文件；无 tab 行→文件（非 GNU find 回退）。空行跳过。
    static func parseFindOutput(_ text: String) -> [RemoteHit] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { line in
            let s = String(line)
            guard let tab = s.firstIndex(of: "\t") else {
                return s.isEmpty ? nil : RemoteHit(path: s, isDirectory: false)
            }
            let type = s[..<tab]
            let path = String(s[s.index(after: tab)...])
            guard !path.isEmpty else { return nil }
            return RemoteHit(path: path, isDirectory: type == "d")
        }
    }

    /// 跑搜索：resolveRoot → buildFindCommand → provider.exec → parseFindOutput。
    static func search(query: String, home: String,
                       provider: any SFTPProviding) async throws -> [RemoteHit] {
        let (root, pattern) = resolveRoot(query: query, home: home)
        let cmd = buildFindCommand(root: root, pattern: pattern)
        let out = try await provider.exec(cmd)
        return parseFindOutput(out)
    }
}
