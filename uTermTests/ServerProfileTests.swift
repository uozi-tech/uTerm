import XCTest
import SwiftData
@testable import uTerm

final class ServerProfileTests: XCTestCase {
    /// 内存版 ModelContainer —— 不触碰磁盘 / CloudKit。
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ServerProfile.self, configurations: config)
        return ModelContext(container)
    }

    func testDefaultsAreSane() {
        let p = ServerProfile()
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.authMethod, .password)
        XCTAssertNil(p.jumpHost)
    }

    func testAuthMethodRoundTripsThroughRawValue() {
        let p = ServerProfile()
        p.authMethod = .privateKey
        XCTAssertEqual(p.authMethodRaw, "privateKey")
        XCTAssertEqual(p.authMethod, .privateKey)
    }

    func testInsertAndFetch() throws {
        let ctx = try makeContext()
        let p = ServerProfile()
        p.name = "cluster-main"
        p.host = "cluster-main.example.com"
        p.username = "root"
        p.port = 2222
        p.authMethod = .privateKey
        let originalID = p.id
        ctx.insert(p)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<ServerProfile>())
        XCTAssertEqual(fetched.count, 1)
        let f = try XCTUnwrap(fetched.first)
        XCTAssertEqual(f.name, "cluster-main")
        XCTAssertEqual(f.host, "cluster-main.example.com")
        XCTAssertEqual(f.username, "root")
        XCTAssertEqual(f.port, 2222)
        XCTAssertEqual(f.authMethod, .privateKey)
        XCTAssertEqual(f.id, originalID)
    }

    func testSortOrderAndCreatedAtPersist() throws {
        let ctx = try makeContext()
        let p = ServerProfile()
        p.name = "sort-test"
        p.sortOrder = 5
        ctx.insert(p)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<ServerProfile>())
        let f = try XCTUnwrap(fetched.first)
        XCTAssertEqual(f.sortOrder, 5)
        XCTAssertGreaterThan(f.createdAt.timeIntervalSince1970, 0)
    }

    func testJumpHostRelationship() throws {
        let ctx = try makeContext()
        let bastion = ServerProfile()
        bastion.name = "bastion"
        let target = ServerProfile()
        target.name = "internal-db"
        target.jumpHost = bastion
        ctx.insert(target)
        try ctx.save()

        let target2 = try ctx.fetch(
            FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.name == "internal-db" })
        ).first
        XCTAssertEqual(target2?.jumpHost?.name, "bastion")
    }
}
