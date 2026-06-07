import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class ServerProfileStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ServerProfile.self, configurations: config)
        return ModelContext(container)
    }

    private func profile(_ name: String, group: String?, sortOrder: Int) -> ServerProfile {
        let profile = ServerProfile()
        profile.name = name
        profile.host = "host-\(name)"
        profile.username = "root"
        profile.group = group
        profile.sortOrder = sortOrder
        return profile
    }

    func testNextSortOrderAppendsAfterExistingMax() throws {
        let context = try makeContext()
        context.insert(profile("a", group: nil, sortOrder: 2))
        context.insert(profile("b", group: "prod", sortOrder: 7))

        XCTAssertEqual(ServerProfileStore(context: context).nextSortOrder(), 8)
    }

    func testReorderVisibleReplacesOnlyFilteredSlotsAndCompactsGlobalOrder() throws {
        let context = try makeContext()
        let a = profile("a", group: nil, sortOrder: 0)
        let b = profile("b", group: "prod", sortOrder: 1)
        let c = profile("c", group: nil, sortOrder: 2)
        let d = profile("d", group: "prod", sortOrder: 3)
        [a, b, c, d].forEach { context.insert($0) }

        ServerProfileStore(context: context).reorderVisible([c, a], within: [a, b, c, d])

        let descriptor = FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\.sortOrder)])
        let reordered = try context.fetch(descriptor)
        XCTAssertEqual(reordered.map(\.name), ["c", "b", "a", "d"])
        XCTAssertEqual(c.sortOrder, 0)
        XCTAssertEqual(b.sortOrder, 1)
        XCTAssertEqual(a.sortOrder, 2)
        XCTAssertEqual(d.sortOrder, 3)
    }
}
