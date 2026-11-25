import Foundation
import SQLite3
import XCTest
@testable import uTerm

/// 假主机：一组内存里的文件，目录由文件路径推出来。读之前可以插一手（`setBeforeRead`）模拟「读的时候被写」。
/// 任何写操作都记下来并失败：读取器绝不能往主机上写东西。
actor SQLiteTestHost: SFTPProviding {
    private var files: [String: (data: Data, mtime: Date)] = [:]
    private(set) var reads: [(path: String, offset: UInt64, length: Int)] = []
    private(set) var lists: [String] = []
    private(set) var writeAttempts: [String] = []
    private var beforeRead: (@Sendable (SQLiteTestHost, String) async -> Void)?
    /// 一时连不上的路径（前缀）：列目录、取属性、读都报错，像辅助程序断了一下。
    private var unreachable: [String] = []
    let home: String

    init(home: String = "/home/user") { self.home = home }

    func put(_ path: String, _ data: Data, mtime: Date = Date()) { files[path] = (data, mtime) }
    func remove(_ path: String) { files[path] = nil }
    func data(_ path: String) -> Data? { files[path]?.data }
    func setBeforeRead(_ hook: (@Sendable (SQLiteTestHost, String) async -> Void)?) { beforeRead = hook }
    func setUnreachable(_ prefixes: [String]) { unreachable = prefixes }
    func clearCounters() {
        reads = []
        lists = []
    }
    var bytesRead: Int { reads.reduce(0) { $0 + $1.length } }

    /// 把一份夹具库此刻的两个文件放到 `path`（没有 WAL 就删掉 `-wal`）。
    func install(_ snapshot: SQLiteFixtureSnapshot, at path: String, mtime: Date = Date()) {
        put(path, snapshot.main, mtime: mtime)
        if snapshot.wal.isEmpty { remove(path + "-wal") } else { put(path + "-wal", snapshot.wal, mtime: mtime) }
    }

    private func children(of directory: String) -> [RemoteEntry]? {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        var output: [String: RemoteEntry] = [:]
        var found = false
        for (path, file) in files where path.hasPrefix(prefix) {
            found = true
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                let name = String(rest[..<slash])
                let previous = output[name]?.modifiedAt ?? .distantPast
                output[name] = RemoteEntry(name: name, posixPermissions: 0o040755, size: nil,
                                           modifiedAt: max(previous, file.mtime))
            } else {
                output[String(rest)] = RemoteEntry(name: String(rest), posixPermissions: 0o100644,
                                                   size: UInt64(file.data.count), modifiedAt: file.mtime)
            }
        }
        return found ? Array(output.values).sorted { $0.name < $1.name } : nil
    }

    private func checkReachable(_ path: String) throws {
        guard unreachable.contains(where: { path.hasPrefix($0) }) else { return }
        throw NSError(domain: "SQLiteTestHost", code: 4, userInfo: [NSLocalizedDescriptionKey: "connection interrupted: \(path)"])
    }

    private func missing(_ path: String) -> NSError {
        NSError(domain: "SQLiteTestHost", code: 2, userInfo: [NSLocalizedDescriptionKey: "no such file: \(path)"])
    }

    func list(path: String) async throws -> [RemoteEntry] {
        lists.append(path)
        try checkReachable(path)
        guard let entries = children(of: path) else { throw missing(path) }
        return entries
    }

    func realPath(_ path: String) async throws -> String { path == "." ? home : path }

    func stat(_ path: String) async throws -> RemoteStat {
        try checkReachable(path)
        if let file = files[path] { return RemoteStat(size: Int64(file.data.count), mtime: file.mtime) }
        if let entries = children(of: path) {
            return RemoteStat(size: 0, mtime: entries.compactMap(\.modifiedAt).max() ?? .distantPast, permissions: 0o040755)
        }
        throw missing(path)
    }

    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        if let beforeRead { await beforeRead(self, path) }
        reads.append((path, offset, length))
        try checkReachable(path)
        guard let data = files[path]?.data else { throw missing(path) }
        let start = min(Int(offset), data.count)
        return data.subdata(in: start..<min(data.count, start + max(0, length)))
    }

    func download(remotePath: String) async throws -> Data {
        guard let data = files[remotePath]?.data else { throw missing(remotePath) }
        return data
    }

    private func refuse(_ what: String) throws -> Never {
        writeAttempts.append(what)
        throw NSError(domain: "SQLiteTestHost", code: 13, userInfo: [NSLocalizedDescriptionKey: "read-only host"])
    }

    func upload(data: Data, toRemotePath: String) async throws { try refuse("upload \(toRemotePath)") }
    func write(_ path: String, data: Data) async throws { try refuse("write \(path)") }
    func writeRange(_ path: String, offset: UInt64, data: Data, mode: SFTPWriteMode) async throws { try refuse("writeRange \(path)") }
    func openTransferHandle(_ path: String, writeMode: SFTPWriteMode?) async throws -> SFTPTransferHandle {
        try refuse("open \(path)")
    }
    func exec(_ command: String) async throws -> String { try refuse("exec") }
    func rename(_ path: String, to newPath: String) async throws { try refuse("rename \(path)") }
    func removeFile(_ path: String) async throws { try refuse("remove \(path)") }
    func removeDirectory(_ path: String) async throws { try refuse("rmdir \(path)") }
    func createDirectory(_ path: String) async throws { try refuse("mkdir \(path)") }
    func createFile(_ path: String) async throws { try refuse("create \(path)") }
    func setPermissions(path: String, mode: UInt32) async throws { try refuse("chmod \(path)") }
    func upload(data: Data, toRemotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try refuse("upload \(toRemotePath)")
    }
    func download(remotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        try await download(remotePath: remotePath)
    }
    func download(remotePath: String, toLocalURL localURL: URL, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try refuse("download to local file")
    }
    func upload(localURL: URL, toRemotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try refuse("upload \(toRemotePath)")
    }
    func close() async {}
}

