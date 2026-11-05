import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class ServerProfileStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

    // MARK: - delete

    func testDeleteCleansSecretsRulesAndJumpHostReferences() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerProfile.self, ForwardingRule.self, configurations: config)
        let context = ModelContext(container)
        let keychain = KeychainStore(service: "com.uozi.uTerm.tests.serverprofilestore")

        let bastion = profile("bastion", group: nil, sortOrder: 0)
        let behind = profile("behind", group: nil, sortOrder: 1)
        let other = profile("other", group: nil, sortOrder: 2)
        let upstream = profile("upstream", group: nil, sortOrder: 3)
        behind.jumpHost = bastion
        bastion.jumpHost = upstream
        [bastion, behind, other, upstream].forEach { context.insert($0) }
        let ruleOfBastion = ForwardingRule()
        ruleOfBastion.serverID = bastion.id
        let ruleOfOther = ForwardingRule()
        ruleOfOther.serverID = other.id
        context.insert(ruleOfBastion)
        context.insert(ruleOfOther)
        try context.save()

        let bastionID = bastion.id
        let upstreamID = upstream.id
        defer {
            for id in [bastionID, upstreamID] {
                for kind in [SecretKind.password, .passphrase, .privateKey] {
                    try? keychain.delete(profileID: id, kind: kind)
                }
            }
        }
        for kind in [SecretKind.password, .passphrase, .privateKey] {
            try keychain.save("secret-\(kind.rawValue)", profileID: bastionID, kind: kind)
        }
        try keychain.save("upstream-pw", profileID: upstreamID, kind: .password)

        ServerProfileStore(context: context).delete(bastion, keychain: keychain)

        for kind in [SecretKind.password, .passphrase, .privateKey] {
            XCTAssertNil(try keychain.load(profileID: bastionID, kind: kind), "\(kind) 应被删")
        }
        // 被删主机自己的跳板机是一台正常服务器：它与它的密码都要保留。
        XCTAssertEqual(try keychain.load(profileID: upstreamID, kind: .password), "upstream-pw")
        XCTAssertNil(behind.jumpHost, "指向被删主机的跳板引用应置空")
        let names = try context.fetch(FetchDescriptor<ServerProfile>()).map(\.name).sorted()
        XCTAssertEqual(names, ["behind", "other", "upstream"])
        let rules = try context.fetch(FetchDescriptor<ForwardingRule>())
        XCTAssertEqual(rules.map(\.serverID), [other.id])
        XCTAssertFalse(context.hasChanges)
    }
}
