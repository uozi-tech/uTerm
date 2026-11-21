import Foundation

/// 体验主机（不联网的演示主机）的内存文件系统。终端里的模拟 shell 与文件页共用同一份，
/// 所以在终端里 `echo hi > a.txt`，文件页刷新就能看到 `a.txt`，反过来上传的文件 `cat` 得出来。
///
/// 每次启动按种子重新生成，不落盘。路径一律是规范化后的绝对路径（`/` 开头、无 `.` / `..`、无尾斜杠）。
/// 跨线程用（终端后端与文件页的 provider 各是一个 actor），内部一把锁。
nonisolated final class DemoFileSystem: @unchecked Sendable {
    nonisolated enum Node: Equatable, Sendable {
        case directory(mode: UInt32, mtime: Date)
        case file(data: Data, mode: UInt32, mtime: Date)

        var isDirectory: Bool { if case .directory = self { return true } else { return false } }
        var mode: UInt32 {
            switch self {
            case .directory(let mode, _), .file(_, let mode, _): return mode
            }
        }
        var mtime: Date {
            switch self {
            case .directory(_, let mtime), .file(_, _, let mtime): return mtime
            }
        }
        var size: Int {
            if case .file(let data, _, _) = self { return data.count }
            return 4096
        }
    }

    static let home = "/home/demo"
    static let user = "demo"
    static let hostname = "uterm-demo"
    /// 文件页显示的属主（SFTP 只给数字 ID，这里直接带上名字）。
    static let uid: UInt32 = 1000

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]

    init(seed: Bool = true, now: Date = Date()) {
        nodes["/"] = .directory(mode: 0o755, mtime: now)
        if seed { Self.seed(into: self, now: now) }
    }

    // MARK: - 路径

    /// 把 `path`（相对 `cwd`，可带 `~`）规范成绝对路径。
    static func normalize(_ path: String, cwd: String) -> String {
        var raw = path
        if raw == "~" { raw = home } else if raw.hasPrefix("~/") { raw = home + raw.dropFirst(1) }
        if !raw.hasPrefix("/") { raw = (cwd == "/" ? "" : cwd) + "/" + raw }
        var parts: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func parent(of path: String) -> String {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return "/" }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    static func name(of path: String) -> String {
        path == "/" ? "/" : String(path.split(separator: "/").last ?? "")
    }

    /// 提示符里显示的路径：家目录下写成 `~`。
    static func display(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - 读

    func node(at path: String) -> Node? {
        lock.withLock { nodes[path] }
    }

    func isDirectory(_ path: String) -> Bool { node(at: path)?.isDirectory == true }

    /// 目录下的直接子项，按名字排好。
    func children(of path: String) throws -> [(name: String, node: Node)] {
        try lock.withLock { () in
            guard let dir = nodes[path] else { throw DemoFSError.noSuchFile(path) }
            guard dir.isDirectory else { throw DemoFSError.notDirectory(path) }
            let prefix = path == "/" ? "/" : path + "/"
            return nodes.compactMap { key, node -> (name: String, node: Node)? in
                guard key != path, key.hasPrefix(prefix) else { return nil }
                let rest = key.dropFirst(prefix.count)
                guard !rest.contains("/") else { return nil }
                return (String(rest), node)
            }
            .sorted { $0.name < $1.name }
        }
    }

    func read(_ path: String) throws -> Data {
        switch node(at: path) {
        case nil: throw DemoFSError.noSuchFile(path)
        case .directory: throw DemoFSError.isDirectory(path)
        case .file(let data, _, _): return data
        }
    }

    /// `path` 以下（含自己）的全部路径，深度优先、同层按名字排。
    func walk(_ path: String) -> [String] {
        lock.withLock {
            let prefix = path == "/" ? "/" : path + "/"
            return nodes.keys.filter { $0 == path || $0.hasPrefix(prefix) }.sorted()
        }
    }

    // MARK: - 写

    func write(_ path: String, data: Data, append: Bool = false, now: Date = Date()) throws {
        try lock.withLock {
            let parent = Self.parent(of: path)
            guard let dir = nodes[parent] else { throw DemoFSError.noSuchFile(path) }
            guard dir.isDirectory else { throw DemoFSError.notDirectory(parent) }
            switch nodes[path] {
            case .directory: throw DemoFSError.isDirectory(path)
            case .file(let old, let mode, _):
                nodes[path] = .file(data: append ? old + data : data, mode: mode, mtime: now)
            case nil:
                nodes[path] = .file(data: data, mode: 0o644, mtime: now)
            }
        }
    }

    /// 新建空文件；已存在时只更新时间（`touch` 语义）。`exclusive` 为 true 时已存在就报错。
    func touch(_ path: String, exclusive: Bool = false, now: Date = Date()) throws {
        try lock.withLock {
            let parent = Self.parent(of: path)
            guard let dir = nodes[parent] else { throw DemoFSError.noSuchFile(path) }
            guard dir.isDirectory else { throw DemoFSError.notDirectory(parent) }
            switch nodes[path] {
            case .directory(let mode, _):
                if exclusive { throw DemoFSError.exists(path) }
                nodes[path] = .directory(mode: mode, mtime: now)
            case .file(let data, let mode, _):
                if exclusive { throw DemoFSError.exists(path) }
                nodes[path] = .file(data: data, mode: mode, mtime: now)
            case nil:
                nodes[path] = .file(data: Data(), mode: 0o644, mtime: now)
            }
        }
    }

    func mkdir(_ path: String, parents: Bool = false, now: Date = Date()) throws {
        try lock.withLock {
            if let existing = nodes[path] {
                if parents && existing.isDirectory { return }
                throw DemoFSError.exists(path)
            }
            if parents {
                var cur = ""
                for part in path.split(separator: "/") {
                    cur += "/" + part
                    switch nodes[cur] {
                    case nil: nodes[cur] = .directory(mode: 0o755, mtime: now)
                    case .file: throw DemoFSError.notDirectory(cur)
                    case .directory: continue
                    }
                }
                return
            }
            let parent = Self.parent(of: path)
            guard let dir = nodes[parent] else { throw DemoFSError.noSuchFile(path) }
            guard dir.isDirectory else { throw DemoFSError.notDirectory(parent) }
            nodes[path] = .directory(mode: 0o755, mtime: now)
        }
    }

    /// 删除。目录要么 `recursive`，要么是空的（`allowEmptyDirectory`，即 `rmdir`）。
    func remove(_ path: String, recursive: Bool = false, allowEmptyDirectory: Bool = false) throws {
        try lock.withLock {
            guard path != "/" else { throw DemoFSError.permissionDenied(path) }
            guard let node = nodes[path] else { throw DemoFSError.noSuchFile(path) }
            if node.isDirectory {
                let prefix = path + "/"
                let hasChildren = nodes.keys.contains { $0.hasPrefix(prefix) }
                if !recursive {
                    guard allowEmptyDirectory else { throw DemoFSError.isDirectory(path) }
                    guard !hasChildren else { throw DemoFSError.notEmpty(path) }
                }
                for key in nodes.keys where key.hasPrefix(prefix) { nodes[key] = nil }
            }
            nodes[path] = nil
        }
    }

    /// 改名 / 移动。目标是已存在的目录时移到它里面（`mv a dir/` 语义）。返回最终路径。
    @discardableResult
    func move(_ from: String, to: String, now: Date = Date()) throws -> String {
        try lock.withLock {
            guard let node = nodes[from] else { throw DemoFSError.noSuchFile(from) }
            var dest = to
            if nodes[to]?.isDirectory == true { dest = (to == "/" ? "" : to) + "/" + Self.name(of: from) }
            guard dest != from else { return dest }
            if node.isDirectory, dest.hasPrefix(from + "/") { throw DemoFSError.invalidArgument(dest) }
            let parent = Self.parent(of: dest)
            guard nodes[parent]?.isDirectory == true else { throw DemoFSError.noSuchFile(dest) }
            if nodes[dest]?.isDirectory == true { throw DemoFSError.isDirectory(dest) }
            let prefix = from + "/"
            let moved = nodes.filter { $0.key == from || $0.key.hasPrefix(prefix) }
            for key in moved.keys { nodes[key] = nil }
            for (key, value) in moved { nodes[dest + key.dropFirst(from.count)] = value }
            return dest
        }
    }

    /// 复制。目录要 `recursive`。目标是已存在的目录时复制到它里面。
    func copy(_ from: String, to: String, recursive: Bool = false, now: Date = Date()) throws {
        try lock.withLock {
            guard let node = nodes[from] else { throw DemoFSError.noSuchFile(from) }
            if node.isDirectory && !recursive { throw DemoFSError.omittingDirectory(from) }
            var dest = to
            if nodes[to]?.isDirectory == true { dest = (to == "/" ? "" : to) + "/" + Self.name(of: from) }
            if node.isDirectory, dest.hasPrefix(from + "/") { throw DemoFSError.invalidArgument(dest) }
            guard nodes[Self.parent(of: dest)]?.isDirectory == true else { throw DemoFSError.noSuchFile(dest) }
            let prefix = from + "/"
            for (key, value) in nodes where key == from || key.hasPrefix(prefix) {
                let target = dest + key.dropFirst(from.count)
                switch value {
                case .directory(let mode, _): nodes[target] = .directory(mode: mode, mtime: now)
                case .file(let data, let mode, _): nodes[target] = .file(data: data, mode: mode, mtime: now)
                }
            }
        }
    }

    func chmod(_ path: String, mode: UInt32, recursive: Bool = false) throws {
        try lock.withLock {
            guard nodes[path] != nil else { throw DemoFSError.noSuchFile(path) }
            let prefix = path + "/"
            for (key, value) in nodes where key == path || (recursive && key.hasPrefix(prefix)) {
                switch value {
                case .directory(_, let mtime): nodes[key] = .directory(mode: mode & 0o777, mtime: mtime)
                case .file(let data, _, let mtime): nodes[key] = .file(data: data, mode: mode & 0o777, mtime: mtime)
                }
            }
        }
    }
}

/// 演示文件系统的错误。文案仿 coreutils（`No such file or directory` 等），终端里原样打印。
nonisolated enum DemoFSError: Error, Equatable, LocalizedError {
    case noSuchFile(String)
    case notDirectory(String)
    case isDirectory(String)
    case exists(String)
    case notEmpty(String)
    case omittingDirectory(String)
    case invalidArgument(String)
    case permissionDenied(String)

    var path: String {
        switch self {
        case .noSuchFile(let p), .notDirectory(let p), .isDirectory(let p), .exists(let p),
             .notEmpty(let p), .omittingDirectory(let p), .invalidArgument(let p), .permissionDenied(let p):
            return p
        }
    }

    /// 不带路径的那半句，shell 自己拼 `cmd: path: reason`。
    var reason: String {
        switch self {
        case .noSuchFile: return "No such file or directory"
        case .notDirectory: return "Not a directory"
        case .isDirectory: return "Is a directory"
        case .exists: return "File exists"
        case .notEmpty: return "Directory not empty"
        case .omittingDirectory: return "is a directory (not copied)"
        case .invalidArgument: return "Invalid argument"
        case .permissionDenied: return "Permission denied"
        }
    }

    var errorDescription: String? { "\(path): \(reason)" }
}

// MARK: - 种子

nonisolated extension DemoFileSystem {
    /// 一台「普通开发机」的样子：家目录里有说明、一个小网站项目、日志、脚本。
    static func seed(into fs: DemoFileSystem, now: Date) {
        let day: TimeInterval = 86_400
        func dir(_ path: String, _ age: TimeInterval) {
            fs.nodes[path] = .directory(mode: 0o755, mtime: now - age)
        }
        func file(_ path: String, _ text: String, _ age: TimeInterval, mode: UInt32 = 0o644) {
            fs.nodes[path] = .file(data: Data(text.utf8), mode: mode, mtime: now - age)
        }

        for path in ["/bin", "/etc", "/home", "/tmp", "/usr", "/var", "/var/log"] { dir(path, 30 * day) }
        dir(home, 12 * day)
        file("/etc/hostname", "\(hostname)\n", 30 * day)
        file("/etc/os-release", """
            PRETTY_NAME="uTerm Demo Linux"
            NAME="uTerm Demo"
            VERSION_ID="1.0"
            ID=uterm-demo

            """, 30 * day)

        file(home + "/.bashrc", """
            # ~/.bashrc
            export EDITOR=vim
            alias ll='ls -l'

            """, 12 * day)
        file(home + "/README.md", String(localized: """
            # 欢迎来到 uTerm 体验主机

            这是一台模拟的 Linux 主机，所有文件都只在这台设备的内存里，关掉 App 就恢复原样。

            可以试试：
              ls -l          看看有什么
              cd projects    进入目录
              cat notes.txt  读文件
              echo hi > a.txt  写文件，然后去「文件」页看它
              help           列出支持的命令

            连接你自己的服务器：回到「主机」页点右上角的「+」。

            """), 2 * day)
        file(home + "/notes.txt", """
            TODO
            - 给 nginx 加 gzip
            - 把 deploy.sh 改成先跑测试
            - 周五前轮换数据库密码

            """, 1 * day)

        dir(home + "/projects", 9 * day)
        dir(home + "/projects/website", 3 * day)
        file(home + "/projects/website/index.html", """
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><title>Hello</title></head>
            <body><h1>Hello from uTerm</h1></body>
            </html>

            """, 3 * day)
        file(home + "/projects/website/style.css", "body { font-family: system-ui; margin: 4rem; }\n", 3 * day)
        file(home + "/projects/website/deploy.sh", """
            #!/bin/sh
            set -e
            rsync -av ./ web@example.com:/srv/www/

            """, 3 * day, mode: 0o755)
        dir(home + "/projects/api", 5 * day)
        file(home + "/projects/api/main.go", """
            package main

            import (
            \t"fmt"
            \t"net/http"
            )

            func main() {
            \thttp.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
            \t\tfmt.Fprintln(w, "ok")
            \t})
            \thttp.ListenAndServe(":8080", nil)
            }

            """, 5 * day)
        file(home + "/projects/api/config.yaml", """
            server:
              port: 8080
            database:
              host: 127.0.0.1
              name: app

            """, 5 * day)

        dir(home + "/logs", 1 * day)
        let log = (0..<24).map { i -> String in
            let level = i % 7 == 6 ? "WARN" : "INFO"
            let message = i % 7 == 6 ? "slow request /api/orders 812ms" : "GET /api/health 200 3ms"
            return String(format: "2026-11-20 %02ld:00:01 ", i) + "\(level) \(message)"
        }.joined(separator: "\n") + "\n"
        file(home + "/logs/app.log", log, 600)
        file("/var/log/syslog", "Nov 20 08:00:00 \(hostname) systemd[1]: Started Daily apt upgrade.\n", 1 * day)
    }
}
