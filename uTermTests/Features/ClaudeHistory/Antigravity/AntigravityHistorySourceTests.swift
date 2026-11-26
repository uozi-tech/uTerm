import XCTest
@testable import uTerm

/// Antigravity 的数据源：列表与项目、标题的几条来路、对话的分页与跟随、继续会话的命令。主机是 `MockSFTP`，内容全是编的。
@MainActor
final class AntigravityHistorySourceTests: XCTestCase {
    private typealias F = AntigravityFixture
    private typealias S = AntigravityFixture.Session

    // MARK: 列表与项目

    func testWithoutIndexEverythingIsInTheNoWorkspaceGroup() async throws {
        let sftp = await F.host([S(index: 1, data: F.file(F.conversation("第一个")), age: 30),
                                 S(index: 2, data: F.file(F.conversation("第二个")), age: 90)])
        let source = AntigravityHistorySource(provider: sftp)
        let projects = try await source.projects()
        XCTAssertEqual(projects.count, 1)
        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project.id, AntigravityHistorySource.noWorkspaceProjectID)
        XCTAssertNil(project.directory)
        XCTAssertEqual(project.tool, .antigravity)
        XCTAssertEqual(project.path, F.appRoot + "/brain")

        let sessions = try await source.sessions(in: project)
        XCTAssertEqual(sessions.map(\.sessionID), [F.sessionID(1), F.sessionID(2)], "新的在前，.DS_Store 不算")
        XCTAssertEqual(sessions.first?.path, F.transcriptPath(1))
        XCTAssertEqual(sessions.first?.size, UInt64(F.file(F.conversation("第一个")).count))
        XCTAssertEqual(sessions.first?.tool, .antigravity)

