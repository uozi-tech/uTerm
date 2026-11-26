import XCTest
@testable import uTerm

/// 列表一路往下读，在**这台 Mac 的真实记录**上读到底，底下的「正在读取…」不卡住（用户报的：停在一个转圈上不动）。
/// 照列表的做法：底下那一行露着就 `loadMore`，读完一批、行数变了再 `loadMore`。
///
/// 默认跳过，开关同 `AgentHistoryAllToolsLocalLiveTests`（`UTERM_AGENT_HISTORY_LOCAL=1`）。只读；输出里只有条数。
@MainActor
final class AgentHistoryLoadMoreLocalLiveTests: XCTestCase {
    func testReadsToTheEndWithoutStalling() async throws {
        guard ProcessInfo.processInfo.environment["UTERM_AGENT_HISTORY_LOCAL"] == "1" else {
            throw XCTSkip("没设 UTERM_AGENT_HISTORY_LOCAL=1，跳过读本机真实记录的测试")
        }
        AgentHistoryListCache.shared.removeAll()
        let client = LocalShellAgentClient()
        defer { client.invalidate() }
        let provider = RemoteMacFileProvider.localShellAgent(client: client)
        let source = AgentHistorySources.make(tools: AgentHistoryTool.allCases, provider: provider)
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        await history.start()

        // 先只读一页（列表刚打开、没往下滚），等慢的工具（Codex）列完、后台再列一次把它的会话并进来，再往下读到底。
        let firstCount = history.files.count
        for _ in 0..<600 where history.files.count == firstCount { try await Task.sleep(for: .milliseconds(50)) }
        print("[load-more-live] first list \(firstCount), merged \(history.files.count), shown \(history.visibleFiles.count)")
        var lastShown = -1
        var lastChange = ContinuousClock.now
        let deadline = ContinuousClock.now + .seconds(240)
        while history.hasMore, ContinuousClock.now < deadline {
            let shown = history.visibleFiles.count
            if shown != lastShown {
                lastShown = shown
                lastChange = .now
                history.loadMore()
            }
            if ContinuousClock.now - lastChange > .seconds(15) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let unreadInPrefix = history.files.prefix(history.resolvedCount).filter { history.metadata[$0.path] == nil }
        let next = history.resolvedCount < history.files.count ? history.files[history.resolvedCount] : nil
        print("""
            [load-more-live] hasMore=\(history.hasMore) shown=\(history.visibleFiles.count) \
            resolved=\(history.resolvedCount)/\(history.files.count) unreadInPrefix=\(unreadInPrefix.count) \
            (\(unreadInPrefix.map(\.tool.rawValue))) next=\(next.map { "\($0.tool.rawValue) read=\(history.metadata[$0.path] != nil)" } ?? "-")
            """)
        XCTAssertFalse(history.hasMore, "读到底，「正在读取…」收起")
    }
}
