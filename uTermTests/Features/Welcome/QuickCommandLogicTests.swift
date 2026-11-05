import XCTest
import UDesignKit
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

    // MARK: AI 意图文案 / Agent 预填

    func testAiIntentTextPrefersIntentElseFallback() {
        XCTAssertEqual(QuickCommandLogic.aiIntentText(name: "重启 Nginx", intent: "  做一次健康检查  "),
                       "做一次健康检查")
        let fallback = QuickCommandLogic.aiIntentText(name: "重启 Nginx", intent: "   ")
        XCTAssertTrue(fallback.contains("重启 Nginx"))
    }

    func testAgentPrefillIntentThenCommandThenFallback() {
        XCTAssertEqual(QuickCommandLogic.agentPrefill(name: "n", intent: " 意图 ", command: "cmd"), "意图")
        XCTAssertEqual(QuickCommandLogic.agentPrefill(name: "n", intent: "  ", command: " cmd "), "cmd")
        let f = QuickCommandLogic.agentPrefill(name: "清理 Docker", intent: "", command: "")
        XCTAssertTrue(f.contains("清理 Docker"))
    }

    // MARK: isSaveable 校验

    func testIsSaveableNonAIRequiresCommand() {
        XCTAssertTrue(QuickCommandLogic.isSaveable(name: "n", hasServers: true, command: "x", intent: "", ai: false))
        // 非 AI：仅有 intent 不够，命令必填。
        XCTAssertFalse(QuickCommandLogic.isSaveable(name: "n", hasServers: true, command: " ", intent: "i", ai: false))
    }

    func testIsSaveableAIRequiresEitherIntentOrCommand() {
        XCTAssertTrue(QuickCommandLogic.isSaveable(name: "n", hasServers: true, command: "", intent: "i", ai: true))
        XCTAssertTrue(QuickCommandLogic.isSaveable(name: "n", hasServers: true, command: "c", intent: "", ai: true))
        XCTAssertFalse(QuickCommandLogic.isSaveable(name: "n", hasServers: true, command: " ", intent: " ", ai: true))
    }

    func testIsSaveableNeedsNameAndServers() {
        XCTAssertFalse(QuickCommandLogic.isSaveable(name: " ", hasServers: true, command: "x", intent: "", ai: false))
        XCTAssertFalse(QuickCommandLogic.isSaveable(name: "n", hasServers: false, command: "x", intent: "", ai: false))
    }

    // MARK: 格式化

    /// 执行日志的耗时走 `UFormat.duration`：三位有效数字、先舍入再选档。
    func testRunDurationUsesUFormat() {
        XCTAssertEqual(UFormat.duration(milliseconds: 1240), "1.24 s")
        XCTAssertEqual(UFormat.duration(milliseconds: 600), "600 ms")
        XCTAssertEqual(UFormat.duration(milliseconds: 5200), "5.20 s")
        XCTAssertEqual(UFormat.duration(milliseconds: 59_996), "1m 00s")
        XCTAssertEqual(UFormat.duration(milliseconds: 125_300), "2m 05s")
    }

    /// 日志时间戳：今天 / 昨天 / 同年 MM-dd / 跨年带年份；公历 + 24 小时制，与 locale 无关。
    func testLogTimestamp() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var g = Calendar(identifier: .gregorian)
        g.timeZone = tz
        func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            g.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        let now = date(2026, 9, 28, 10, 0)
        XCTAssertEqual(UTermFormat.logTimestamp(date(2026, 9, 28, 9, 5), now: now, timeZone: tz), "今天 09:05")
        XCTAssertEqual(UTermFormat.logTimestamp(date(2026, 9, 27, 23, 59), now: now, timeZone: tz), "昨天 23:59")
        XCTAssertEqual(UTermFormat.logTimestamp(date(2026, 3, 1, 13, 5), now: now, timeZone: tz), "03-01 13:05")
        XCTAssertEqual(UTermFormat.logTimestamp(date(2025, 12, 31, 13, 5), now: now, timeZone: tz), "2025-12-31 13:05")
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

    // MARK: runnable（两端运行入口共用的目标筛选）

    @MainActor
    private func profile(_ name: String, sftpOnly: Bool = false) -> ServerProfile {
        let p = ServerProfile()
        p.name = name; p.host = "\(name).example"; p.username = "u"; p.port = 22
        p.sftpOnly = sftpOnly
        return p
    }

    @MainActor
    func testRunnableKeepsServerIDOrderAndDropsDuplicates() {
        let a = profile("a"), b = profile("b"), c = profile("c")
        let picked = QuickCommandTargets.runnable([c.id, a.id, c.id, b.id], in: [a, b, c])
        XCTAssertEqual(picked.map(\.name), ["c", "a", "b"])
    }

    @MainActor
    func testRunnableSkipsSFTPOnlyAndDeletedHosts() {
        let a = profile("a"), files = profile("files", sftpOnly: true)
        let picked = QuickCommandTargets.runnable([files.id, UUID(), a.id], in: [a, files])
        XCTAssertEqual(picked.map(\.name), ["a"])
        XCTAssertTrue(QuickCommandTargets.runnable([files.id], in: [files]).isEmpty)
        XCTAssertTrue(QuickCommandTargets.runnable([], in: [a]).isEmpty)
    }
}
