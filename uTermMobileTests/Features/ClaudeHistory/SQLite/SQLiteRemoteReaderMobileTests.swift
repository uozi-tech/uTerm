import Foundation
import SQLite3
import XCTest
@testable import uTermMobile

/// iOS 上的只读 SQLite 读取器（共享代码，两端同一份）：系统自带的 SQLite 在 iOS 上也能 `sqlite3_deserialize`，
/// WAL 里没并回的行读得到，坏文件、超限照样报。完整的用例在 macOS 的 `SQLiteRemoteReaderTests`；这里只核两端会不一样的
/// 地方（系统库的版本与编译选项）。夹具全是测试里现建的假数据。
final class SQLiteRemoteReaderMobileTests: XCTestCase {
    private let path = "/data/store.db"

    /// 在临时目录里建一个 WAL 模式的库，前 `checkpointed` 行并回主文件，其余留在 WAL 里。读出两个文件后关掉。
    private func makeDatabase(rows: Int, checkpointed: Int) throws -> (main: Data, wal: Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-sqlite-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA wal_autocheckpoint = 0")
        exec("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
        for id in 1...rows {
            exec("INSERT INTO items (id, label) VALUES (\(id), '第 \(id) 行')")
            if id == checkpointed { exec("PRAGMA wal_checkpoint(FULL)") }
        }
        let main = try Data(contentsOf: url)
        let wal = (try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))) ?? Data()
        return (main, wal)
    }

    private func provider(main: Data, wal: Data) async throws -> MobileFakeSFTPProvider {
        let provider = MobileFakeSFTPProvider(tree: MobileFakeSFTPTree(directories: ["/": [], "/data": []]))
        try await provider.seedFile(path, data: main)
        if !wal.isEmpty { try await provider.seedFile(path + "-wal", data: wal) }
        return provider
    }

    private static func ids(_ database: SQLiteMemoryDatabase) throws -> [Int] {
        var ids: [Int] = []
        try database.query("SELECT id FROM items ORDER BY id") { ids.append(Int($0.integer(0))) }
        return ids
    }

    func testReadsRowsThatOnlyLiveInTheWAL() async throws {
        let files = try makeDatabase(rows: 30, checkpointed: 10)
        XCTAssertGreaterThan(files.wal.count, SQLiteWAL.headerBytes)
        XCTAssertEqual(try Self.ids(SQLiteMemoryDatabase(main: files.main, wal: Data())), Array(1...10))

        let provider = try await provider(main: files.main, wal: files.wal)
        let read = try await SQLiteRemoteReader(provider: provider, path: path).read { try Self.ids($0) }
        XCTAssertEqual(read?.value, Array(1...30))
        let writes = await provider.callCount(.write) + provider.callCount(.upload) + provider.callCount(.createFile)
        XCTAssertEqual(writes, 0)
    }

    func testNotSQLiteAndTooLarge() async throws {
        let junk = try await provider(main: Data(repeating: 0x5A, count: 4096), wal: Data())
        do {
            _ = try await SQLiteRemoteReader(provider: junk, path: path).read { _ in 0 }
            XCTFail("不是 SQLite 的文件也打开了")
        } catch let error as SQLiteRemoteReadError {
            XCTAssertEqual(error, .notSQLite)
        }

        let files = try makeDatabase(rows: 20, checkpointed: 5)
        let big = try await provider(main: files.main, wal: files.wal)
        let limits = SQLiteReadLimits(maxTotalBytes: 1024, attempts: 3)
        do {
            _ = try await SQLiteRemoteReader(provider: big, path: path, limits: limits).read { _ in 0 }
            XCTFail("超过上限还读了")
        } catch let error as SQLiteRemoteReadError {
            guard case .tooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testDamagedPagesAreReportedAsCorrupt() async throws {
        let files = try makeDatabase(rows: 600, checkpointed: 600)
        var main = files.main
        XCTAssertGreaterThan(main.count, 4096 * 4)
        for offset in (4096 * 2)..<(4096 * 3) { main[offset] = UInt8(truncatingIfNeeded: offset &* 13) }
        // 并回过以后 WAL 里的帧也都在主文件里了：只给主文件，坏页不会被 WAL 盖住。
        let provider = try await provider(main: main, wal: Data())
        do {
            _ = try await SQLiteRemoteReader(provider: provider, path: path).read { try Self.ids($0) }
            XCTFail("坏的库也读出来了")
        } catch let error as SQLiteRemoteReadError {
            guard case .corrupt = error else { return XCTFail("\(error)") }
        }
    }
}