        let info = try await source.metadata(for: try XCTUnwrap(sessions.first))
        XCTAssertEqual(info.title, "第一个", "没有摘要时标题取第一句你说的话")
        XCTAssertTrue(info.isListed)
        XCTAssertNil(info.resumeDirectory)
        XCTAssertEqual(info.lastActivity, ClaudeTimestamp.parse(F.time(4)))
        // 只读：没往主机上写任何东西。
        let writes = await sftp.rangeWrites.count
        let created = await sftp.createdFiles.count + sftp.createdDirs.count
        XCTAssertEqual(writes + created, 0)
    }

    func testIndexGroupsByWorkspaceAndSuppliesTitles() async throws {
        let other = "/home/user/projects/other"
        let index = FakeAntigravityIndex(byRoot: [F.appRoot: [
            F.sessionID(1): AntigravityConversationInfo(title: "摘要里的标题", workspace: F.workspace),
            F.sessionID(2): AntigravityConversationInfo(workspace: F.workspace),
            F.sessionID(3): AntigravityConversationInfo(title: "别的项目", workspace: other),
        ]])
        let sftp = await F.host([S(index: 1, data: F.file(F.conversation("一")), age: 10),
                                 S(index: 2, data: F.file(F.conversation("二")), age: 20, annotation: "注解里的标题"),
                                 S(index: 3, data: F.file(F.conversation("三")), age: 5),
                                 S(index: 4, data: F.file(F.conversation("四")), age: 40)])
        let source = AntigravityHistorySource(provider: sftp, index: index)
        let projects = try await source.projects()
        XCTAssertEqual(Set(projects.map(\.id)), [F.workspace, other, AntigravityHistorySource.noWorkspaceProjectID])
        XCTAssertEqual(projects.first?.directory, other, "最近的项目在前")
        XCTAssertTrue(projects.allSatisfy { $0.tool == .antigravity })

        let demo = try XCTUnwrap(projects.first { $0.directory == F.workspace })
        let sessions = try await source.sessions(in: demo)
        XCTAssertEqual(sessions.map(\.sessionID), [F.sessionID(1), F.sessionID(2)])
        let first = try await source.metadata(for: sessions[0])
        let second = try await source.metadata(for: sessions[1])
        XCTAssertEqual(first.title, "摘要里的标题")
        XCTAssertEqual(second.title, "注解里的标题", "摘要没有标题时用 annotations/ 里的")
        XCTAssertEqual(first.resumeDirectory, F.workspace)
        XCTAssertEqual(first.lastDirectory, F.workspace)

        // 终端在项目的子目录里：落在那个项目上；不相干的目录不落。
        let deep = await source.project(containing: F.workspace + "/src/deep", among: projects)
        let sibling = await source.project(containing: "/home/user/projects/demolition", among: projects)
        let elsewhere = await source.project(containing: "/tmp", among: projects)
        XCTAssertEqual(deep?.id, F.workspace)
        XCTAssertNil(sibling)
        XCTAssertNil(elsewhere)

        let all = await source.allSessions(in: projects)
        XCTAssertEqual(all.map(\.sessionID), [3, 1, 2, 4].map(F.sessionID))
    }

    func testFailingIndexFallsBackToRecordsOnly() async throws {
        let sftp = await F.host([S(index: 1, data: F.file(F.conversation("你好")))])
        let source = AntigravityHistorySource(provider: sftp, index: FailingAntigravityIndex())
        let projects = try await source.projects()
        XCTAssertEqual(projects.map(\.id), [AntigravityHistorySource.noWorkspaceProjectID])
        let files = await source.allSessions(in: projects)
        let info = try await source.metadata(for: try XCTUnwrap(files.first))
        XCTAssertEqual(info.title, "你好")
    }

    func testNoDataDirectoryMeansNoProjects() async throws {
        let source = AntigravityHistorySource(provider: MockSFTP())
        let projects = try await source.projects()
        XCTAssertEqual(projects, [])
        let files = await source.allSessions(in: projects)
        XCTAssertEqual(files, [])
    }

    func testSessionsWithoutRecordsAreSkippedAndShortTranscriptIsTheFallback() async throws {
        let short = F.file([F.userInput(0, "只有删节版"), F.planner(1, content: "好")])
        let sftp = await F.host([S(index: 1, data: F.file(F.conversation("完整的"))),
                                 S(index: 2, data: short, name: "transcript.jsonl")])
        // 第 3 个会话目录里还没有记录。
        var tree = await sftp.tree
        tree[F.appRoot + "/brain"]?.append(ClaudeFixture.entry(F.sessionID(3), directory: true))
        await sftp.setTree(tree)
        let source = AntigravityHistorySource(provider: sftp)
        let projects = try await source.projects()
        let files = await source.allSessions(in: projects)
        XCTAssertEqual(Set(files.map(\.sessionID)), [F.sessionID(1), F.sessionID(2)])
        let fallback = try XCTUnwrap(files.first { $0.sessionID == F.sessionID(2) })
        XCTAssertTrue(fallback.path.hasSuffix("/transcript.jsonl"))
        let page = try await source.transcript(for: fallback).loadPrevious()
        XCTAssertEqual(page.items.filter(\.isDisplayed).map(\.kind), [.userText("只有删节版"), .assistantText("好")])
    }

    func testEmptyRecordsAreNotListed() async throws {
        let onlyNoise = F.file([F.systemMessage(0, "系统说的话"), F.errorMessage(1, "API error")])
        let sftp = await F.host([S(index: 1, data: onlyNoise)])
        let source = AntigravityHistorySource(provider: sftp)
        let files = await source.allSessions(in: try await source.projects())
        let info = try await source.metadata(for: try XCTUnwrap(files.first))
        XCTAssertFalse(info.isListed)
        XCTAssertNil(info.title)
    }

    /// 大文件：标题在开头那一块里，最后的时间在末尾那一块里，中间不读。
    func testLargeRecordReadsOnlyHeadAndTail() async throws {
        var lines = [F.userInput(0, "开头的那句话")]
        for step in 1...400 {
            lines.append(F.planner(step, content: String(repeating: "填充的回答 ", count: 60)))
        }
        lines.append(F.userInput(401, "最后一句"))
        let data = F.file(lines)
        XCTAssertGreaterThan(data.count, AntigravityHistorySource.tailBytes + AntigravityHistorySource.headBytes)
        let sftp = await F.host([S(index: 1, data: data)])
        let source = AntigravityHistorySource(provider: sftp)
        let files = await source.allSessions(in: try await source.projects())
        await sftp.clearRangeReads()
        let info = try await source.metadata(for: try XCTUnwrap(files.first))
        XCTAssertEqual(info.title, "开头的那句话")
        XCTAssertEqual(info.lastActivity, ClaudeTimestamp.parse(F.time(401)))
        XCTAssertTrue(info.isListed)
        let reads = await sftp.rangeReads.filter { $0.path.hasSuffix(".jsonl") }
        XCTAssertEqual(reads.map(\.length).reduce(0, +), AntigravityHistorySource.tailBytes + AntigravityHistorySource.headBytes)
        // 第二遍走缓存。
        await sftp.clearRangeReads()
        _ = try await source.metadata(for: try XCTUnwrap(files.first))
        let again = await sftp.rangeReads.count
        XCTAssertEqual(again, 0)
    }

    // MARK: 对话

    func testTranscriptPagesBackAndFollowsNewSteps() async throws {
        var lines: [String] = []
        for round in 0..<30 {
            let step = round * 4
            lines += [F.userInput(step, "第 \(round) 问"),
                      F.planner(step + 1, calls: [F.command("echo \(round)")]),
                      F.generic(step + 2, "输出 \(round)"),
                      F.planner(step + 3, content: "第 \(round) 答")]
        }
        let path = F.transcriptPath(1)
        let sftp = await F.host([S(index: 1, data: F.file(lines))])
        let pager = ClaudeTranscriptPager(provider: sftp, path: path, chunkBytes: 1024, pageItems: 10, lineParser: {
            AntigravityTranscriptParser.items(from: $0)
        })
        var items: [AgentTranscriptItem] = []
        var reachedStart = false
        var pages = 0
        while !reachedStart {
            let page = try await pager.loadPrevious()
            items = page.items + items
            reachedStart = page.reachedStart
            pages += 1
        }
        XCTAssertGreaterThan(pages, 3)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        // 用量不画，不算在内。
        let assembled = AgentTranscriptAssembler.attachResults(items).filter(\.isDisplayed)
        XCTAssertEqual(assembled.count, 30 * 3, "每轮：问、带结果的调用、答")
        XCTAssertEqual(assembled.first?.kind, .userText("第 0 问"))
        guard case .toolCall(let call) = assembled[1].kind else { return XCTFail() }
        XCTAssertEqual(call.result?.content.text, "输出 0", "跨页的结果照样挂上")

        // 会话还开着：新写的一步接着读出来。
        let grown = F.file(lines + [F.userInput(120, "又问一句")])
        await sftp.setFile(path, data: grown, mtime: Date())
        let growth = try await pager.loadNewer()
        guard case .appended(let newer, let hasMore) = growth else { return XCTFail("\(growth)") }
        XCTAssertEqual(newer.map(\.kind), [.userText("又问一句")])
        XCTAssertFalse(hasMore)
    }

    func testOpensAroundAnAnchorWithTheSameIDs() async throws {
        let lines = F.conversation("一问") + [F.userInput(5, "二问"), F.planner(6, content: "二答")]
        let data = F.file(lines)
        let sftp = await F.host([S(index: 1, data: data)])
        let source = AntigravityHistorySource(provider: sftp)
        let listed = await source.allSessions(in: try await source.projects())
        let file = try XCTUnwrap(listed.first)
        let offset = lines.prefix(5).map { $0.utf8.count + 1 }.reduce(0, +)
        let anchor = AgentTranscriptAnchor(lineOffset: UInt64(offset), lineLength: lines[5].utf8.count)
        let pager = source.transcript(for: file, around: anchor)
        let page = try await pager.loadPrevious()
        XCTAssertEqual(page.items.last?.kind, .userText("二问"))
        XCTAssertEqual(page.items.last?.id, "\(offset).0")
        guard case .appended(let rest, hasMore: false) = try await pager.loadNext() else { return XCTFail() }
        XCTAssertEqual(rest.filter(\.isDisplayed).map(\.kind), [.assistantText("二答")])
        let whole = try await source.transcript(for: file).loadPrevious()
        XCTAssertTrue(whole.items.contains { $0.id == "\(offset).0" })
    }

    func testOversizedLineInTranscript() async throws {
        let big = F.planner(1, content: String(repeating: "很长", count: 4000))
        let data = F.file([F.userInput(0, "前面"), big, F.planner(2, content: "后面")])
        let path = F.transcriptPath(1)
        let sftp = await F.host([S(index: 1, data: data)])
        let pager = ClaudeTranscriptPager(provider: sftp, path: path, chunkBytes: 512, maxLineBytes: 4096,
                                          lineParser: { AntigravityTranscriptParser.items(from: $0) })
        var items: [AgentTranscriptItem] = []
        var done = false
        while !done {
            let page = try await pager.loadPrevious()
            items = page.items + items
            done = page.reachedStart
        }
        XCTAssertEqual(items.filter(\.isDisplayed).map(\.kind), [.userText("前面"), .oversized(bytes: big.utf8.count), .assistantText("后面")])
    }

    // MARK: 子会话

    func testNoSubagentsAreReported() async throws {
        let sftp = await F.host([S(index: 1, data: F.file(F.conversation("一")))])
        let source = AntigravityHistorySource(provider: sftp)
        let listed = await source.allSessions(in: try await source.projects())
        let file = try XCTUnwrap(listed.first)
        let subagents = try await source.subagents(of: .session(file))
        XCTAssertEqual(subagents, [])
    }

    // MARK: 继续 / 新开

    func testOnlyCLISessionsCanBeResumed() async throws {
        let index = FakeAntigravityIndex(byRoot: [F.cliRoot: [F.sessionID(2): AntigravityConversationInfo(workspace: F.workspace)]])
        let sftp = await F.host([S(index: 1, data: F.file(F.conversation("桌面版"))),
                                 S(index: 2, data: F.file(F.conversation("命令行")), root: F.cliRoot)])
        let source = AntigravityHistorySource(provider: sftp, index: index)
        XCTAssertNil(source.newSessionCommand(directory: F.workspace), "还没列过：不知道有没有命令行")
        let projects = try await source.projects()
        XCTAssertEqual(Set(projects.map(\.id)), [F.workspace, AntigravityHistorySource.noWorkspaceProjectID])
        XCTAssertNil(source.resumeCommand(sessionID: F.sessionID(1), directory: F.workspace), "桌面版的会话没法在终端里接上")
        XCTAssertEqual(source.resumeCommand(sessionID: F.sessionID(2).uppercased(), directory: "/home/user/it's here"),
                       "cd -- '/home/user/it'\\''s here' && agy --conversation \(F.sessionID(2))")
        XCTAssertNil(source.resumeCommand(sessionID: F.sessionID(2), directory: "relative/dir"))
        XCTAssertNil(source.resumeCommand(sessionID: "not-a-uuid; rm -rf /", directory: F.workspace))
        XCTAssertEqual(source.newSessionCommand(directory: F.workspace), "cd -- '/home/user/projects/demo' && agy")
        XCTAssertNil(source.newSessionCommand(directory: "/home/user/a\nb"))

        let all = await source.allSessions(in: projects)
        let cliFile = try XCTUnwrap(all.first { $0.sessionID == F.sessionID(2) })
        let cliInfo = try await source.metadata(for: cliFile)
        XCTAssertEqual(cliInfo.resumeDirectory, F.workspace)
    }

    func testAppOnlyHostHasNoCommands() async throws {
        let sftp = await F.host([S(index: 1, data: F.file(F.conversation("桌面版")))])
        let source = AntigravityHistorySource(provider: sftp)
        _ = try await source.projects()
        XCTAssertNil(source.newSessionCommand(directory: F.workspace))
        XCTAssertNil(source.resumeCommand(sessionID: F.sessionID(1), directory: F.workspace))
        XCTAssertEqual(source.tool, .antigravity)
        XCTAssertTrue(source.supportsSearch)
    }
}
