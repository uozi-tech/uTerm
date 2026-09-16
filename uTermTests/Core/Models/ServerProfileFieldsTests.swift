import XCTest
import SwiftData
@testable import uTerm

final class ServerProfileFieldsTests: XCTestCase {

    // MARK: - test_defaultValues

    /// 新建实例时，group 为 nil，isPinned 为 false，lastConnectedAt 为 nil。
    func test_defaultValues() {
        let p = ServerProfile()
        XCTAssertNil(p.group)
        XCTAssertFalse(p.isPinned)
        XCTAssertNil(p.lastConnectedAt)
    }

    // MARK: - test_settingFields_persists

    /// 对三个字段赋值后，再次读取返回相同值。
    func test_settingFields_persists() {
        let p = ServerProfile()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        p.group = "production"
        p.isPinned = true
        p.lastConnectedAt = now

        XCTAssertEqual(p.group, "production")
        XCTAssertTrue(p.isPinned)
        XCTAssertEqual(p.lastConnectedAt, now)
    }

    // MARK: - test_schemaContainerLoads

    /// ModelContainer 能以内存配置加载 ServerProfile schema，
    /// 并完整完成插入 → 保存 → 查询的往返。
    func test_schemaContainerLoads() throws {
        let config = ModelConfiguration("test-\(UUID())", isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerProfile.self, configurations: config)
        let ctx = ModelContext(container)

        let p = ServerProfile()
        p.name = "prod-web"
        p.host = "web.example.com"
        p.group = "production"
        p.isPinned = true
        p.lastConnectedAt = Date(timeIntervalSince1970: 1_700_000_000)

        ctx.insert(p)
        try ctx.save()

        let results = try ctx.fetch(FetchDescriptor<ServerProfile>())
        XCTAssertEqual(results.count, 1)
        let fetched = try XCTUnwrap(results.first)
        XCTAssertEqual(fetched.name, "prod-web")
        XCTAssertEqual(fetched.group, "production")
        XCTAssertTrue(fetched.isPinned)
        XCTAssertEqual(fetched.lastConnectedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }
}
