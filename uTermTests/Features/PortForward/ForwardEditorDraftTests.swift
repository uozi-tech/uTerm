import SwiftData
import XCTest
@testable import uTerm

/// 编辑规则后什么时候要停隧道：只有类型 / 地址 / 端口变了才停。
/// 只改「连接时自动启动」或名称时，在跑的隧道不能被保存顺手关掉。
@MainActor
final class ForwardEditorDraftTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: ForwardingRule.self, configurations: config))
    }

    private func makeRule(in context: ModelContext) throws -> ForwardingRule {
        let rule = ForwardingRule(serverID: UUID(), name: "k3s-to-mac", kind: .remote,
                                  listenHost: "192.168.31.122", listenPort: 18443,
                                  destHost: "127.0.0.1", destPort: 18443,
                                  destLabel: nil, autostart: false, sortOrder: 0)
        context.insert(rule)
        try context.save()
        return rule
    }

    private func draft(from rule: ForwardingRule,
                       name: String? = nil,
                       kind: ForwardKind? = nil,
                       listenHost: String? = nil,
                       listenPort: Int? = nil,
                       destHost: String?? = nil,
                       destPort: Int? = nil,
                       autostart: Bool? = nil) -> ForwardEditorDraft {
        ForwardEditorDraft(editingID: rule.id,
                           name: name ?? rule.name,
                           kind: kind ?? rule.kind,
                           listenHost: listenHost ?? rule.listenHost,
                           listenPort: listenPort ?? rule.listenPort,
                           destHost: destHost ?? rule.destHost,
                           destPort: destPort ?? rule.destPort,
                           autostart: autostart ?? rule.autostart)
    }

    func testTurningOnAutostartSavesItAndKeepsTunnel() throws {
        let context = try makeContext()
        let rule = try makeRule(in: context)

        let rewires = draft(from: rule, autostart: true).commit(to: rule, in: context)

        XCTAssertFalse(rewires)
        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<ForwardingRule>()).first)
        XCTAssertTrue(fetched.autostart)
    }

    func testRenamingKeepsTunnel() throws {
        let context = try makeContext()
        let rule = try makeRule(in: context)

        XCTAssertFalse(draft(from: rule, name: "renamed").commit(to: rule, in: context))
        XCTAssertEqual(rule.name, "renamed")
    }

    func testChangingTunnelConfigRewires() throws {
        let context = try makeContext()
        let rule = try makeRule(in: context)

        XCTAssertTrue(draft(from: rule, kind: .local).rewiresTunnel(of: rule))
        XCTAssertTrue(draft(from: rule, listenHost: "0.0.0.0").rewiresTunnel(of: rule))
        XCTAssertTrue(draft(from: rule, listenPort: 18444).rewiresTunnel(of: rule))
        XCTAssertTrue(draft(from: rule, destHost: .some("10.0.0.1")).rewiresTunnel(of: rule))
        XCTAssertTrue(draft(from: rule, destPort: 3000).rewiresTunnel(of: rule))

        XCTAssertTrue(draft(from: rule, listenPort: 18444, autostart: true).commit(to: rule, in: context))
        XCTAssertEqual(rule.listenPort, 18444)
        XCTAssertTrue(rule.autostart)
    }
}
