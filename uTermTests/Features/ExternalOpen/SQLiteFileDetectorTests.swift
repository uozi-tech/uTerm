import XCTest
@testable import uTerm

final class SQLiteFileDetectorTests: XCTestCase {
    func testCandidateByExtensionIgnoresCase() {
        for path in ["/root/cert.db", "/a/b.SQLite", "/x.sqlite3", "/x.db3", "/x.s3db", "/x.sl3"] {
            XCTAssertTrue(SQLiteFileDetector.isCandidate(path: path), path)
        }
        for path in ["/etc/nginx.conf", "/x.db-wal", "/x.db.bak", "/dbfile", "/x.mdb"] {
            XCTAssertFalse(SQLiteFileDetector.isCandidate(path: path), path)
        }
    }

    func testHeaderMatchesSQLite3Only() {
        var sqlite = Data("SQLite format 3\u{0}".utf8)
        XCTAssertTrue(SQLiteFileDetector.hasSQLiteHeader(sqlite))
        sqlite.append(contentsOf: [0x10, 0x00, 0x01, 0x01])
        XCTAssertTrue(SQLiteFileDetector.hasSQLiteHeader(sqlite), "文件头之后还有字节也算")

        XCTAssertFalse(SQLiteFileDetector.hasSQLiteHeader(Data("SQLite format 3".utf8)), "少了结尾的 \\0")
        XCTAssertFalse(SQLiteFileDetector.hasSQLiteHeader(Data()))
        // BerkeleyDB hash 魔数，常见的 `.db` 冒名者。
        XCTAssertFalse(SQLiteFileDetector.hasSQLiteHeader(Data([0, 0, 0, 0, 0x61, 0x15, 0x06, 0,
                                                              0, 0, 0, 0, 0, 0, 0, 0])))
    }

    func testCompanionPathsAreWALAndRollbackJournal() {
        XCTAssertEqual(SQLiteFileDetector.companionPaths(for: "/srv/cert.db"),
                       ["/srv/cert.db-wal", "/srv/cert.db-journal"])
    }
}
