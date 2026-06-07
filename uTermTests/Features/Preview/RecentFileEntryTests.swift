import XCTest
@testable import uTerm

final class RecentFileEntryTests: XCTestCase {

    func test_codable_roundtrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let e = RecentFileEntry(remotePath: "/etc/nginx.conf",
                                kindTag: "code:nginx",
                                lastOpenedAt: now)
        let data = try JSONEncoder().encode(e)
        let decoded = try JSONDecoder().decode(RecentFileEntry.self, from: data)
        XCTAssertEqual(decoded, e)
    }

    func test_idIsRemotePath_forUniqueness() {
        let a = RecentFileEntry(remotePath: "/a", kindTag: "x", lastOpenedAt: .now)
        let b = RecentFileEntry(remotePath: "/a", kindTag: "y", lastOpenedAt: .now)
        XCTAssertEqual(a.id, b.id)   // 路径相同则 id 相同（同条目）
    }
}
