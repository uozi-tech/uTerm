import Foundation

/// POSIX 权限位（u/g/o × r/w/x 共 9 位）与 chmod 编辑器的 9 个勾选框之间的换算。
///
/// macOS 权限对话框（`SFTPPermissionSheet`）与 iOS 操作单里的权限页（`PermissionGrid`）
/// 共用这一份：勾选状态是 9 个布尔，顺序 rwx(所有者) rwx(群组) rwx(其他)。
/// setuid/setgid/sticky 不在编辑范围内（两端都只改低 9 位）。
nonisolated enum POSIXPermissionBits {
    /// 9 个权限位的掩码与符号字符，顺序与 `bits(from:)` 一致。
    /// `posixPermissionString` 也按这张表逐位输出，不再每次现建数组。
    static let table: [(mask: UInt32, symbol: Character)] = [
        (0o400, "r"), (0o200, "w"), (0o100, "x"),
        (0o040, "r"), (0o020, "w"), (0o010, "x"),
        (0o004, "r"), (0o002, "w"), (0o001, "x"),
    ]

    /// mode → 9 个布尔位。只看低 9 位，类型位 / 特殊位被忽略。
    static func bits(from mode: UInt32) -> [Bool] {
        table.map { (mode & $0.mask) != 0 }
    }

    /// 9 个布尔位 → mode（只含低 9 位）。`bits` 不足 9 个时缺的位按未勾选算。
    static func mode(from bits: [Bool]) -> UInt32 {
        var mode: UInt32 = 0
        for (index, on) in bits.prefix(table.count).enumerated() where on {
            mode |= table[index].mask
        }
        return mode
    }

    /// 9 个布尔位 → 三位八进制（`"755"`）。
    static func octal(_ bits: [Bool]) -> String {
        let mode = mode(from: bits)
        return String((mode >> 6) & 7) + String((mode >> 3) & 7) + String(mode & 7)
    }

    /// 9 个布尔位 → 符号串（`drwxr-xr-x`），首字符是调用方给的类型字符。
    static func symbolic(_ bits: [Bool], typeChar: Character) -> String {
        var out = ""
        out.reserveCapacity(10)
        out.append(typeChar)
        for (index, entry) in table.enumerated() {
            out.append(index < bits.count && bits[index] ? entry.symbol : "-")
        }
        return out
    }

    /// 条目的类型字符：目录 `d`、符号链接 `l`、其余 `-`。
    static func typeChar(for entry: RemoteEntry) -> Character {
        entry.isDirectory ? "d" : (entry.isSymlink ? "l" : "-")
    }

    /// 编辑器打开时的初始权限（只含低 9 位）。
    /// 服务端没给权限位时取常见默认：目录 755 / 符号链接 777 / 普通文件 644。
    static func initialMode(for entry: RemoteEntry) -> UInt32 {
        if let permissions = entry.permissions { return permissions & 0o777 }
        if entry.isDirectory { return 0o755 }
        return entry.isSymlink ? 0o777 : 0o644
    }
}
