import XCTest
@testable import uTerm

/// 侧栏后台重列（Code 标签页里有新会话在等记录时每 10 秒一次、会话结束时一次）不能让历史从侧栏上消失：
/// 一个项目这次没列出来、整趟列不出来、最上面冒出一份读得慢的新记录、跑着的会话的记录一直在变，已经显示的行都留着。
/// 再开一次同一台主机的列表（新开 Code 标签页）先显示上一次列到的（`AgentHistoryListCache`）。
@MainActor
final class AgentHistoryBackgroundRefreshTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session

    override func setUp() async throws {
        try await super.setUp()
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        try await super.tearDown()
    }

    private func session(_ id: String, project: String, ago seconds: TimeInterval, listed: Bool = true) -> Session {
        Session(id: id, projectID: project, resumeDirectory: "/srv/\(project)", title: "会话 \(id)",
                modifiedAt: Date().addingTimeInterval(-seconds), isListed: listed)
    }

    private var sessions: [Session] {
        var result: [Session] = []
        for index in 0..<6 {
            let project = index % 2 == 0 ? "shop" : "infra"
            result.append(session("s\(index)", project: project, ago: TimeInterval(60 * (index + 1))))
        }
        return result
    }

    private func settle(_ history: AgentHistoryModel) async {
        for _ in 0..<300 where history.hasMore || history.isListing {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func model(_ source: AgentHistoryFakeSource, cacheKey: String? = nil) async -> AgentHistoryModel {
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false,
                                        cacheKey: cacheKey)
        await history.start()
        await settle(history)
        return history
    }

    private func ids(_ history: AgentHistoryModel) -> [String] { history.visibleFiles.map(\.sessionID) }

    func testProjectThatFailsToListKeepsItsRows() async {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = await model(source)
        XCTAssertEqual(ids(history), ["s0", "s1", "s2", "s3", "s4", "s5"])

        await source.setFailingProjects(["infra"])
        await history.reload(showsLoading: false)
        await settle(history)
        XCTAssertEqual(ids(history), ["s0", "s1", "s2", "s3", "s4", "s5"], "这一趟没列出来的项目，上一次列到的留着")
    }

    func testWholeListingFailingInTheBackgroundKeepsTheList() async {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = await model(source)
        await source.setProjectsError(AgentHistoryFakeError.missing)
        await history.reload(showsLoading: false)
        XCTAssertEqual(history.phase, .ready, "后台重列失败不换成失败页")
        XCTAssertEqual(ids(history).count, 6)

        await history.reload()
        XCTAssertNotEqual(history.phase, .ready, "用户自己点「刷新」照旧报错")
    }

    /// 在 `~` 新开了一个会话：最上面冒出一份新记录，信息还没读到（读得慢）。下面的历史一行不少，新的读到了再出来。
    func testNewSlowRecordOnTopDoesNotHideTheHistory() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = await model(source)
        await source.add(session("fresh", project: "-Users-me", ago: -1))
        await source.holdMetadata(["fresh"])
        await history.reload(showsLoading: false)
        XCTAssertEqual(history.files.first?.sessionID, "fresh")
        XCTAssertEqual(ids(history), ["s0", "s1", "s2", "s3", "s4", "s5"], "读得慢的新记录挡不住下面已经显示的行")

        await source.releaseMetadata()
        await settle(history)
        for _ in 0..<100 where ids(history).first != "fresh" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(ids(history), ["fresh", "s0", "s1", "s2", "s3", "s4", "s5"], "读到了就出来")
    }

    /// 跑着的会话的记录一直在写：重列时它那一行照旧显示上次读到的标题，后台重读，不先消失。
    func testChangedRecordKeepsItsRowWhileReread() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = await model(source)
        await source.update("s0") {
            $0.size += 4096
            $0.modifiedAt = Date()
            $0.title = "改过的标题"
        }
        await source.holdMetadata(["s0"])
        await history.reload(showsLoading: false)
        XCTAssertEqual(ids(history), ["s0", "s1", "s2", "s3", "s4", "s5"], "变了的记录那一行留着")
        XCTAssertEqual(history.metadata[history.files[0].path]?.title, "会话 s0", "先显示上次读到的")

        await source.releaseMetadata()
        for _ in 0..<200 where history.metadata[history.files[0].path]?.title != "改过的标题" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(history.metadata[history.files[0].path]?.title, "改过的标题", "重读之后换成新的")
    }

    /// 再开一次同一台主机的列表：上一次列到的立刻显示（连列目录都还没回来），后台重列完再换成新的。
    func testReopeningShowsTheCachedListFirst() async throws {
        let first = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = await model(first, cacheKey: "host-a")
        history.storeInCache()
        XCTAssertEqual(ids(history).count, 6)

        let second = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        await second.setProjectsError(AgentHistoryFakeError.missing)
        let reopened = await model(second, cacheKey: "host-a")
        XCTAssertEqual(reopened.phase, .ready)
        XCTAssertEqual(ids(reopened), ids(history), "列不出来也先显示上一次的")
        let reads = await second.metadataReads
        XCTAssertEqual(reads, 0, "读过、没变的记录不再读")

        let other = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        await other.setProjectsError(AgentHistoryFakeError.missing)
        let elsewhere = await model(other, cacheKey: "host-b")
        XCTAssertNotEqual(elsewhere.phase, .ready, "别的主机不用这一份")
    }
}
