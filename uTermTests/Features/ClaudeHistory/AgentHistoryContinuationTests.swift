import Foundation
import XCTest
@testable import uTerm

/// 「接着往下聊」（用户报的：历史里冒出两行同名的对话）：Claude Code 上下文满了接着来时另起一份新记录，标题照抄，
/// 旧的末尾记一行 `continued-in`。侧栏只留最新那一份，「运行中」跟过去；记录顶上能翻回之前那段。
@MainActor
final class AgentHistoryContinuationTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "history-continuation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        defaults?.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    // MARK: 读记录

    private static let continuedLine = #"{"type":"continued-in","timestamp":"2026-11-26T08:32:53.658Z","sessionId":"old","continuedInSessionId":"new-1"}"#

    func testScanReadsContinuedIn() {
        let data = ClaudeFixture.file([ClaudeFixture.userText("你好"), Self.continuedLine])
        let scan = ClaudeSessionScan.scan(data, dropsLeadingPartial: false, dropsTrailingPartial: false)
        XCTAssertEqual(scan.continuedIn, "new-1")
    }

    func testLaterMessagesCancelContinuedIn() {
        let data = ClaudeFixture.file([Self.continuedLine, ClaudeFixture.userText("又回到旧的会话里聊", uuid: "u-2")])
        let scan = ClaudeSessionScan.scan(data, dropsLeadingPartial: false, dropsTrailingPartial: false)
        XCTAssertNil(scan.continuedIn, "旧的会话后来又被继续了：不算接到别处")
    }

    func testClaudeMetadataCarriesContinuedIn() async throws {
        let host = SQLiteTestHost()
        let path = "/home/user/.claude/projects/-srv-shop/old.jsonl"
        let data = ClaudeFixture.file([ClaudeFixture.userText("你好", cwd: "/srv/shop"), Self.continuedLine])
        await host.put(path, data)
        let source = ClaudeHistorySource(provider: host, home: "/home/user")
        let project = AgentHistoryProject(id: "-srv-shop", path: "/home/user/.claude/projects/-srv-shop", modifiedAt: nil)
        let file = AgentHistorySessionFile(sessionID: "old", project: project, path: path, size: UInt64(data.count),
                                           modifiedAt: Date())
        let metadata = try await source.metadata(for: file)
        XCTAssertEqual(metadata.continuedIn, "new-1")
        XCTAssertTrue(metadata.isListed, "本身照样算命令行的会话，藏不藏由列表看接着的那份在不在")
    }

    // MARK: 列表

    private func sessions(continuedInExists: Bool = true) -> [Session] {
        let now = Date()
        var list = [
            Session(id: "old", projectID: ClaudeProjectPath.encode("/srv/shop"), resumeDirectory: "/srv/shop",
                    title: "Code 视图侧边栏", modifiedAt: now.addingTimeInterval(-90), continuedIn: "new"),
            Session(id: "other", projectID: ClaudeProjectPath.encode("/srv/shop"), resumeDirectory: "/srv/shop",
                    title: "别的会话", modifiedAt: now.addingTimeInterval(-600)),
        ]
        if continuedInExists {
            list.append(Session(id: "new", projectID: ClaudeProjectPath.encode("/srv/shop"), resumeDirectory: "/srv/shop",
                                title: "Code 视图侧边栏", modifiedAt: now.addingTimeInterval(-30)))
        }
        return list
    }

    private func start(_ sessions: [Session]) async -> AgentHistoryModel {
        let history = AgentHistoryModel(source: AgentHistoryFakeSource(tool: .claude, sessions: sessions),
                                        preferredDirectory: nil, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
        return history
    }

    func testOnlyTheLatestPartIsListed() async throws {
        let history = await start(sessions())
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), ["new", "other"], "同一个对话只有一行")
        let old = try XCTUnwrap(history.files.first { $0.sessionID == "old" })
        let new = try XCTUnwrap(history.files.first { $0.sessionID == "new" })
        XCTAssertEqual(history.latestPart(of: old)?.path, new.path)
        XCTAssertEqual(history.continuationLink(of: new), .previous(old), "新的那份顶上能翻回之前那段")
        XCTAssertEqual(history.continuationLink(of: old), .next(new), "翻回去之后能再回到后来那段")
        XCTAssertNil(history.continuationLink(of: try XCTUnwrap(history.files.first { $0.sessionID == "other" })))
    }

    func testOldPartStaysWhenTheNewOneIsMissing() async throws {
        let history = await start(sessions(continuedInExists: false))
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), ["old", "other"], "接着的那份不在（删了、没列到）：旧的照旧列出来")
    }

    func testPinnedOldPartShowsTheLatestPart() async throws {
        let history = await start(sessions())
        let old = try XCTUnwrap(history.files.first { $0.sessionID == "old" })
        history.pins?.toggle(old)
        XCTAssertEqual(history.pinnedFiles.map(\.sessionID), ["new"], "置顶的那一行换成最新那一份")
    }
}
