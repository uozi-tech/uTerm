import XCTest
@testable import uTerm

final class ClaudeSessionScanTests: XCTestCase {
    private func scan(_ lines: [String], dropsLeading: Bool = false) -> ClaudeSessionScan {
        ClaudeSessionScan.scan(ClaudeFixture.file(lines), dropsLeadingPartial: dropsLeading, dropsTrailingPartial: false)
    }

    func testCLISessionIsListed() {
        let result = scan([ClaudeFixture.userText("hi"), ClaudeFixture.aiTitle("修复登录")])
        XCTAssertEqual(result.origin, .cli)
        XCTAssertTrue(result.origin.isListed)
        XCTAssertEqual(result.title, "修复登录")
        XCTAssertEqual(result.gitBranch, "main")
        XCTAssertEqual(result.directories.last, ClaudeFixture.cwd)
        XCTAssertNotNil(result.lastTimestamp)
    }

    func testDesktopAndSDKSessionsAreNotListed() {
        XCTAssertEqual(scan([ClaudeFixture.userText("hi", entrypoint: "claude-desktop")]).origin, .other("claude-desktop"))
        XCTAssertFalse(scan([ClaudeFixture.userText("hi", entrypoint: "sdk-cli")]).origin.isListed)
    }

    func testLastEntrypointWins() {
        // 桌面版起的会话后来在命令行里接着用（真实文件里出现过）。
        let resumed = scan([ClaudeFixture.userText("a", entrypoint: "claude-desktop"), ClaudeFixture.userText("b")])
        XCTAssertEqual(resumed.origin, .cli)
        let back = scan([ClaudeFixture.userText("a"), ClaudeFixture.userText("b", entrypoint: "claude-desktop")])
        XCTAssertEqual(back.origin, .other("claude-desktop"))
    }

    func testMissingEntrypointWithMessagesIsLegacyCLI() {
        let result = scan([ClaudeFixture.userText("老版本", entrypoint: nil), ClaudeFixture.lastPrompt("老版本")])
        XCTAssertEqual(result.origin, .legacy)
        XCTAssertTrue(result.origin.isListed)
    }

    func testTitleOnlySessionIsUnknownAndHidden() {
        let result = scan([ClaudeFixture.aiTitle("空会话")])
        XCTAssertEqual(result.origin, .unknown)
        XCTAssertFalse(result.origin.isListed)
        XCTAssertFalse(result.isOriginDecided)
    }

    func testTitlePriority() {
        let all = scan([ClaudeFixture.lastPrompt("最后一问"), ClaudeFixture.aiTitle("AI 标题"),
                        ClaudeFixture.customTitle("我起的名字"), ClaudeFixture.aiTitle("新的 AI 标题")])
        XCTAssertEqual(all.title, "我起的名字")
        XCTAssertEqual(scan([ClaudeFixture.lastPrompt("最后一问"), ClaudeFixture.aiTitle("AI 标题")]).title, "AI 标题")
        XCTAssertEqual(scan([ClaudeFixture.lastPrompt("多行\n提问")]).title, "多行 提问")
        XCTAssertNil(scan([ClaudeFixture.noise(1)]).title)
    }

    func testFallsBackToLastUserTextAndDetectsConversation() {
        let result = scan([ClaudeFixture.userText("第一句"), ClaudeFixture.userText("<system-reminder>x</system-reminder>第二句"),
                           ClaudeFixture.lastPrompt("")])
        XCTAssertEqual(result.title, "第二句")
        XCTAssertTrue(result.hasConversation)
        // 只敲过 /exit：有消息行，没有对话。
        let exitOnly = scan([ClaudeFixture.userText("<command-name>/exit</command-name>\n<command-args></command-args>"),
                             ClaudeFixture.userText("<local-command-stdout>Bye!</local-command-stdout>")])
        XCTAssertTrue(exitOnly.hasMessageLine)
        XCTAssertFalse(exitOnly.hasConversation)
        XCTAssertNil(exitOnly.title)
    }

    func testPartialFirstLineIsIgnoredForTitles() {
        let title = ClaudeFixture.aiTitle("被截断")
        let cut = String(title.dropFirst(5))
        let data = Data((cut + "\n" + ClaudeFixture.noise(1) + "\n").utf8)
        let result = ClaudeSessionScan.scan(data, dropsLeadingPartial: true, dropsTrailingPartial: false)
        XCTAssertNil(result.title)
    }

