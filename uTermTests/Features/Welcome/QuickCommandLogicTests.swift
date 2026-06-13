import XCTest
@testable import uTerm

/// 快捷命令的纯逻辑（分组 / 三态 / 摘要 / 运行文案 / 格式化）单测。
/// 非 `@MainActor`：验证这些 helper 确为 `nonisolated`、可在非主线程上下文调用。
final class QuickCommandLogicTests: XCTestCase {

    private func ref(_ name: String, group: String?) -> QuickCommandHostRef {
        QuickCommandHostRef(id: UUID(), name: name, group: group, username: "u", host: "h", port: 22)
    }

    // MARK: grouped

    func testGroupedPreservesOrderAndFoldsEmptyToUngrouped() {
        let a = ref("a", group: "prod")
        let b = ref("b", group: nil)
        let c = ref("c", group: "prod")
        let d = ref("d", group: "")
        let groups = QuickCommandLogic.grouped([a, b, c, d])
        XCTAssertEqual(groups.map(\.group), ["prod", "未分组"])
        XCTAssertEqual(groups[0].hosts.map(\.name), ["a", "c"])
        XCTAssertEqual(groups[1].hosts.map(\.name), ["b", "d"])
    }

    func testGroupedEmptyInput() {
        XCTAssertTrue(QuickCommandLogic.grouped([]).isEmpty)
    }

    // MARK: groupState 三态

    func testGroupStateTriState() {
        let a = ref("a", group: "g")
        let b = ref("b", group: "g")
        let none = QuickCommandLogic.groupState([a, b], selected: [])
        XCTAssertFalse(none.all); XCTAssertFalse(none.some)
        let partial = QuickCommandLogic.groupState([a, b], selected: [a.id])
        XCTAssertFalse(partial.all); XCTAssertTrue(partial.some)
        let full = QuickCommandLogic.groupState([a, b], selected: [a.id, b.id])
        XCTAssertTrue(full.all); XCTAssertTrue(full.some)
    }

    func testGroupStateEmptyGroup() {
        let s = QuickCommandLogic.groupState([], selected: [UUID()])
        XCTAssertFalse(s.all); XCTAssertFalse(s.some)
    }

    // MARK: selectionSummary

    func testSelectionSummaryByCount() {
        let a = ref("alpha", group: nil)
        let b = ref("beta", group: nil)
        let c = ref("gamma", group: nil)
        XCTAssertNil(QuickCommandLogic.selectionSummary([a, b, c], selected: []))
        XCTAssertEqual(QuickCommandLogic.selectionSummary([a, b, c], selected: [a.id]), "alpha")
        XCTAssertEqual(QuickCommandLogic.selectionSummary([a, b, c], selected: [a.id, b.id]), "alpha、beta")
        XCTAssertEqual(QuickCommandLogic.selectionSummary([a, b, c], selected: [a.id, b.id, c.id]), "alpha 等 3 台")
    }

    func testSelectionSummaryFollowsRefOrderNotSelectionOrder() {
        let a = ref("alpha", group: nil)
        let b = ref("beta", group: nil)
        // Set 无序；摘要应按 refs 出现顺序，与插入顺序无关。
        XCTAssertEqual(QuickCommandLogic.selectionSummary([a, b], selected: [b.id, a.id]), "alpha、beta")
    }

    // MARK: runLabel

    func testRunLabelSingleVsMultiVsAI() {
        XCTAssertEqual(QuickCommandLogic.runLabel(serverCount: 1, ai: false), "运行命令")
        XCTAssertEqual(QuickCommandLogic.runLabel(serverCount: 1, ai: true), "运行 · AI 介入")
        XCTAssertEqual(QuickCommandLogic.runLabel(serverCount: 3, ai: false), "并行运行 · 3 台")
        // 多台优先显示并行（与原型一致），即使 AI 开启。
        XCTAssertEqual(QuickCommandLogic.runLabel(serverCount: 3, ai: true), "并行运行 · 3 台")
    }

    // MARK: 格式化

    func testDurationSecondsOneDecimal() {
        XCTAssertEqual(QuickCommandFormat.durationSeconds(1240), "1.2s")
        XCTAssertEqual(QuickCommandFormat.durationSeconds(600), "0.6s")
        XCTAssertEqual(QuickCommandFormat.durationSeconds(0), "0.0s")
        XCTAssertEqual(QuickCommandFormat.durationSeconds(5200), "5.2s")
    }

    // MARK: 值类型 Codable

    func testServerResultCodableRoundTrip() throws {
        let r = QuickCommandServerResult(serverID: UUID(), serverName: "api-prod",
                                         endpoint: "root@1.2.3.4:22", exitCode: 0,
                                         durationMs: 620, ok: true)
        let data = try JSONEncoder().encode([r])
        let back = try JSONDecoder().decode([QuickCommandServerResult].self, from: data)
        XCTAssertEqual(back, [r])
    }

    func testServerResultNilExitCodeRoundTrip() throws {
        let r = QuickCommandServerResult(serverID: UUID(), serverName: "s",
                                         endpoint: "u@h:22", exitCode: nil,
                                         durationMs: 0, ok: false)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(QuickCommandServerResult.self, from: data)
        XCTAssertNil(back.exitCode)
        XCTAssertFalse(back.ok)
    }

    func testAIRecordCodableRoundTrip() throws {
        let ai = QuickCommandAIRecord(summary: "诊断", steps: ["a", "b"])
        let data = try JSONEncoder().encode(ai)
        let back = try JSONDecoder().decode(QuickCommandAIRecord.self, from: data)
        XCTAssertEqual(back, ai)
    }
}
