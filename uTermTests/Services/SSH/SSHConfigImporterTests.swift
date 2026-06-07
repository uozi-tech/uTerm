import XCTest
@testable import uTerm

final class SSHConfigImporterTests: XCTestCase {

    private func host(_ alias: String, wildcard: Bool = false) -> ParsedSSHHost {
        ParsedSSHHost(alias: alias, hostName: "h", user: "u", port: 22,
                      identityFile: nil, isWildcard: wildcard)
    }

    func testPlanMarksExisting() {
        let rows = SSHConfigImporter.plan(
            [host("web"), host("db")], existingNames: ["db"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.host.alias), ["web", "db"])
        XCTAssertFalse(rows[0].existing)
        XCTAssertTrue(rows[1].existing)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)   // ids 唯一
    }

    func testPlanPassesWildcardThrough() {
        let rows = SSHConfigImporter.plan([host("*.lab", wildcard: true)], existingNames: [])
        XCTAssertTrue(rows[0].host.isWildcard)
        XCTAssertFalse(rows[0].existing)
    }
}
