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

    /// 在远端用 POSIX `sh` 跑一段脚本，脚本里的第 i 个参数是 `"$a<i>"`（按字节原样传进去）。
    ///
    /// 整段包成 `sh -c '…'`：exec 通道交给用户的登录 shell，它可能是 csh / tcsh（单引号里的 `!` 照样做历史展开、
    /// 不认单引号里的换行）或老的 fish；外层只剩一个单引号串，里面没有 `!`、换行这类字符。参数不直接写进命令行，
    /// 而是在脚本开头用 `printf` 的八进制转义造出来（`a0="$(printf '\057…'; printf x)"; a0="${a0%x}"`）：
    /// - 名字里不是 UTF-8 的字节（`RemoteName` 的转义，`escapedNames` 为真时还原）、换行、`!`、引号都不会被哪一层
    ///   shell 另作解释；
    /// - 命令替换会吃掉结尾的换行，末尾垫一个 `x` 再用参数展开去掉，以换行结尾的名字不会变成它的兄弟。
    ///
    /// `escapedNames`：参数是不是 `RemoteName.display` 写法（`SFTPProviding.escapesRawNames`）。配对过的 Mac 一类
    /// 名字本来就是合法 UTF-8 的 provider 传 false，名字里碰巧有转义的样子也原样传过去。
    ///
    /// 所有参数都是「直接写进单引号也不会出事」的文字（没有控制字符、换行、`!`，也不是要还原的转义）时，照旧直接写成
    /// `body`（`"$a<i>"` 换成单引号串），不套 `sh -c`：命令和以前一模一样，演示主机的假 shell 也认得。
    static func shScript(_ body: String, arguments: [String], escapedNames: Bool) -> String {
        let raw = arguments.map { escapedNames ? RemoteName.bytes($0) : Array($0.utf8) }
        if zip(arguments, raw).allSatisfy({ Array($0.utf8) == $1 && $1.allSatisfy(isQuotableByte) }) {
            var direct = body
            // 倒着换：`$a10` 先于 `$a1`。
            for (index, argument) in arguments.enumerated().reversed() {
                direct = direct.replacingOccurrences(of: "\"$a\(index)\"", with: shellQuote(argument))
            }
            return direct
        }
        var script = ""
        for (index, argument) in arguments.enumerated() {
            let bytes = escapedNames ? RemoteName.bytes(argument) : Array(argument.utf8)
            let name = "a\(index)"
            if bytes.allSatisfy(isPlainShellByte), !bytes.isEmpty {
                script += "\(name)='\(String(decoding: bytes, as: UTF8.self))'; "
            } else {
                script += "\(name)=\"$(printf '\(octalFormat(bytes))'; printf x)\"; \(name)=\"${\(name)%x}\"; "
            }
        }
        return "sh -c " + shellQuote(script + body)
    }

    /// 写进单引号串（`shellQuote`）后，sh / bash / zsh / csh / tcsh / fish 都原样当字面值的字节：除了控制字符、DEL、
    /// `!`（csh 在单引号里也做历史展开）之外都行；单引号本身由 `shellQuote` 写成 `'\\''`。合法 UTF-8 的多字节字符也行。
    private static func isQuotableByte(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte != 0x7F && byte != UInt8(ascii: "!")
    }

    /// 不用转义、写进单引号也不会被任何一层 shell 解释的字节。
    private static func isPlainShellByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "/"), UInt8(ascii: "."), UInt8(ascii: "_"),
             UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: ","), UInt8(ascii: "@"), UInt8(ascii: ":"):
            return true
        default:
            return false
        }
    }

    /// `printf` 的格式串：字母数字与 `/._` 原样，其余字节一律三位八进制（`%`、`\`、`'`、`-`、`!`、空白与所有
    /// 非 ASCII 字节都不会被 printf / 任何 shell 另作解释）。
    private static func octalFormat(_ bytes: [UInt8]) -> String {
        var format = ""
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "/"), UInt8(ascii: "."), UInt8(ascii: "_"):
                format.append(Character(Unicode.Scalar(byte)))
            default:
                let octal = String(byte, radix: 8)
                format += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            }
        }
        return format
    }
}