    func testEscapedValuesAreDecoded() {
        let line = #"{"type":"user","message":{"role":"user","content":"x"},"cwd":"/home/u/中\"q\"","entrypoint":"cli"}"#
        let result = scan([line])
        XCTAssertEqual(result.directories, [#"/home/u/中"q""#])
        // 字符串里转义过的键不算。
        let inner = #"{"type":"user","message":{"role":"user","content":"{\"entrypoint\":\"claude-desktop\"}"},"entrypoint":"cli"}"#
        XCTAssertEqual(scan([inner]).entrypoints, ["cli"])
    }
}

final class ClaudeHistorySourceTests: XCTestCase {
    private let root = "/home/user/.claude/projects"
    private let project = "-home-user-projects-demo"

    private func sessionPath(_ id: String) -> String { "\(root)/\(project)/\(id).jsonl" }

    private func makeSFTP(files: [(id: String, data: Data, mtime: Date)]) async -> MockSFTP {
        let sftp = MockSFTP(tree: [
            root: [ClaudeFixture.entry(project, directory: true), ClaudeFixture.entry("-srv-other", directory: true)],
            "\(root)/\(project)": files.map { ClaudeFixture.entry("\($0.id).jsonl", size: UInt64($0.data.count), mtime: $0.mtime) }
                + [ClaudeFixture.entry("memory", directory: true), ClaudeFixture.entry("notes.txt", size: 3)],
        ])
        for file in files { await sftp.setFile(sessionPath(file.id), data: file.data, mtime: file.mtime) }
        return sftp
    }

    func testListsProjectsAndSessionsNewestFirst() async throws {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        let sftp = await makeSFTP(files: [("11111111-1111-1111-1111-111111111111", ClaudeFixture.file([ClaudeFixture.userText("a")]), old),
                                          ("22222222-2222-2222-2222-222222222222", ClaudeFixture.file([ClaudeFixture.userText("b")]), new)])
        let source = ClaudeHistorySource(provider: sftp)
        let projects = try await source.projects()
        XCTAssertEqual(Set(projects.map(\.id)), [project, "-srv-other"])
        let current = await source.project(containing: "/home/user/projects/demo/src", among: projects)
        XCTAssertEqual(current?.id, project)
        XCTAssertEqual(current?.directory, "/home/user/projects/demo")
        let sessions = try await source.sessions(in: try XCTUnwrap(current))
        XCTAssertEqual(sessions.map(\.sessionID), ["22222222-2222-2222-2222-222222222222", "11111111-1111-1111-1111-111111111111"])
    }

    func testNoProjectsDirectoryMeansEmpty() async throws {
        let source = ClaudeHistorySource(provider: MockSFTP())
        let projects = try await source.projects()
        XCTAssertEqual(projects, [])
    }

    func testMetadataReadsOnlyTheTailAndCaches() async throws {
        var lines = [ClaudeFixture.userText("开头", cwd: "/home/user/projects/demo")]
        for index in 0..<3000 { lines.append(ClaudeFixture.noise(index)) }
        lines.append(ClaudeFixture.userText("最后", cwd: "/home/user/projects/demo/sub"))
        lines.append(ClaudeFixture.aiTitle("整理目录"))
        let data = ClaudeFixture.file(lines)
        XCTAssertGreaterThan(data.count, ClaudeHistorySource.tailBytes * 3)
        let id = ClaudeFixture.sessionID
        let sftp = await makeSFTP(files: [(id, data, Date())])
        let source = ClaudeHistorySource(provider: sftp)
        let projects = try await source.projects()
        let project = try XCTUnwrap(projects.first { $0.id == self.project })
        let sessions = try await source.sessions(in: project)
        let file = try XCTUnwrap(sessions.first)
        let metadata = try await source.metadata(for: file)
        XCTAssertEqual(metadata.title, "整理目录")
        XCTAssertTrue(metadata.isListed)
        XCTAssertEqual(metadata.lastDirectory, "/home/user/projects/demo/sub")
        XCTAssertEqual(metadata.resumeDirectory, "/home/user/projects/demo")
        let readBytes = await sftp.rangeReads.reduce(0) { $0 + $1.length }
        XCTAssertEqual(readBytes, ClaudeHistorySource.tailBytes)
        _ = try await source.metadata(for: file)
        let again = await sftp.rangeReads.count
        XCTAssertEqual(again, 1)
    }

    func testSmallSessionWithoutConversationIsNotListed() async throws {
        let empty = ClaudeFixture.file([ClaudeFixture.userText("<command-name>/model</command-name>"),
                                        ClaudeFixture.lastPrompt("")])
        let sftp = await makeSFTP(files: [(ClaudeFixture.sessionID, empty, Date())])
        let source = ClaudeHistorySource(provider: sftp)
        let projects = try await source.projects()
        let sessions = try await source.sessions(in: try XCTUnwrap(projects.first { $0.id == self.project }))
        let metadata = try await source.metadata(for: try XCTUnwrap(sessions.first))
        XCTAssertFalse(metadata.isListed)
    }

    func testOriginFallsBackToTheHeadWhenTailHasNoMessages() async throws {
        var lines = [ClaudeFixture.userText("桌面版", entrypoint: "claude-desktop")]
        for index in 0..<3000 { lines.append(ClaudeFixture.noise(index)) }
        lines.append(ClaudeFixture.aiTitle("桌面会话"))
        let sftp = await makeSFTP(files: [(ClaudeFixture.sessionID, ClaudeFixture.file(lines), Date())])
        let source = ClaudeHistorySource(provider: sftp)
        let projects = try await source.projects()
        let project = try XCTUnwrap(projects.first { $0.id == self.project })
        let sessions = try await source.sessions(in: project)
        let file = try XCTUnwrap(sessions.first)
        let metadata = try await source.metadata(for: file)
        XCTAssertFalse(metadata.isListed)
        XCTAssertEqual(metadata.title, "桌面会话")
        let reads = await sftp.rangeReads
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads.last?.offset, 0)
    }
}

@MainActor
final class AgentHistoryModelTests: XCTestCase {
    private let root = "/home/user/.claude/projects"
    private let project = "-home-user-projects-demo"

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStartsInCurrentProjectAndHidesNonCLISessions() async throws {
        let cli = "11111111-1111-1111-1111-111111111111", desktop = "22222222-2222-2222-2222-222222222222"
        let cliData = ClaudeFixture.file([ClaudeFixture.userText("a"), ClaudeFixture.aiTitle("命令行")])
        let desktopData = ClaudeFixture.file([ClaudeFixture.userText("b", entrypoint: "claude-desktop")])
        let sftp = MockSFTP(tree: [
            root: [ClaudeFixture.entry(project, directory: true)],
            "\(root)/\(project)": [ClaudeFixture.entry("\(cli).jsonl", size: UInt64(cliData.count), mtime: Date(timeIntervalSince1970: 1)),
                                   ClaudeFixture.entry("\(desktop).jsonl", size: UInt64(desktopData.count), mtime: Date(timeIntervalSince1970: 2))],
        ])
        await sftp.setFile("\(root)/\(project)/\(cli).jsonl", data: cliData, mtime: Date(timeIntervalSince1970: 1))
        await sftp.setFile("\(root)/\(project)/\(desktop).jsonl", data: desktopData, mtime: Date(timeIntervalSince1970: 2))

        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: sftp),
                                      preferredDirectory: "/home/user/projects/demo")
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.currentProject?.id, project)
        XCTAssertEqual(model.scope, .project(try XCTUnwrap(model.currentProject)))
        XCTAssertEqual(model.visibleFiles.count, 2)

        model.rowAppeared(try XCTUnwrap(model.visibleFiles.first))
        await waitUntil { model.metadata.count == 2 }
        XCTAssertEqual(model.visibleFiles.map(\.sessionID), [cli])
        XCTAssertEqual(model.hiddenCount, 1)

        let file = try XCTUnwrap(model.visibleFiles.first)
        XCTAssertEqual(model.resumeCommand(for: file)?.command,
                       "cd -- '/home/user/projects/demo' && claude --resume \(cli)")
        model.select(file)
        let transcript = try XCTUnwrap(model.transcript)
        await waitUntil { transcript.reachedStart }
        XCTAssertEqual(transcript.items.map(\.kind), [.userText("a")])

        await model.setScope(.all)
        XCTAssertEqual(model.files.count, 2)
    }

    func testNoHistoryDirectory() async {
        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: MockSFTP()), preferredDirectory: nil)
        await model.start()
        XCTAssertEqual(model.phase, .empty)
    }
}