/// 一份库此刻的两个文件。
struct SQLiteFixtureSnapshot: Sendable {
    var main: Data
    var wal: Data
}

/// 在测试的临时目录里现建一个 WAL 模式的库。连接一直开着、自动并回关掉（`wal_autocheckpoint = 0`），写进去的东西就留在
/// `-wal` 里没并回主文件——会话正开着时真实的库就是这样。`snapshot()` 读出此刻的两个文件。
final class SQLiteFixtureDatabase {
    let directory: URL
    let url: URL
    private var db: OpaquePointer?

    init(name: String = "store.db") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-sqlite-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure(message: "open") }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA wal_autocheckpoint = 0")
    }

    deinit {
        sqlite3_close_v2(db)
        try? FileManager.default.removeItem(at: directory)
    }

    struct Failure: Error { let message: String }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw Failure(message: message)
        }
    }

    /// 执行一条带参数的语句（参数按 `?` 的顺序；`Data` 绑成 blob，`String` 绑成文本，`Int` 绑成整数）。
    func run(_ sql: String, _ values: [Any]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure(message: "prepare \(sql)") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let data as Data:
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case let text as String:
                sqlite3_bind_text(statement, index, text, -1, transient)
            case let number as Int:
                sqlite3_bind_int64(statement, index, Int64(number))
            default:
                throw Failure(message: "bind \(type(of: value))")
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
    }

    /// 把 WAL 全部并回主文件。`truncate`：并完把 WAL 截成 0（下一次写从头开始、换 salt）。
    func checkpoint(truncate: Bool = false) throws {
        try exec(truncate ? "PRAGMA wal_checkpoint(TRUNCATE)" : "PRAGMA wal_checkpoint(FULL)")
    }

    func snapshot() throws -> SQLiteFixtureSnapshot {
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let wal = (try? Data(contentsOf: walURL)) ?? Data()
        return SQLiteFixtureSnapshot(main: try Data(contentsOf: url), wal: wal)
    }
}

/// 测试里常用的小库：`items(id INTEGER PRIMARY KEY, label TEXT, payload BLOB)`。
enum SQLiteFixtureRows {
    static func create(_ db: SQLiteFixtureDatabase) throws {
        try db.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT, payload BLOB)")
    }

    /// 插 `range` 这几行；`payloadBytes` 大一点能让库长出好多页。
    static func insert(_ db: SQLiteFixtureDatabase, _ range: Range<Int>, payloadBytes: Int = 16) throws {
        try db.exec("BEGIN")
        for id in range {
            try db.run("INSERT INTO items (id, label, payload) VALUES (?, ?, ?)",
                       [id, "第 \(id) 行", Data(repeating: UInt8(id % 251), count: payloadBytes)])
        }
        try db.exec("COMMIT")
    }

    /// 内存库里的全部 ID。
    static func ids(_ database: SQLiteMemoryDatabase) throws -> [Int] {
        var ids: [Int] = []
        try database.query("SELECT id FROM items ORDER BY id") { ids.append(Int($0.integer(0))) }
        return ids
    }
}

/// 只触发一次。
final class SQLiteTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func setOnce() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}

/// 数第几次。
final class SQLiteTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
