import Foundation

/// 远程（POSIX）路径的拼接 / 上一级 / 规范化 / 面包屑 / shell 引号。
///
/// macOS 文件浏览器（`FileBrowserModel` 及 SFTP 窗口各视图）与 iOS 文件标签
/// （`MobileSFTPController` / `FilesSessionBody`）共用这一份。只做字符串运算，
/// 不碰网络、不解析 `.` / `..` / 符号链接。
nonisolated enum RemotePath {
    /// 目录 + 名字。根目录不重复斜杠：`join("/", "a") == "/a"`。
    static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    /// 上一级目录；根的上一级仍是根。多余的斜杠（`/a//b/`）不影响结果。
    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        var components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return "/" }
        components.removeLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    /// 规范成「`/` 开头、不带尾斜杠」：空串 → `/`，`a/b/` → `/a/b`。
    static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        var value = path.hasPrefix("/") ? path : "/" + path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// 面包屑段：第一段恒为根 `("/", "/")`，其后每段是 (段名, 到该段为止的绝对路径)。
    /// `/home/user` → `[("/", "/"), ("home", "/home"), ("user", "/home/user")]`。
    static func breadcrumbs(_ path: String) -> [(name: String, full: String)] {
        var result: [(name: String, full: String)] = [(name: "/", full: "/")]
        var accumulated = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            accumulated += "/" + component
            result.append((name: String(component), full: accumulated))
        }
        return result
    }

    /// 把字符串包成单引号串供 shell（exec channel）安全使用：单引号内一切原样，
    /// 内嵌单引号用 `'\''` 收尾再续。杜绝路径注入 / 空格问题。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 远程**路径**交给 shell：同 `shellQuote`，但路径里有不是 UTF-8 的名字（`RemoteName` 的转义）时，
    /// 还原成服务器上的原样字节——用 `printf` 的八进制转义造出来（`"$(printf '\262\342…')"`，POSIX sh 都认），
    /// 否则 `chmod -R`、`stat`、`find` 拿到的是转义后的字符串，找不到那个文件。
    static func shellQuotePath(_ path: String) -> String {
        let bytes = RemoteName.bytes(path)
        guard bytes != Array(path.utf8) else { return shellQuote(path) }
        var format = ""
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "/"), UInt8(ascii: "."),
                 UInt8(ascii: "_"):
                format.append(Character(Unicode.Scalar(byte)))
            default:
                // 其余一律八进制：`%`、`\`、`'`、`-`（开头的 `-` 会被当成选项）、空白与所有非 ASCII 字节
                // 都不会被 printf / shell 另作解释。
                let octal = String(byte, radix: 8)
                format += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            }
        }
        return "\"$(printf '" + format + "')\""
    }
}
