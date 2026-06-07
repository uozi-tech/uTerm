import SwiftUI

/// 远程文件的"种类"——由扩展名 + 是否目录派生。提供中文类型标签、列表角标
/// （PY / YML…）与角标色。纯值逻辑，便于单测；视图据此上色/打标。
///
/// 注意：与 `uTerm/Preview/FileBuffer.swift` 中仅用于预览路由的 `FileKind` 不同，
/// 此类型面向文件浏览器列表的分类显示。
enum BrowserFileKind: Equatable {
    case folder
    /// 符号链接（统一链接图标，不预判目标是目录还是文件；点击时再解析）。
    case symlink
    /// 普通文件：label = 中文类型名；tag = 可选语言角标；tagColor = 角标底色。
    case file(label: String, tag: String?, tagColor: Color?)

    /// `isSymlink` 优先于 `isDirectory` —— symlink 的 lstat 类型恒非目录，但要单独成
    /// 一类显示链接图标。
    static func from(name: String, isDirectory: Bool, isSymlink: Bool = false) -> BrowserFileKind {
        if isSymlink { return .symlink }
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        func code(_ label: String, _ tag: String, _ c: Color) -> BrowserFileKind {
            .file(label: label, tag: tag, tagColor: c)
        }
        switch ext {
        case "py":             return code("Python 脚本", "PY",  Color(red: 0.36, green: 0.61, blue: 0.84))
        case "go":             return code("Go 源码",     "GO",  Color(red: 0.30, green: 0.77, blue: 0.84))
        case "yml", "yaml":    return code("YAML",        "YML", Color(red: 0.79, green: 0.55, blue: 0.86))
        case "md", "markdown": return .file(label: "Markdown", tag: "MD", tagColor: Color(red: 0.54, green: 0.70, blue: 0.97))
        case "gz", "tgz", "zip", "tar", "xz", "bz2":
            return code("归档", "GZ", Color(red: 0.88, green: 0.64, blue: 0.35))
        case "json", "js", "ts", "sh", "conf", "toml", "xml", "html", "css":
            return code(ext.uppercased(), ext.uppercased(), Color(red: 0.54, green: 0.70, blue: 0.97))
        default:
            return .file(label: "文件", tag: nil, tagColor: nil)
        }
    }

    var label: String {
        switch self {
        case .folder:                 return "文件夹"
        case .symlink:                return "符号链接"
        case .file(let label, _, _):  return label
        }
    }

    var tag: String? {
        switch self {
        case .folder, .symlink:     return nil
        case .file(_, let tag, _):  return tag
        }
    }

    var tagColor: Color? {
        switch self {
        case .folder, .symlink:        return nil
        case .file(_, _, let color):   return color
        }
    }
}

/// POSIX 权限位 → `drwxr-xr-x` 串。`mode` 含文件类型位（`S_IFMT` 掩码 `0o170000`）。
/// `mode` 为 nil 时返回占位 `----------`。
func posixPermissionString(_ mode: UInt32?) -> String {
    guard let mode else { return "----------" }
    var s: String
    switch mode & 0o170000 {
    case 0o040000: s = "d"
    case 0o120000: s = "l"
    default:       s = "-"
    }
    let bits: [(UInt32, String)] = [
        (0o400, "r"), (0o200, "w"), (0o100, "x"),
        (0o040, "r"), (0o020, "w"), (0o010, "x"),
        (0o004, "r"), (0o002, "w"), (0o001, "x"),
    ]
    for (mask, ch) in bits { s += (mode & mask) != 0 ? ch : "-" }
    return s
}

/// POSIX 权限位 → `"755"` / 含特殊位时 `"4755"`。`mode` 为 nil 返回 `"—"`。
/// 只取低 12 位（`& 0o7777`，含 setuid/setgid/sticky）；文件类型位被忽略。
func posixOctalString(_ mode: UInt32?) -> String {
    guard let mode else { return "—" }
    let perm = mode & 0o7777
    let special = (perm >> 9) & 0o7
    let base = String((perm >> 6) & 7) + String((perm >> 3) & 7) + String(perm & 7)
    return special != 0 ? String(special) + base : base
}
