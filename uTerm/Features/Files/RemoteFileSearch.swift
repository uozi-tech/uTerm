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

    /// 单引号转义：包 '…'，内部 ' → '\''。转发到共享的 `RemotePath.shellQuote`。
    static func shSingleQuote(_ s: String) -> String {
        RemotePath.shellQuote(s)
    }

    /// `sh -c '… find "$a0" -maxdepth N \( -type f -o -type d \) -iname "$a1" -printf '%y\t%p\n' 2>/dev/null | head -n L'`
    /// （根目录与模式都按字节传进去，见 `RemotePath.shScript`；模式可能是从列表里拷来的名字，和根目录一样按
    /// provider 的写法还原）。
    static func buildFindCommand(root: String, pattern: String, escapedNames: Bool = false,
                                 maxDepth: Int = 8, limit: Int = 200) -> String {
        let pat = pattern.isEmpty ? "*" : "*\(pattern)*"
        return RemotePath.shScript(
            "find \(argument: 0) -maxdepth \(maxDepth) \\( -type f -o -type d \\) "
                + "-iname \(argument: 1) -printf '%y\\t%p\\n' 2>/dev/null | head -n \(limit)",
            arguments: [root, pat], escapedNames: escapedNames)
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
        let escapes = provider.escapesRawNames
        let cmd = buildFindCommand(root: root, pattern: pattern, escapedNames: escapes)
        let out = try await provider.exec(cmd)
        let hits = parseFindOutput(out)
        // find 打出来的是服务器上的原样文字，不是 `RemoteName` 写法：换成那种写法再交给会还原转义的 provider，
        // 名字里本来就有的 U+2060 才不会被误认成转义的收尾。（exec 的输出已按 UTF-8 有损解码过，不是 UTF-8 的
        // 名字在这里已经找不回原样字节，和迁移前一样打不开。）
        guard escapes else { return hits }
        return hits.map { RemoteHit(path: RemoteName.display($0.path.utf8), isDirectory: $0.isDirectory) }
    }
}
