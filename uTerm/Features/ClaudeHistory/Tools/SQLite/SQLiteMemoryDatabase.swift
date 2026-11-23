import Foundation
import SQLite3

/// 打开库或查询时 SQLite 报的错。`isCorruption`：库的字节本身不对（读到了写到一半的状态，或者文件就是坏的）。
nonisolated struct SQLiteError: Error, Equatable, Sendable {
    let code: Int32
    let message: String

    var isCorruption: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }
}

/// 只在内存里的一份只读 SQLite 库：主文件的字节 + `-wal` 里提交过的页，经 `sqlite3_deserialize` 交给系统的 SQLite。
///
/// 不碰任何文件：连接开在 `:memory:` 上，`temp_store = MEMORY`（排序之类的临时表也不落盘），库是只读的。
/// 不是 Sendable：在哪个 actor 里建就只在那里用（`SQLiteRemoteReader.read` 把它交给同步的闭包）。
nonisolated final class SQLiteMemoryDatabase {
    private var handle: OpaquePointer?

    static let headerMagic = Data("SQLite format 3\0".utf8)

    /// `main`：主文件的字节（可以是空的，库还没并回过）；`wal`：`-wal` 的字节（没有就是空的）。
    /// 主文件不是 SQLite 的抛 `SQLiteRemoteReadError.notSQLite`。
    init(main: Data, wal: Data, walIndex: SQLiteWALIndex? = nil) throws {
        let index = walIndex ?? SQLiteWAL.index(wal)
        let length = SQLiteWAL.imageLength(index, mainCount: main.count)
        if !main.isEmpty, !main.starts(with: Self.headerMagic) { throw SQLiteRemoteReadError.notSQLite }

        var db: OpaquePointer?
        let opened = sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        handle = db
        guard opened == SQLITE_OK, let db else { throw Self.error(db, opened) }
        try exec("PRAGMA temp_store = MEMORY")

        // 空库（新建、一页都还没写）：内存里那个空的 main 就是它。
        guard length > 0 else { return }
        guard length >= 100, let buffer = sqlite3_malloc64(sqlite3_uint64(length)) else {
            throw length < 100 ? SQLiteRemoteReadError.notSQLite : SQLiteError(code: SQLITE_NOMEM, message: "out of memory")
        }
        let bytes = UnsafeMutableRawBufferPointer(start: buffer, count: length)
        SQLiteWAL.apply(index, wal: wal, main: main, into: bytes)
        guard bytes.starts(with: Self.headerMagic) else {
            sqlite3_free(buffer)
            throw SQLiteRemoteReadError.notSQLite
        }
        Self.patchHeader(bytes)
        // FREEONCLOSE：成功与否都由 SQLite 负责释放 buffer。
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
        let result = sqlite3_deserialize(db, "main", buffer.assumingMemoryBound(to: UInt8.self),
                                         sqlite3_int64(length), sqlite3_int64(length), flags)
        guard result == SQLITE_OK else { throw Self.error(db, result) }
        try exec("PRAGMA query_only = ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// 内存库不支持 WAL：文件头里的读写版本（第 18、19 字节，WAL 是 2）改回 1，不然 SQLite 会去找 `-wal`。
    /// 头里记的页数改成实际的长度（它只在「版本对得上」时才作数，一起写上），WAL 让库变长了也读得到后面的页。
    private static func patchHeader(_ bytes: UnsafeMutableRawBufferPointer) {
        bytes[18] = 1
        bytes[19] = 1
        let rawPageSize = Int(bytes[16]) << 8 | Int(bytes[17])
        let pageSize = rawPageSize == 1 ? 65_536 : rawPageSize
        guard pageSize >= 512 else { return }
        let pages = UInt32(bytes.count / pageSize)
        for (index, shift) in [24, 16, 8, 0].enumerated() { bytes[28 + index] = UInt8(truncatingIfNeeded: pages >> UInt32(shift)) }
        for index in 0..<4 { bytes[92 + index] = bytes[24 + index] }
    }

    /// 整库校验（`quick_check`：B 树结构与页的引用，不核索引内容）。读到写到一半的状态多半在这里露出来。
    func quickCheck() throws {
        var result: String?
        try query("PRAGMA quick_check(1)") { row in result = row.text(0) }
        guard result == "ok" else { throw SQLiteError(code: SQLITE_CORRUPT, message: result ?? "quick_check") }
    }

    func exec(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw Self.error(handle, result) }
    }

    /// 跑一条语句，每行交给 `row`。`bindings` 按 `?` 的顺序绑定。
    func query(_ sql: String, _ bindings: [SQLiteBinding] = [], row: (SQLiteRow) throws -> Void) throws {
        let statement = try prepare(sql)
        try statement.run(bindings, row: row)
    }

    /// 要反复用的语句（按 ID 一条条取 blob）先准备好。
    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw Self.error(handle, result) }
        return SQLiteStatement(statement: statement, database: self)
    }

    fileprivate var rawHandle: OpaquePointer? { handle }

    fileprivate static func error(_ db: OpaquePointer?, _ code: Int32) -> SQLiteError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(code))
        return SQLiteError(code: code, message: message)
    }
}

nonisolated enum SQLiteBinding {
    case text(String)
    case integer(Int64)
    case blob(Data)
}

/// 一条准备好的语句。跟着建它的库走（库先释放了语句也就失效，所以它强引用库）。
nonisolated final class SQLiteStatement {
    private let statement: OpaquePointer
    private let database: SQLiteMemoryDatabase

    fileprivate init(statement: OpaquePointer, database: SQLiteMemoryDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func run(_ bindings: [SQLiteBinding], row: (SQLiteRow) throws -> Void) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .blob(let data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard result == SQLITE_OK else { throw SQLiteMemoryDatabase.error(database.rawHandle, result) }
        }
        defer { sqlite3_reset(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw SQLiteMemoryDatabase.error(database.rawHandle, step) }
            try row(SQLiteRow(statement: statement))
        }
    }

    /// 第一行的第一列（按主键取一个值）。
    func firstData(_ bindings: [SQLiteBinding]) throws -> Data? {
        var value: Data?
        try run(bindings) { row in if value == nil { value = row.data(0) } }
        return value
    }
}

/// 当前这一行。只在 `row` 回调里有效。
nonisolated struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    var columnCount: Int { Int(sqlite3_column_count(statement)) }

    func isNull(_ column: Int) -> Bool { sqlite3_column_type(statement, Int32(column)) == SQLITE_NULL }

    func text(_ column: Int) -> String? {
        guard !isNull(column), let pointer = sqlite3_column_text(statement, Int32(column)) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, Int32(column)))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    func data(_ column: Int) -> Data? {
        guard !isNull(column) else { return nil }
        // 先取指针再取长度（SQLite 文档要求的顺序，类型转换只发生一次）。
        let pointer = sqlite3_column_blob(statement, Int32(column))
        let count = Int(sqlite3_column_bytes(statement, Int32(column)))
        guard count > 0, let pointer else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    func integer(_ column: Int) -> Int64 { sqlite3_column_int64(statement, Int32(column)) }
}
