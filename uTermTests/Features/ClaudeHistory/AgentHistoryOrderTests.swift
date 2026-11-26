import Foundation
import XCTest
@testable import uTerm

/// 侧栏的先后（用户报的：排序不稳定，每次重列都换个样）：同步、备份恢复会把几百份记录的修改时间改成同一刻
/// （实测 548 份落在同一纳秒），只按修改时间排时这些打平的谁先谁后看数据源这一趟列完的先后。
/// 同一时刻的要有固定的先后，重列多少次都一样。
@MainActor
final class AgentHistoryOrderTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "history-order-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        defaults?.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func settle(_ history: AgentHistoryModel) async {
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testSessionsWithTheSameTimeKeepTheirOrderAcrossReloads() async throws {
        let same = Date(timeIntervalSince1970: 1_794_739_693.628)
        let newer = same.addingTimeInterval(60)
        var sessions = (1...6).map { index in
            Session(id: "tied-\(index)", projectID: ClaudeProjectPath.encode("/srv/p\(index % 3)"),
                    resumeDirectory: "/srv/p\(index % 3)", title: "同一刻 \(index)", modifiedAt: same)
        }
        sessions.append(Session(id: "newest", projectID: ClaudeProjectPath.encode("/srv/p0"), resumeDirectory: "/srv/p0",
                                title: "最新", modifiedAt: newer))
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        await settle(history)
        let first = history.visibleFiles.map(\.sessionID)
        XCTAssertEqual(first.count, 7)
        XCTAssertEqual(first.first, "newest", "新的照旧在前")

        await source.reverseStorageOrder()
        await history.reload(showsLoading: false)
        await settle(history)

        XCTAssertEqual(history.visibleFiles.map(\.sessionID), first, "同一刻的几份重列之后不换位置")
    }

    func testOrderIsTotalForTiedSessions() {
        let same = Date(timeIntervalSince1970: 1_794_739_693)
        func file(_ id: String, _ tool: AgentHistoryTool) -> AgentHistorySessionFile {
            let project = AgentHistoryProject(id: "p", path: "/r/p", modifiedAt: same, tool: tool)
            return AgentHistorySessionFile(sessionID: id, project: project, path: "/r/p/\(id).jsonl", size: 1, modifiedAt: same)
        }
        let files = [file("b", .codex), file("a", .claude), file("c", .claude), file("a", .codex)]
        let forward = files.sorted(by: AgentHistorySessionFile.newestFirst).map(\.path)
        let backward = files.reversed().sorted(by: AgentHistorySessionFile.newestFirst).map(\.path)
        XCTAssertEqual(forward, backward, "不管进来的先后，排出来都一样")
    }
}
