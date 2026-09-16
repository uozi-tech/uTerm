import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class ForwardingRuleStoreTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ForwardingRule.self, configurations: config)
        return ModelContext(container)
    }

    private func rule(_ serverID: UUID, name: String, sortOrder: Int) -> ForwardingRule {
        ForwardingRule(serverID: serverID, name: name, kind: .local,
                       listenHost: "127.0.0.1", listenPort: 8080,
                       destHost: "localhost", destPort: 80,
                       destLabel: nil, autostart: false, sortOrder: sortOrder)
    }

    // MARK: rules(forServer:) —— 过滤 + 排序

    func testRulesFilterByServerAndSortBySortOrder() throws {
        let ctx = try makeContext()
        let a = UUID(), b = UUID()
        let store = ForwardingRuleStore(context: ctx)
        store.add(rule(a, name: "a2", sortOrder: 2))
        store.add(rule(a, name: "a1", sortOrder: 1))   // 故意乱序插入
        store.add(rule(b, name: "b0", sortOrder: 0))

        let aRules = store.rules(forServer: a)
        XCTAssertEqual(aRules.map(\.name), ["a1", "a2"])   // 按 sortOrder 升序

        let bRules = store.rules(forServer: b)
        XCTAssertEqual(bRules.map(\.name), ["b0"])         // 只含 serverB
    }

    func testRulesForUnknownServerIsEmpty() throws {
        let ctx = try makeContext()
        let store = ForwardingRuleStore(context: ctx)
        store.add(rule(UUID(), name: "x", sortOrder: 0))
        XCTAssertTrue(store.rules(forServer: UUID()).isEmpty)
    }

    // MARK: delete

    func testDeleteRemovesSingleRule() throws {
        let ctx = try makeContext()
        let a = UUID()
        let store = ForwardingRuleStore(context: ctx)
        let r1 = rule(a, name: "r1", sortOrder: 0)
        let r2 = rule(a, name: "r2", sortOrder: 1)
        store.add(r1); store.add(r2)
        store.delete(r1)
        XCTAssertEqual(store.rules(forServer: a).map(\.name), ["r2"])
    }

    // MARK: deleteAll(forServer:) —— 孤儿清理

    func testDeleteAllRemovesOnlyThatServer() throws {
        let ctx = try makeContext()
        let a = UUID(), b = UUID()
        let store = ForwardingRuleStore(context: ctx)
        store.add(rule(a, name: "a1", sortOrder: 0))
        store.add(rule(a, name: "a2", sortOrder: 1))
        store.add(rule(b, name: "b1", sortOrder: 0))

        store.deleteAll(forServer: a)
        XCTAssertTrue(store.rules(forServer: a).isEmpty)
        XCTAssertEqual(store.rules(forServer: b).map(\.name), ["b1"])
    }

    func testDeleteAllNoOpWhenServerHasNoRules() throws {
        let ctx = try makeContext()
        let b = UUID()
        let store = ForwardingRuleStore(context: ctx)
        store.add(rule(b, name: "b1", sortOrder: 0))
        store.deleteAll(forServer: UUID())   // 无该 server 的规则
        XCTAssertEqual(store.rules(forServer: b).count, 1)
    }

    // MARK: nextSortOrder —— 递增

    func testNextSortOrderEmptyServerIsZero() throws {
        let ctx = try makeContext()
        let store = ForwardingRuleStore(context: ctx)
        XCTAssertEqual(store.nextSortOrder(forServer: UUID()), 0)
    }

    func testNextSortOrderIncrementsPastMax() throws {
        let ctx = try makeContext()
        let a = UUID()
        let store = ForwardingRuleStore(context: ctx)
        store.add(rule(a, name: "a1", sortOrder: 0))
        store.add(rule(a, name: "a2", sortOrder: 5))   // 非连续
        XCTAssertEqual(store.nextSortOrder(forServer: a), 6)   // max(5)+1
    }

    func testNextSortOrderIsPerServer() throws {
        let ctx = try makeContext()
        let a = UUID(), b = UUID()
        let store = ForwardingRuleStore(context: ctx)
        store.add(rule(a, name: "a1", sortOrder: 9))
        XCTAssertEqual(store.nextSortOrder(forServer: b), 0)   // serverB 独立计数
    }
}
