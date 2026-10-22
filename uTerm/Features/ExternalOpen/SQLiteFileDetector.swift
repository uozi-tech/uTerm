import Foundation

/// 「这个远端文件是不是 SQLite 数据库」的判定。
///
/// 两道：先看扩展名挑候选（不读任何字节，决定菜单里显不显示「在 uTable 中打开」），
/// 真要交给 uTable 之前再读前 16 字节核文件头——`.db` 并不都是 SQLite
/// （BerkeleyDB、bbolt、各种私有格式都爱用这个扩展名），交错了 uTable 只会报一句
/// 「file is not a database」。
nonisolated enum SQLiteFileDetector {
    /// SQLite 3 文件头：`"SQLite format 3\0"`（官方文件格式文档 §1.3）。
    static let header = Data("SQLite format 3\u{0}".utf8)

    /// 常见的 SQLite 扩展名（已小写，不带点）。
    static let candidateExtensions: Set<String> = [
        "db", "db3", "sqlite", "sqlite3", "s3db", "sl3",
    ]

    /// 按扩展名看是不是 SQLite 候选。
    static func isCandidate(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return candidateExtensions.contains(ext)
    }

    /// 文件开头是不是 SQLite 3 文件头。传入的字节可以比 16 字节长。
    static func hasSQLiteHeader(_ prefix: Data) -> Bool {
        prefix.count >= header.count && prefix.prefix(header.count) == header
    }

    /// 回滚日志 / WAL 伴生文件路径。任一存在，说明有进程正在（或刚刚异常退出时）
    /// 写这个库：此时把整库拉下来改完再盖回去，会跟远端进程的写入互相覆盖。
    static func companionPaths(for path: String) -> [String] {
        [path + "-wal", path + "-journal"]
    }
}
