import Foundation
import XCTest
@testable import uTerm

/// 只读的远端 SQLite 读取器：库在内存里打开，WAL 里没并回的内容读得到，读到撕裂的状态能认出来重读，不往主机上写东西。
final class SQLiteRemoteReaderTests: XCTestCase {
    private let path = "/home/user/data/store.db"

    private func makeHost(_ snapshot: SQLiteFixtureSnapshot, mtime: Date = Date(timeIntervalSince1970: 1_800_000_000))
        async -> SQLiteTestHost {
        let host = SQLiteTestHost()
        await host.install(snapshot, at: path, mtime: mtime)
        return host
    }

    /// 只在 WAL 里的行：主文件里没有，读取器读得到。
    func testReadsRowsThatOnlyLiveInTheWAL() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<11)
        try db.checkpoint()
        try SQLiteFixtureRows.insert(db, 11..<31)
        let snapshot = try db.snapshot()
        XCTAssertGreaterThan(snapshot.wal.count, SQLiteWAL.headerBytes, "夹具的 WAL 里得有没并回的帧")

        // 只看主文件：只有并回过的前 10 行。
        let mainOnly = try SQLiteMemoryDatabase(main: snapshot.main, wal: Data())
        XCTAssertEqual(try SQLiteFixtureRows.ids(mainOnly), Array(1..<11))

        let host = await makeHost(snapshot)
        let reader = SQLiteRemoteReader(provider: host, path: path)
        let read = try await reader.read { try SQLiteFixtureRows.ids($0) }
        XCTAssertEqual(read?.value, Array(1..<31))
        XCTAssertEqual(read?.fingerprint.totalBytes, UInt64(snapshot.main.count + snapshot.wal.count))
        let writes = await host.writeAttempts
        XCTAssertEqual(writes, [], "读取器往主机上写了东西")
    }

    /// 库还没并回过一次：主文件只有建表时那一点（或者是空的），表和行都在 WAL 里，而且 WAL 让库长出了很多页。
    func testDatabaseThatGrewEntirelyInTheWAL() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<201, payloadBytes: 600)
        let snapshot = try db.snapshot()
        XCTAssertGreaterThan(snapshot.wal.count, snapshot.main.count * 4)

        let host = await makeHost(snapshot)
        let read = try await SQLiteRemoteReader(provider: host, path: path).read { try SQLiteFixtureRows.ids($0) }
        XCTAssertEqual(read?.value, Array(1..<201))
    }

    /// WAL 末尾写到一半的帧、校验和不对的帧、没提交的事务都不算：读到的是最后一次提交时的样子。
    func testIgnoresTornAndUncommittedFramesAtTheEnd() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<6)
        let committed = try db.snapshot()
        let index = try XCTUnwrap(SQLiteWAL.index(committed.wal))
        XCTAssertNotNil(index.databasePages)
        XCTAssertEqual(index.committedEnd, committed.wal.count)

        // 写到一半的下一帧：一个帧头加半页。
        var torn = committed
        torn.wal.append(Data(repeating: 0xAB, count: SQLiteWAL.frameHeaderBytes + index.pageSize / 2))
        let tornIndex = try XCTUnwrap(SQLiteWAL.index(torn.wal))
        XCTAssertEqual(tornIndex.committedEnd, index.committedEnd)
        XCTAssertEqual(try SQLiteFixtureRows.ids(SQLiteMemoryDatabase(main: torn.main, wal: torn.wal)), Array(1..<6))

        // 下一个事务的帧写完了、最后一帧的内容被改坏（校验和对不上）：这个事务整个不算。
        try SQLiteFixtureRows.insert(db, 6..<9)
        var damaged = try db.snapshot()
        damaged.wal[damaged.wal.count - 10] ^= 0xFF
        XCTAssertEqual(try SQLiteFixtureRows.ids(SQLiteMemoryDatabase(main: damaged.main, wal: damaged.wal)), Array(1..<6))
        XCTAssertEqual(try SQLiteFixtureRows.ids(SQLiteMemoryDatabase(main: damaged.main, wal: try db.snapshot().wal)), Array(1..<9))
    }

    func testWALHeaderWithBadChecksumIsIgnored() throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<4)
        try db.checkpoint()
        try SQLiteFixtureRows.insert(db, 4..<6)
        var snapshot = try db.snapshot()
        snapshot.wal[25] ^= 0x01
        XCTAssertNil(SQLiteWAL.index(snapshot.wal)?.databasePages)
        XCTAssertEqual(try SQLiteFixtureRows.ids(SQLiteMemoryDatabase(main: snapshot.main, wal: snapshot.wal)), Array(1..<4))
        XCTAssertNil(SQLiteWAL.index(Data("not a wal at all, definitely not".utf8)))
    }

    func testNotSQLite() async throws {
        let host = SQLiteTestHost()
        await host.put(path, Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        do {
            _ = try await SQLiteRemoteReader(provider: host, path: path).read { _ in 0 }
            XCTFail("不是 SQLite 的文件也打开了")
        } catch let error as SQLiteRemoteReadError {
            XCTAssertEqual(error, .notSQLite)
            XCTAssertNotNil(error.errorDescription)
        }
        // 太短的也不是。
        await host.put(path, Data("SQLite".utf8))
        do {
            _ = try await SQLiteRemoteReader(provider: host, path: path).read { _ in 0 }
            XCTFail("几个字节的文件也打开了")
        } catch let error as SQLiteRemoteReadError {
            XCTAssertEqual(error, .notSQLite)
        }
    }

    func testTooLargeIsRefusedBeforeReading() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<50, payloadBytes: 200)
        let snapshot = try db.snapshot()
        let host = await makeHost(snapshot)
        let limit = SQLiteReadLimits(maxTotalBytes: snapshot.main.count, attempts: 3)
        do {
            _ = try await SQLiteRemoteReader(provider: host, path: path, limits: limit).read { _ in 0 }
            XCTFail("超过上限还读了")
        } catch let error as SQLiteRemoteReadError {
            XCTAssertEqual(error, .tooLarge(bytes: UInt64(snapshot.main.count + snapshot.wal.count), limit: snapshot.main.count))
        }
        let reads = await host.reads
        XCTAssertTrue(reads.isEmpty, "超限的库不该读任何字节")
    }

    func testMissingFile() async throws {
        let host = SQLiteTestHost()
        await host.put("/home/user/data/other.db", Data())
        do {
            _ = try await SQLiteRemoteReader(provider: host, path: path).read { _ in 0 }
            XCTFail()
        } catch let error as SQLiteRemoteReadError {
            XCTAssertEqual(error, .missing)
        }
        do {
            _ = try await SQLiteRemoteReader(provider: host, path: "/nowhere/store.db").read { _ in 0 }
            XCTFail()
        } catch let error as SQLiteRemoteReadError {
            XCTAssertEqual(error, .missing)
        }
    }

    /// 读主文件的时候 WAL 又长了一截（写的一方提交了新事务）：前后两次列目录对不上，重读一次，读到的是新的。
    func testChangeDuringReadIsDetectedAndRetried() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<6)
        let host = await makeHost(try db.snapshot())
        try SQLiteFixtureRows.insert(db, 6..<9)
        let newer = try db.snapshot()
        let path = self.path
        let fired = SQLiteTestFlag()
        await host.setBeforeRead { host, readPath in
            guard readPath == path, fired.setOnce() else { return }
            await host.install(newer, at: path, mtime: Date(timeIntervalSince1970: 1_800_000_100))
        }
        let reader = SQLiteRemoteReader(provider: host, path: path)
        let read = try await reader.read { try SQLiteFixtureRows.ids($0) }
        XCTAssertEqual(read?.value, Array(1..<9))
        let stats = await reader.lastStats
        XCTAssertEqual(stats.attempts, 2)
    }

    /// 一直在变：试满次数报「对不上」。
    func testKeepsChangingIsReportedAsUnstable() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<6)
        let snapshot = try db.snapshot()
        let host = await makeHost(snapshot)
        let path = self.path
        let counter = SQLiteTestCounter()
        await host.setBeforeRead { host, _ in
            let tick = counter.next()
            await host.install(snapshot, at: path, mtime: Date(timeIntervalSince1970: 1_800_000_000 + Double(tick)))
        }
        do {
            _ = try await SQLiteRemoteReader(provider: host, path: path).read { _ in 0 }
            XCTFail("一直在变的库也读出来了")
        } catch let error as SQLiteRemoteReadError {
            XCTAssertEqual(error, .unstable)
        }
    }

    /// 字节本身坏了（页被写乱）：`quick_check` 不过，重读几次还是坏的，报「读不了」。
    func testCorruptDatabaseIsRetriedThenReported() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<400, payloadBytes: 100)
        try db.checkpoint(truncate: true)
        var snapshot = try db.snapshot()
        XCTAssertTrue(snapshot.wal.isEmpty)
        let pageSize = 4096
        XCTAssertGreaterThan(snapshot.main.count, pageSize * 4)
        // 第 3 页（表的某个 B 树页）整页写成乱码。
        for offset in (pageSize * 2)..<(pageSize * 3) { snapshot.main[offset] = UInt8(truncatingIfNeeded: offset &* 7) }
        let host = await makeHost(snapshot)
        let reader = SQLiteRemoteReader(provider: host, path: path, limits: SQLiteReadLimits(maxTotalBytes: 1 << 26, attempts: 3))
        do {
            _ = try await reader.read { try SQLiteFixtureRows.ids($0) }
            XCTFail("坏的库也读出来了")
        } catch let error as SQLiteRemoteReadError {
            guard case .corrupt = error else { return XCTFail("应该报库坏了，实际 \(error)") }
        }
        let stats = await reader.lastStats
        XCTAssertEqual(stats.attempts, 3)
        // 每次都整份重读，不复用坏的缓存。
        let mainReads = await host.reads.filter { $0.path == path }.count
        XCTAssertEqual(mainReads, 3)
    }

    /// 两个文件都没变：再读一次什么字节都不读（只列一次目录）。
    func testUnchangedDatabaseReadsNothing() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<6)
        let host = await makeHost(try db.snapshot())
        let reader = SQLiteRemoteReader(provider: host, path: path)
        let first = try await reader.read { try SQLiteFixtureRows.ids($0) }
        await host.clearCounters()
        let second = try await reader.read(ifChangedFrom: first?.fingerprint) { try SQLiteFixtureRows.ids($0) }
        XCTAssertNil(second)
        let reads = await host.reads
        let lists = await host.lists
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(lists.count, 1)
    }

    /// 会话开着、WAL 往后长：只读 WAL 头和新长出来的那段，主文件不重读。
    func testGrowingWALIsReadIncrementally() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<301, payloadBytes: 300)
        let host = await makeHost(try db.snapshot())
        let reader = SQLiteRemoteReader(provider: host, path: path)
        let first = try await reader.read { try SQLiteFixtureRows.ids($0) }
        XCTAssertEqual(first?.value.count, 300)

        try SQLiteFixtureRows.insert(db, 301..<304)
        let grown = try db.snapshot()
        // 主文件没动（没并回过），只有 WAL 变长、时间变了。
        await host.put(path + "-wal", grown.wal, mtime: Date(timeIntervalSince1970: 1_800_000_050))
        await host.clearCounters()
        let second = try await reader.read(ifChangedFrom: first?.fingerprint) { try SQLiteFixtureRows.ids($0) }
        XCTAssertEqual(second?.value, Array(1..<304))
        let reads = await host.reads
        XCTAssertFalse(reads.contains { $0.path == path }, "主文件没变却重读了")
        let walBytes = reads.filter { $0.path == path + "-wal" }.reduce(0) { $0 + $1.length }
        XCTAssertLessThan(walBytes, grown.wal.count / 4, "WAL 应该只读新长出来的部分")
    }

    /// WAL 被并回并重置（换了 salt、从头写）：头变了，整份重读两个文件。
    func testResetWALRereadsEverything() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<51, payloadBytes: 200)
        let host = await makeHost(try db.snapshot())
        let reader = SQLiteRemoteReader(provider: host, path: path)
        let first = try await reader.read { try SQLiteFixtureRows.ids($0) }

        try db.checkpoint(truncate: true)
        try SQLiteFixtureRows.insert(db, 51..<56)
        let reset = try db.snapshot()
        // 主文件的修改时间故意不变（同一秒里并回的，列目录看不出来），只靠 WAL 头认出来。
        await host.put(path, reset.main, mtime: Date(timeIntervalSince1970: 1_800_000_000))
        await host.put(path + "-wal", reset.wal, mtime: Date(timeIntervalSince1970: 1_800_000_060))
        let second = try await reader.read(ifChangedFrom: first?.fingerprint) { try SQLiteFixtureRows.ids($0) }
        XCTAssertEqual(second?.value, Array(1..<56))
    }

    /// 查询时 SQLite 报库坏了（读到的状态不一致）也重读。
    func testCorruptionReportedByTheBodyIsRetried() async throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<4)
        let host = await makeHost(try db.snapshot())
        let reader = SQLiteRemoteReader(provider: host, path: path)
        let calls = SQLiteTestCounter()
        let read = try await reader.read { database -> [Int] in
            if calls.next() == 0 { throw SQLiteError(code: 11, message: "database disk image is malformed") }
            return try SQLiteFixtureRows.ids(database)
        }
        XCTAssertEqual(read?.value, [1, 2, 3])
        let stats = await reader.lastStats
        XCTAssertEqual(stats.attempts, 2)
    }

    func testEmptyMainFileOpensAsEmptyDatabase() throws {
        let database = try SQLiteMemoryDatabase(main: Data(), wal: Data())
        var tables = 0
        try database.query("SELECT count(*) FROM sqlite_master") { tables = Int($0.integer(0)) }
        XCTAssertEqual(tables, 0)
        try database.quickCheck()
    }

    /// 内存库是只读的：写语句报错，不会悄悄成功。
    func testDatabaseIsReadOnly() throws {
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<3)
        let snapshot = try db.snapshot()
        let database = try SQLiteMemoryDatabase(main: snapshot.main, wal: snapshot.wal)
        XCTAssertThrowsError(try database.exec("INSERT INTO items (id) VALUES (99)"))
        XCTAssertThrowsError(try database.exec("CREATE TABLE other (x)"))
        XCTAssertEqual(try SQLiteFixtureRows.ids(database), [1, 2])
    }
}
