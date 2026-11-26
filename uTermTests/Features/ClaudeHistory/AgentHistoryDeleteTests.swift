import Foundation
import XCTest
@testable import uTerm

/// 历史会话的「删除会话」（用户报的：历史消息删不掉）：删的是主机上的记录，删掉后列表、置顶、选中、搜索结果一起跟上；
/// 删不掉时列表不动；会话存在共享数据库里的工具（Antigravity）不出这一项。
@MainActor
final class AgentHistoryDeleteTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "history-delete-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        defaults?.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func sessions(_ ids: [String]) -> [Session] {
        let now = Date()
        return ids.enumerated().map { index, id in
            Session(id: id, projectID: ClaudeProjectPath.encode("/srv/shop"), resumeDirectory: "/srv/shop",
                    title: "会话 \(id)", modifiedAt: now.addingTimeInterval(-TimeInterval(index * 60)))
        }
    }

    private func start(_ source: any AgentHistorySource) async -> AgentHistoryModel {
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
        return history
    }

    // MARK: 模型

    func testDeletedSessionLeavesListPinsAndSelection() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions(["a", "b", "c"]))
        let history = await start(source)
        let target = try XCTUnwrap(history.visibleFiles.first { $0.sessionID == "b" })
        history.pins?.toggle(target)
        history.select(target)
        XCTAssertEqual(history.pinnedFiles.map(\.sessionID), ["b"])

        try await history.delete(target)

        let deleted = await source.deleted
        XCTAssertEqual(deleted, ["b"], "删的是主机上的那一份")
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), ["a", "c"], "列表里不等重列就没了")
        XCTAssertNil(history.selectedFile, "正开着的关掉")
        XCTAssertNil(history.transcript)
        XCTAssertFalse(history.pins?.isPinned(target) ?? true, "置顶里也拿掉")
        XCTAssertTrue(history.pinnedFiles.isEmpty)

        await history.reload()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), ["a", "c"], "重列之后也不回来")
    }

    func testFailedDeleteKeepsTheList() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions(["a", "b"]))
        await source.setDeleteError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        let history = await start(source)
        let target = try XCTUnwrap(history.visibleFiles.first { $0.sessionID == "a" })
        history.pins?.toggle(target)

        do {
            try await history.delete(target)
            XCTFail("删不掉要报出来")
        } catch {}

        XCTAssertEqual(history.visibleFiles.map(\.sessionID), ["a", "b"], "删不掉列表不动")
        XCTAssertTrue(history.pins?.isPinned(target) ?? false, "置顶也还在")
    }

    func testToolsThatShareADatabaseCannotDelete() async throws {
        let claude = AgentHistoryFakeSource(tool: .claude, sessions: sessions(["a"]))
        let antigravity = AgentHistoryFakeSource(tool: .antigravity, sessions: [
            Session(id: "chat", projectID: "/srv/shop", projectDirectory: "/srv/shop", resumeDirectory: "/srv/shop",
                    title: "Antigravity 的会话", modifiedAt: Date()),
        ], supportsDelete: false)
        let history = await start(AgentHistoryCompositeSource([claude, antigravity]))
        let claudeFile = try XCTUnwrap(history.visibleFiles.first { $0.tool == .claude })
        let antigravityFile = try XCTUnwrap(history.visibleFiles.first { $0.tool == .antigravity })
        XCTAssertTrue(history.canDelete(claudeFile))
        XCTAssertFalse(history.canDelete(antigravityFile), "Antigravity 的会话在共享的数据库里，不能单独删")
        do {
            try await history.delete(antigravityFile)
            XCTFail("不能删的工具要拒绝")
        } catch {}
        let deleted = await antigravity.deleted
        XCTAssertTrue(deleted.isEmpty)
    }

    // MARK: Claude Code 的记录

    private static let projectDirectory = "/home/user/.claude/projects/-srv-shop"

    func testClaudeDeleteRemovesTheRecordAndItsCompanionDirectory() async throws {
        let host = SQLiteTestHost()
        await host.setAllowsRemoval(true)
        let record = Self.projectDirectory + "/s1.jsonl"
        await host.put(record, ClaudeFixture.file([ClaudeFixture.userText("你好", cwd: "/srv/shop")]))
        await host.put(Self.projectDirectory + "/s1/subagents/agent-x.jsonl", Data("{}\n".utf8))
        await host.put(Self.projectDirectory + "/s1/tool-results/r.txt", Data("out".utf8))
        await host.put(Self.projectDirectory + "/s2.jsonl", Data("{}\n".utf8))
        let source = ClaudeHistorySource(provider: host, home: "/home/user")

        try await source.delete(file(record, id: "s1"))

        let removed = await host.removed
        XCTAssertEqual(removed.first, record, "主记录先删")
        XCTAssertTrue(removed.contains(Self.projectDirectory + "/s1/subagents/agent-x.jsonl"), "子代理的记录一起删")
        XCTAssertTrue(removed.contains(Self.projectDirectory + "/s1"), "旁边同名的目录删掉")
        let other = await host.data(Self.projectDirectory + "/s2.jsonl")
        XCTAssertNotNil(other, "别的会话不碰")
        let writes = await host.writeAttempts
        XCTAssertTrue(writes.isEmpty, "除了删，不往主机上写别的")
    }

    func testClaudeDeleteWithoutCompanionDirectory() async throws {
        let host = SQLiteTestHost()
        await host.setAllowsRemoval(true)
        let record = Self.projectDirectory + "/s1.jsonl"
        await host.put(record, Data("{}\n".utf8))
        let source = ClaudeHistorySource(provider: host, home: "/home/user")

        try await source.delete(file(record, id: "s1"))

        let removed = await host.removed
        XCTAssertEqual(removed, [record], "没派过子代理的只有那一份")
    }

    private func file(_ path: String, id: String) -> AgentHistorySessionFile {
        let project = AgentHistoryProject(id: "-srv-shop", path: Self.projectDirectory, modifiedAt: nil)
        return AgentHistorySessionFile(sessionID: id, project: project, path: path, size: 4, modifiedAt: Date())
    }

    // MARK: 菜单

    func testMenuItemsForAHistoryRow() {
        typealias Item = AgentHistorySessionMenuItem
        XCTAssertEqual(Item.items(hasRecord: true, canResume: true, canPin: true, isPinned: false, isRunning: false,
                                  canDelete: true), [.resume, .pin(isPinned: false), .copyTitle, .copySessionID, .delete])
        XCTAssertEqual(Item.items(hasRecord: true, canResume: false, canPin: false, isPinned: false, isRunning: false,
                                  canDelete: false), [.copyTitle, .copySessionID], "继续不了、不能置顶、不能删的只剩拷贝")
        XCTAssertEqual(Item.items(hasRecord: true, canResume: true, canPin: true, isPinned: true, isRunning: true,
                                  canDelete: true), [.pin(isPinned: true), .copyTitle, .endSession], "跑着的会话不能删")
        XCTAssertTrue(Item.delete.isDestructive)
        XCTAssertFalse(Item.copySessionID.isDestructive)
    }
}
