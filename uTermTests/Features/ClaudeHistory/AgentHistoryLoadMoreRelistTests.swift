import Foundation
import XCTest
@testable import uTerm

/// 列表底下的「正在读取…」卡住不动（用户报的）：滚到底读下一批的途中，后台重列了一次（慢的工具列完了、并进来），
/// 重列把「要读到多少行」压回当时的行数，这一批就停在半路；底下那一行一直露着、没有变成新视图，不会再叫 `loadMore`。
@MainActor
final class AgentHistoryLoadMoreRelistTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session

    override func setUp() async throws {
        try await super.setUp()
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        try await super.tearDown()
    }

    func testBackgroundRelistDuringLoadMoreKeepsReadingTheBatch() async throws {
        let now = Date()
        let sessions = (0..<80).map { n in
            Session(id: "s\(n)", projectID: ClaudeProjectPath.encode("/srv/shop"), resumeDirectory: "/srv/shop",
                    title: "会话 \(n)", modifiedAt: now.addingTimeInterval(-TimeInterval(n * 60)))
        }
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.visibleFiles.count < 24 { try await Task.sleep(for: .milliseconds(5)) }
        let firstPage = history.visibleFiles.count
        XCTAssertGreaterThanOrEqual(firstPage, 24)

        // 滚到底读下一批；这一批读得慢，读的途中后台重列了一次。
        await source.holdMetadata(Set((firstPage..<80).map { "s\($0)" }))
        history.loadMore()
        await history.reload(showsLoading: false)
        await source.releaseMetadata()

        for _ in 0..<400 where history.visibleFiles.count < firstPage + 24 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(history.visibleFiles.count, firstPage + 24,
                                    "这一批照样读完，不停在半路（否则底下一直转圈）")
    }
}
