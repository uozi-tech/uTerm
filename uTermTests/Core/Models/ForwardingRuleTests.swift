import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class ForwardingRuleTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ForwardingRule.self, configurations: config)
        return ModelContext(container)
    }

    // MARK: ForwardKind 计算属性

    func testForwardKindFlags() {
        XCTAssertEqual(ForwardKind.local.flag, "-L")
        XCTAssertEqual(ForwardKind.remote.flag, "-R")
        XCTAssertEqual(ForwardKind.dynamic.flag, "-D")
    }

    func testForwardKindReverseOnlyRemote() {
        XCTAssertFalse(ForwardKind.local.reverse)
        XCTAssertTrue(ForwardKind.remote.reverse)
        XCTAssertFalse(ForwardKind.dynamic.reverse)
    }

    func testForwardKindNeedsDestExceptDynamic() {
        XCTAssertTrue(ForwardKind.local.needsDest)
        XCTAssertTrue(ForwardKind.remote.needsDest)
        XCTAssertFalse(ForwardKind.dynamic.needsDest)
    }

    func testForwardKindDstLabelNilForDynamic() {
        XCTAssertNotNil(ForwardKind.local.dstLabel)
        XCTAssertNotNil(ForwardKind.remote.dstLabel)
        XCTAssertNil(ForwardKind.dynamic.dstLabel)
    }

    func testForwardKindCaseIterableAllThree() {
        XCTAssertEqual(ForwardKind.allCases, [.local, .remote, .dynamic])
    }

    func testForwardKindRawValues() {
        // rawValue 用于 CloudKit 持久化，重命名 case 会导致历史数据错乱，故此处明确锁定。
        XCTAssertEqual(ForwardKind.local.rawValue, "local")
        XCTAssertEqual(ForwardKind.remote.rawValue, "remote")
        XCTAssertEqual(ForwardKind.dynamic.rawValue, "dynamic")
    }

    // MARK: kind ↔ typeRaw 映射

    func testKindGetterDefaultsToLocalOnBadRaw() {
        let rule = ForwardingRule()
        rule.typeRaw = "garbage"
        XCTAssertEqual(rule.kind, .local)
    }

    func testKindSetterWritesTypeRaw() {
        let rule = ForwardingRule()
        rule.kind = .dynamic
        XCTAssertEqual(rule.typeRaw, "dynamic")
        XCTAssertEqual(rule.kind, .dynamic)
    }

    // MARK: convenience init 设满全部字段

    func testConvenienceInitSetsEveryField() {
        let sid = UUID()
        let rule = ForwardingRule(serverID: sid, name: "web", kind: .remote,
                                  listenHost: "0.0.0.0", listenPort: 8080,
                                  destHost: "localhost", destPort: 3000,
                                  destLabel: "本地 Web", autostart: true, sortOrder: 4)
        XCTAssertEqual(rule.serverID, sid)
        XCTAssertEqual(rule.name, "web")
        XCTAssertEqual(rule.kind, .remote)
        XCTAssertEqual(rule.typeRaw, "remote")
        XCTAssertEqual(rule.listenHost, "0.0.0.0")
        XCTAssertEqual(rule.listenPort, 8080)
        XCTAssertEqual(rule.destHost, "localhost")
        XCTAssertEqual(rule.destPort, 3000)
        XCTAssertEqual(rule.destLabel, "本地 Web")
        XCTAssertTrue(rule.autostart)
        XCTAssertEqual(rule.sortOrder, 4)
    }

    // MARK: snapshot

    func testSnapshotMirrorsRule() {
        let sid = UUID()
        let rule = ForwardingRule(serverID: sid, name: "db", kind: .local,
                                  listenHost: "127.0.0.1", listenPort: 5432,
                                  destHost: "10.0.0.5", destPort: 5432,
                                  destLabel: nil, autostart: false, sortOrder: 0)
        let snap = rule.snapshot
        // sortOrder 和 destLabel 有意不带入 snapshot（纯 UI/展示字段，不影响转发逻辑）。
        XCTAssertEqual(snap.id, rule.id)
        XCTAssertEqual(snap.serverID, sid)
        XCTAssertEqual(snap.name, "db")
        XCTAssertEqual(snap.kind, .local)
        XCTAssertEqual(snap.listenHost, "127.0.0.1")
        XCTAssertEqual(snap.listenPort, 5432)
        XCTAssertEqual(snap.destHost, "10.0.0.5")
        XCTAssertEqual(snap.destPort, 5432)
        XCTAssertFalse(snap.autostart)
    }

    // MARK: SwiftData 持久化往返

    func testInsertFetchRoundTrip() throws {
        let ctx = try makeContext()
        let sid = UUID()
        ctx.insert(ForwardingRule(serverID: sid, name: "socks", kind: .dynamic,
                                  listenHost: "127.0.0.1", listenPort: 1080,
                                  destHost: nil, destPort: 0,
                                  destLabel: nil, autostart: true, sortOrder: 2))
        let all = try ctx.fetch(FetchDescriptor<ForwardingRule>())
        XCTAssertEqual(all.count, 1)
        let r = try XCTUnwrap(all.first)
        XCTAssertEqual(r.name, "socks")
        XCTAssertEqual(r.kind, .dynamic)
        XCTAssertNil(r.destHost)
        XCTAssertEqual(r.serverID, sid)
        XCTAssertTrue(r.autostart)
        XCTAssertEqual(r.sortOrder, 2)
        XCTAssertNotNil(r.createdAt)
    }
}
