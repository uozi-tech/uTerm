import XCTest
@testable import uTerm

/// 交接 URL 的格式另一半在 uTable 的 `UTermSQLiteOpenRequest`，两边的测试钉的是同一个形状。
final class UTableHandoffTests: XCTestCase {
    private let hostID = UUID(uuidString: "0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0")!

    func testURLCarriesOnlyHostIDAndPath() throws {
        let url = UTableHandoff.url(hostID: hostID, remotePath: "/root/projects/cdn_cert/cert.db")
        XCTAssertEqual(url.scheme, "utable")
        XCTAssertEqual(url.host, "open-sqlite")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["host", "path"])
        XCTAssertEqual(items.first { $0.name == "host" }?.value, hostID.uuidString)
        XCTAssertEqual(items.first { $0.name == "path" }?.value, "/root/projects/cdn_cert/cert.db")
    }

    func testPathWithReservedCharactersRoundTrips() throws {
        let path = "/data/我的 库/a&b=c?#.sqlite"
        let url = UTableHandoff.url(hostID: hostID, remotePath: path)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "path" }?.value, path)
    }
}
