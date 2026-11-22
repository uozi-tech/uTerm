import Foundation

/// Claude Code 把每个工作目录的会话记录放在 `~/.claude/projects/<目录名>/<会话 ID>.jsonl`，
/// 目录名由工作目录的绝对路径转来：每个不是 ASCII 字母数字的字符（按 UTF-16 码元算，和 Claude Code
/// 里 `replace(/[^a-zA-Z0-9]/g, "-")` 一致）都换成 `-`。所以 `/Users/a/my.app` → `-Users-a-my-app`，
/// 空格、`.`、汉字都变成 `-`。
///
/// 这个映射不可逆（`/a-b` 和 `/a/b` 是同一个名字），只能从路径往名字算，不能反过来，所以：
/// - 由终端的当前目录找项目：当前目录和它的上级逐个算名字，第一个存在的就是；
/// - 要在哪个目录里继续会话：从记录里看到的 `cwd`（会话中途可能 `cd` 进了子目录）和它们的上级里，
///   挑名字和项目目录对得上的那个。
///
/// 超长路径（Claude Code 新版超过 200 字符会截断再加哈希）对不上，这时退到「全部项目」。
nonisolated enum ClaudeProjectPath {
    /// 相对主目录。
    static let projectsRelativePath = ".claude/projects"

    static func projectsRoot(home: String) -> String {
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return trimmed + "/" + projectsRelativePath
    }

    /// 工作目录 → 项目目录名。
    static func encode(_ path: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(path.utf16.count)
        for unit in path.utf16 {
            let isAlphanumeric = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            if isAlphanumeric, let scalar = Unicode.Scalar(unit) {
                out.unicodeScalars.append(scalar)
            } else {
                out.unicodeScalars.append("-")
            }
        }
        return out
    }

    /// 规整成不带末尾 `/` 的绝对路径（去掉 `.`、`//`，按 `..` 往上走）。不碰文件系统：路径可能在别的主机上。
    /// 不是绝对路径时为 nil。
    static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// 自己和所有上级目录，由近到远，不含根目录 `/`。
    static func lineage(of path: String) -> [String] {
        guard var current = normalized(path) else { return [] }
        var result: [String] = []
        while current != "/" {
            result.append(current)
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { break }
        }
        return result
    }

    /// 终端的当前目录落在哪个项目里：自己或最近的上级目录，名字在 `projectNames` 里的那个。
    static func project(containing directory: String, among projectNames: Set<String>) -> (name: String, path: String)? {
        for candidate in lineage(of: directory) {
            let name = encode(candidate)
            if projectNames.contains(name) { return (name, candidate) }
        }
        return nil
    }

    /// 该在哪个目录里继续这个会话：`candidates`（新的在前）和它们的上级里，名字等于项目目录名的第一个。
    static func resumeDirectory(projectName: String, candidates: [String]) -> String? {
        for candidate in candidates {
            for directory in lineage(of: candidate) where encode(directory) == projectName {
                return directory
            }
        }
        return nil
    }

    /// OSC 7 报来的当前目录（`file://主机名/路径`，路径百分号编码）→ 绝对路径。
    /// 也认 kitty 的 `kitty-shell-cwd://` 和直接给的绝对路径。认不出来为 nil。
    static func directory(fromOSC7 value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return normalized(trimmed) }
        var rest: Substring
        if trimmed.hasPrefix("file://") {
            rest = trimmed.dropFirst("file://".count)
        } else if trimmed.hasPrefix("kitty-shell-cwd://") {
            rest = trimmed.dropFirst("kitty-shell-cwd://".count)
        } else {
            return nil
        }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        rest = rest[slash...]
        guard let decoded = String(rest).removingPercentEncoding else { return nil }
        return normalized(decoded)
    }
}
