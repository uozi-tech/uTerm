import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class QuickCommandStoreTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: QuickCommand.self, QuickCommandRun.self, configurations: config)
        return ModelContext(container)
    }

    private func result(ok: Bool, code: Int? = 0) -> QuickCommandServerResult {
        QuickCommandServerResult(serverID: UUID(), serverName: "s", endpoint: "u@h:22",
                                 exitCode: code, durationMs: 100, ok: ok)
    }

    // MARK: CRUD

    func testCreateInsertsTrimsAndOrders() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let sid = UUID()
        let cmd = store.create(name: "  重启 Nginx  ", serverIDs: [sid],
                               command: "  systemctl restart nginx  ", aiAssisted: true)
        XCTAssertEqual(cmd.name, "重启 Nginx")
        XCTAssertEqual(cmd.command, "systemctl restart nginx")
        XCTAssertEqual(cmd.serverIDs, [sid])
        XCTAssertTrue(cmd.aiAssisted)
        XCTAssertEqual(cmd.sortOrder, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<QuickCommand>()).count, 1)
    }

    func testNextSortOrderIncrements() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        XCTAssertEqual(store.nextSortOrder(), 0)
        _ = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        XCTAssertEqual(store.nextSortOrder(), 1)
    }

    func testUpdateMutatesEditableFields() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        let newIDs = [UUID(), UUID()]
        store.update(cmd, name: " b ", serverIDs: newIDs, command: " y ", aiAssisted: true)
        XCTAssertEqual(cmd.name, "b")
        XCTAssertEqual(cmd.command, "y")
        XCTAssertEqual(cmd.serverIDs, newIDs)
        XCTAssertTrue(cmd.aiAssisted)
    }

    func testCreateAndUpdatePersistIntentTrimmed() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        // 默认无 intent（向后兼容旧签名）。
        let plain = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        XCTAssertEqual(plain.intent, "")
        // 带 intent 创建：去首尾空白；等效命令可留空。
        let cmd = store.create(name: "n", serverIDs: [UUID()], command: "",
                               intent: "  重启 Nginx 后做健康检查  ", aiAssisted: true)
        XCTAssertEqual(cmd.intent, "重启 Nginx 后做健康检查")
        XCTAssertEqual(cmd.command, "")
        // 更新改写 intent + 清空等效命令。
        store.update(cmd, name: "n", serverIDs: cmd.serverIDs, command: " pm2 reload ",
                     intent: " 只说人话 ", aiAssisted: true)
        XCTAssertEqual(cmd.command, "pm2 reload")
        XCTAssertEqual(cmd.intent, "只说人话")
    }

    func testSetAIAssistedToggles() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        store.setAIAssisted(cmd, true)
        XCTAssertTrue(cmd.aiAssisted)
        store.setAIAssisted(cmd, false)
        XCTAssertFalse(cmd.aiAssisted)
    }

    func testDeleteCascadesOnlyItsRuns() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        let other = store.create(name: "b", serverIDs: [UUID()], command: "y", aiAssisted: false)
        store.recordRun(commandID: cmd.id, startedAt: Date(), durationMs: 100, results: [result(ok: true)])
        store.recordRun(commandID: cmd.id, startedAt: Date(), durationMs: 100, results: [result(ok: true)])
        store.recordRun(commandID: other.id, startedAt: Date(), durationMs: 50, results: [])

        store.delete(cmd)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<QuickCommand>()).count, 1)
        let runs = try ctx.fetch(FetchDescriptor<QuickCommandRun>())
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.commandID, other.id)
    }

    // MARK: 执行日志

    func testRecordRunUpdatesLastRunAndCount() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        XCTAssertNil(cmd.lastRunAt)
        XCTAssertEqual(cmd.runCount, 0)
        let at = Date()
        store.recordRun(commandID: cmd.id, startedAt: at, durationMs: 100, results: [result(ok: true)])
        XCTAssertEqual(cmd.lastRunAt, at)
        XCTAssertEqual(cmd.runCount, 1)
        store.recordRun(commandID: cmd.id, startedAt: Date(), durationMs: 100, results: [result(ok: true)])
        XCTAssertEqual(cmd.runCount, 2)
    }

    func testRunsForReturnsRecentSortedDescending() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        let now = Date()
        store.recordRun(commandID: cmd.id, startedAt: now.addingTimeInterval(-3600), durationMs: 1, results: [])
        store.recordRun(commandID: cmd.id, startedAt: now.addingTimeInterval(-60), durationMs: 1, results: [])
        let runs = store.runs(for: cmd.id, now: now)
        XCTAssertEqual(runs.count, 2)
        XCTAssertGreaterThan(runs[0].startedAt, runs[1].startedAt)
    }

    func testRunsForExcludesExpiredAndOtherCommands() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        let other = store.create(name: "b", serverIDs: [UUID()], command: "y", aiAssisted: false)
        let now = Date()
        store.recordRun(commandID: cmd.id, startedAt: now.addingTimeInterval(-31 * 86_400), durationMs: 1, results: [])
        store.recordRun(commandID: cmd.id, startedAt: now.addingTimeInterval(-86_400), durationMs: 1, results: [])
        store.recordRun(commandID: other.id, startedAt: now, durationMs: 1, results: [])
        let runs = store.runs(for: cmd.id, now: now)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.commandID, cmd.id)
    }

    func testPruneDeletesExpiredKeepsRecent() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        let now = Date()
        store.recordRun(commandID: cmd.id, startedAt: now.addingTimeInterval(-31 * 86_400), durationMs: 1, results: [])
        store.recordRun(commandID: cmd.id, startedAt: now.addingTimeInterval(-29 * 86_400), durationMs: 1, results: [])
        store.pruneExpiredRuns(now: now)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<QuickCommandRun>()).count, 1)
    }

    func testExpiryCutoffIs30DaysBack() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(QuickCommandStore.expiryCutoff(now: now),
                       now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(QuickCommandStore.retentionDays, 30)
    }

    // MARK: 嵌套结构 JSON 往返

    func testRunResultsAndAIRecordRoundTripThroughJSON() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: true)
        let results = [result(ok: true, code: 0), result(ok: false, code: 1)]
        let ai = QuickCommandAIRecord(summary: "两台均 200", steps: ["restart", "healthz 200"])
        let run = store.recordRun(commandID: cmd.id, startedAt: Date(), durationMs: 1240,
                                  results: results, aiRecord: ai)
        // 重新取出，确认从 JSON 解回。
        let fetched = try ctx.fetch(FetchDescriptor<QuickCommandRun>()).first { $0.id == run.id }
        XCTAssertEqual(fetched?.results.count, 2)
        XCTAssertEqual(fetched?.failureCount, 1)
        XCTAssertEqual(fetched?.allSucceeded, false)
        XCTAssertEqual(fetched?.aiRecord?.summary, "两台均 200")
        XCTAssertEqual(fetched?.aiRecord?.steps, ["restart", "healthz 200"])
    }

    func testRecordInvocationBumpsMetaWithoutLoggingRun() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: true)
        let at = Date()
        store.recordInvocation(cmd, at: at)
        XCTAssertEqual(cmd.lastRunAt, at)
        XCTAssertEqual(cmd.runCount, 1)
        // 不写执行日志（AI 命令在 Agent 里交互执行，无逐台退出码）。
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<QuickCommandRun>()).isEmpty)
    }

    // MARK: 目标解析助手

    func testResolveTargetsNameFallbackAndDeletedPlaceholder() {
        let p = ServerProfile()
        p.name = "api-prod"; p.host = "1.2.3.4"; p.username = "root"; p.port = 2222
        let blank = ServerProfile()
        blank.name = ""; blank.host = "10.0.0.1"; blank.username = "u"; blank.port = 22
        let missing = UUID()

        let resolved = QuickCommandTargets.resolve([p.id, blank.id, missing], in: [p, blank])
        XCTAssertEqual(resolved[0].name, "api-prod")
        XCTAssertEqual(resolved[0].endpoint, "root@1.2.3.4:2222")
        XCTAssertTrue(resolved[0].exists)
        XCTAssertEqual(resolved[1].name, "10.0.0.1")          // 名为空 → 回退主机名
        XCTAssertTrue(resolved[1].exists)
        XCTAssertEqual(resolved[2].name, "已删除服务器")        // 未找到 → 占位
        XCTAssertNil(resolved[2].endpoint)
        XCTAssertFalse(resolved[2].exists)
    }

    func testRunWithoutAIRecordDecodesNil() throws {
        let ctx = try makeContext()
        let store = QuickCommandStore(context: ctx)
        let cmd = store.create(name: "a", serverIDs: [UUID()], command: "x", aiAssisted: false)
        let run = store.recordRun(commandID: cmd.id, startedAt: Date(), durationMs: 10,
                                  results: [result(ok: true)])
        XCTAssertNil(run.aiRecord)
        XCTAssertTrue(run.allSucceeded)
    }
}
