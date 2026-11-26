import Foundation
import XCTest
@testable import uTerm

/// 会话的「重命名」「拷贝会话名」（用户要的：同 Claude Code Desktop）与删掉「接着往下聊」串起来的整个对话。
@MainActor
final class AgentHistoryRenameTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "history-rename-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        defaults?.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func start(_ source: any AgentHistorySource) async -> AgentHistoryModel {
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
        return history
    }

    private func session(_ id: String, title: String, ago: TimeInterval, continuedIn: String? = nil) -> Session {
        Session(id: id, projectID: ClaudeProjectPath.encode("/srv/shop"), resumeDirectory: "/srv/shop", title: title,
                modifiedAt: Date().addingTimeInterval(-ago), continuedIn: continuedIn)
    }

    // MARK: 菜单

    func testMenuOrderMatchesDesktop() {
        typealias Item = AgentHistorySessionMenuItem
        XCTAssertEqual(Item.items(hasRecord: true, canResume: true, canPin: true, isPinned: false, isRunning: false,
                                  canDelete: true, canRename: true),
                       [.resume, .pin(isPinned: false), .rename, .copyTitle, .copySessionID, .delete])
        XCTAssertEqual(Item.items(hasRecord: true, canResume: true, canPin: true, isPinned: true, isRunning: true,
                                  canDelete: true, canRename: true),
                       [.pin(isPinned: true), .rename, .copyTitle, .endSession], "跑着的也能改名、拷贝名字")
        XCTAssertEqual(Item.items(hasRecord: false, canResume: false, canPin: false, isPinned: false, isRunning: true,
                                  canDelete: false, canRename: true), [.endSession], "还没对上记录的新会话只能结束")
    }

    // MARK: 模型

    func testRenameUpdatesTheRowRightAway() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", title: "旧名字", ago: 60)])
        let history = await start(source)
        let file = try XCTUnwrap(history.visibleFiles.first)
        XCTAssertTrue(history.canRename(file))

        try await history.rename(file, to: "  新名字  \n")

        let renames = await source.renames
        XCTAssertEqual(renames, ["a=新名字"], "去掉首尾空白后写回记录")
        XCTAssertEqual(AgentHistoryText.sessionTitle(file, metadata: history.metadata[file.path]), "新名字",
                       "不等重读就换")
        try await history.rename(file, to: "   ")
        let after = await source.renames
        XCTAssertEqual(after.count, 1, "空名字不改")
    }

    func testFailedRenameKeepsTheTitle() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", title: "旧名字", ago: 60)])
        await source.setRenameError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        let history = await start(source)
        let file = try XCTUnwrap(history.visibleFiles.first)
        do {
            try await history.rename(file, to: "新名字")
            XCTFail("改不了要报出来")
        } catch {}
        XCTAssertEqual(history.metadata[file.path]?.title, "旧名字")
    }

    func testToolsWithoutRenameAreNotOffered() async throws {
        let cursor = AgentHistoryFakeSource(tool: .cursor, sessions: [
            Session(id: "c", projectID: "/srv/shop", projectDirectory: "/srv/shop", resumeDirectory: "/srv/shop",
                    title: "Cursor 的会话", modifiedAt: Date()),
        ], supportsRename: false)
        let history = await start(cursor)
        let file = try XCTUnwrap(history.visibleFiles.first)
        XCTAssertFalse(history.canRename(file))
    }

    func testDeletingAContinuedConversationDeletesEveryPart() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [
            session("p1", title: "同一个对话", ago: 300, continuedIn: "p2"),
            session("p2", title: "同一个对话", ago: 200, continuedIn: "p3"),
            session("p3", title: "同一个对话", ago: 100),
            session("other", title: "别的", ago: 50),
        ])
        let history = await start(source)
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), ["other", "p3"])
        let latest = try XCTUnwrap(history.visibleFiles.first { $0.sessionID == "p3" })

        try await history.delete(latest)

        let deleted = await source.deleted
        XCTAssertEqual(Set(deleted), ["p1", "p2", "p3"], "前面那几段一起删，不然删了这一行之前那段又冒出来")
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), ["other"])
    }

    // MARK: Claude Code 的记录

    /// 追加的那一行要是 Claude Code `/rename` 写的同一种（`custom-title`），列表读得出来；名字里有引号、`!`、`$` 都原样。
    func testClaudeRenameCommandAppendsACustomTitleLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let title = #"它's "新" 名字 $HOME !x \ 反斜杠"#
        for endsWithNewline in [true, false] {
            let path = directory.appendingPathComponent("s\(endsWithNewline).jsonl").path
            var data = ClaudeFixture.file([ClaudeFixture.userText("你好")])
            if !endsWithNewline { data.removeLast() }
            try data.write(to: URL(fileURLWithPath: path))

            let command = ClaudeHistorySource.renameCommand(path: path, sessionID: "s1", title: title)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let written = try Data(contentsOf: URL(fileURLWithPath: path))
            let scan = ClaudeSessionScan.scan(written, dropsLeadingPartial: false, dropsTrailingPartial: false)
            XCTAssertEqual(scan.customTitle, title, "末尾\(endsWithNewline ? "是" : "不是")换行")
            XCTAssertTrue(scan.hasMessageLine, "原来那一行还在，没被盖掉")
            XCTAssertEqual(written.last, 0x0A)
        }
    }
}
