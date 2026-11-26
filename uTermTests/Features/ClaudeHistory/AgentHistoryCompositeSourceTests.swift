import XCTest
@testable import uTerm

/// 几种工具的数据源合在一起：按工具分派、一种失败不拖累别的、搜索合成一路；以及 `AgentHistoryModel` 怎么用它。
@MainActor
final class AgentHistoryCompositeSourceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private let shop = "/home/dev/shop-api"

    private typealias Session = AgentHistoryFakeSource.Session

    private func claude(hits: Bool = false) -> AgentHistoryFakeSource {
        AgentHistoryFakeSource(tool: .claude, sessions: [
            Session(id: "c-new", projectID: ClaudeProjectPath.encode(shop), resumeDirectory: shop, title: "登录接口偶发 500",
                    modifiedAt: now.addingTimeInterval(-60),
                    items: AgentHistoryFakeSource.turn("c1", ask: "看看登录", answer: "好", at: now),
                    hits: hits ? [AgentHistoryFakeSource.hit("c1.u", before: "看看", match: "登录", after: "")] : []),
            Session(id: "c-old", projectID: ClaudeProjectPath.encode("/home/dev/blog"), resumeDirectory: "/home/dev/blog",
                    title: "写周报", modifiedAt: now.addingTimeInterval(-86_400 * 3),
                    hits: hits ? [AgentHistoryFakeSource.hit("c2.u", before: "", match: "登录", after: "页")] : []),
        ])
    }

    private func codex(supportsSearch: Bool = true, hits: Bool = false, error: (any Error)? = nil,
                       startsSessions: Bool = true) -> AgentHistoryFakeSource {
        AgentHistoryFakeSource(tool: .codex, sessions: [
            Session(id: "x-mid", projectID: "2026-11", projectDirectory: shop, resumeDirectory: shop, title: "订单分页",
                    modifiedAt: now.addingTimeInterval(-3600),
                    items: AgentHistoryFakeSource.turn("x1", ask: "加分页", answer: "加好了", at: now),
                    hits: hits ? [AgentHistoryFakeSource.hit("x1.u", before: "", match: "登录", after: "后分页"),
                                  AgentHistoryFakeSource.hit("x1.a", before: "", match: "登录", after: "", role: .assistant)] : []),
        ], supportsSearch: supportsSearch, startsSessions: startsSessions, projectsError: error)
    }

    // MARK: 工厂

    func testFactoryBuildsEachToolOnce() {
        let sftp = MockSFTP()
        XCTAssertTrue(AgentHistorySources.make(tools: [.claude], provider: sftp, home: "/h") is ClaudeHistorySource,
                      "只要 Claude Code（iOS）：不包一层")
        XCTAssertTrue(AgentHistorySources.make(tools: [.claude, .claude], provider: sftp, home: "/h") is ClaudeHistorySource,
                      "重复要同一种：只建一份，也不包")
        // 四种都有实现：每种工具各建一份、带着自己的 tool，按要的顺序合起来。
        for tool in AgentHistoryTool.allCases {
            XCTAssertEqual(AgentHistorySources.make(tool, provider: sftp, home: "/h")?.tool, tool)
        }
        let all = AgentHistorySources.make(tools: AgentHistoryTool.allCases, provider: sftp, home: "/h")
        XCTAssertEqual((all as? AgentHistoryCompositeSource)?.tools, AgentHistoryTool.allCases)
    }

    func testCompositeKeepsFirstSourcePerTool() {
        let composite = AgentHistoryCompositeSource([claude(), codex(), AgentHistoryFakeSource(tool: .claude, sessions: [])])
        XCTAssertEqual(composite.tools, [.claude, .codex])
    }

    // MARK: 分派

    /// 几种工具列完的先后与注册的顺序不同：每种工具的项目仍落在它自己名下，按工具列会话各自列得出来。
    /// 2026-11-26 实测（build 1548–1556）：Codex 那一格拿到 Cursor 的项目、后面依次错开，Claude Code 慢一步时
    /// 它的项目被交给 Codex 去列，列出空的、不报错，Code 标签页的侧栏整个空掉。
    func testProjectsStayWithTheirToolWhenToolsFinishOutOfOrder() async throws {
        func source(_ tool: AgentHistoryTool, projects: Int) -> AgentHistoryFakeSource {
            AgentHistoryFakeSource(tool: tool, sessions: (0..<projects).map { index in
                Session(id: "\(tool.rawValue)-\(index)", projectID: "p\(index)", title: "t", modifiedAt: now)
            })
        }
        let sources = [source(.claude, projects: 5), source(.codex, projects: 2), source(.cursor, projects: 4),
                       source(.antigravity, projects: 3)]
        // 注册的顺序是 Claude Code、Codex、Cursor、Antigravity，列完的先后正好倒过来（同实测里 Claude Code 最慢）。
        for (source, delay) in zip(sources, [120, 80, 40, 0]) { await source.setProjectsDelay(.milliseconds(delay)) }
        let composite = AgentHistoryCompositeSource(sources)

        let projects = try await composite.projects()
        for source in sources {
            let mine = projects.filter { $0.tool == source.tool }
            XCTAssertEqual(mine.count, ["claude": 5, "codex": 2, "cursor": 4, "antigravity": 3][source.tool.rawValue],
                           "\(source.tool.rawValue) 的项目数")
            XCTAssertTrue(mine.allSatisfy { $0.path.hasPrefix("/fake/\(source.tool.rawValue)/") },
                          "\(source.tool.rawValue) 名下只有它自己的项目")
        }
        let listing = await composite.listAllSessions(in: projects)
        XCTAssertEqual(listing.files.count, 14, "每种工具都列得出自己的会话")
        XCTAssertTrue(listing.failedProjects.isEmpty)
    }

    /// 首次启动时 Codex 要读两千多份记录的开头（实测 2.4 s），Claude Code 几毫秒（用户报的：侧栏首次加载很慢）。
    /// 等够了就先交出列完的那几种，慢的在后台接着列；下一次接着等同一趟，不重新列。
    func testSlowToolDoesNotHoldBackTheOthers() async throws {
        let fast = claude()
        let slow = codex()
        await slow.setProjectsDelay(.milliseconds(800))
        let composite = AgentHistoryCompositeSource([fast, slow], patience: .milliseconds(50))
        let clock = ContinuousClock()

        let started = clock.now
        let first = try await composite.projects()
        XCTAssertLessThan(clock.now - started, .milliseconds(500), "不陪着慢的那一种等")
        XCTAssertEqual(Set(first.map(\.tool)), [.claude])
        let pending = await composite.pendingTools
        XCTAssertEqual(pending, [.codex])
        let failures = await composite.failures
        XCTAssertTrue(failures.isEmpty, "没列完不算失败")

        await composite.waitForPending()
        let second = try await composite.projects()
        XCTAssertEqual(Set(second.map(\.tool)), [.claude, .codex])
        let pendingAfter = await composite.pendingTools
        XCTAssertTrue(pendingAfter.isEmpty)
        let slowCalls = await slow.projectsCalls
        XCTAssertEqual(slowCalls, 1, "接着等上一趟，没有重新列")
    }

    /// 列表先出列完的那几种，慢的列完后并进来；先出来的行不动。
    func testListShowsFastToolsFirstAndMergesTheSlowOneLater() async throws {
        let slow = codex()
        await slow.setProjectsDelay(.milliseconds(600))
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(), slow], patience: .milliseconds(50)),
                                      preferredDirectory: nil, followsCurrentProject: false)
        let clock = ContinuousClock()
        let started = clock.now
        await model.start()
        XCTAssertLessThan(clock.now - started, .milliseconds(450), "不等慢的那一种")
        await drainMetadata(model)
        XCTAssertEqual(model.visibleFiles.map(\.sessionID), ["c-new", "c-old"], "Claude Code 的先出来")
        XCTAssertEqual(model.phase, .ready)

        try await waitUntil { model.visibleFiles.count == 3 }
        XCTAssertEqual(model.visibleFiles.map(\.sessionID), ["c-new", "x-mid", "c-old"], "Codex 列完并进来")
        XCTAssertTrue(model.toolFailures.isEmpty)
    }

    func testDispatchesByTool() async throws {
        let composite = AgentHistoryCompositeSource([claude(), codex()])
        let projects = try await composite.projects()
        XCTAssertEqual(projects.map(\.tool), [.claude, .codex, .claude], "合在一起按修改时间排")
        let all = await composite.allSessions(in: projects)
        XCTAssertEqual(all.map(\.sessionID), ["c-new", "x-mid", "c-old"])

        let codexProject = try XCTUnwrap(projects.first { $0.tool == .codex })
        let codexFiles = try await composite.sessions(in: codexProject)
        XCTAssertEqual(codexFiles.map(\.sessionID), ["x-mid"])
        let info = try await composite.metadata(for: codexFiles[0])
        XCTAssertEqual(info.title, "订单分页")

        let page = try await composite.transcript(for: codexFiles[0]).loadPrevious()
        XCTAssertEqual(page.items.map(\.id), ["x1.u", "x1.a"], "对话交给那种工具自己的数据源读")
    }

    func testMissingToolFailsInsteadOfMisrouting() async throws {
        let composite = AgentHistoryCompositeSource([claude()])
        let stray = AgentHistoryProject(id: "p", path: "/p", modifiedAt: nil, tool: .cursor)
        let file = AgentHistorySessionFile(sessionID: "s", project: stray, path: "/p/s", size: 1, modifiedAt: now)
        do {
            _ = try await composite.sessions(in: stray)
            XCTFail("没有 Cursor 的数据源，不该交给 Claude 的")
        } catch {}
        do {
            _ = try await composite.transcript(for: file).loadPrevious()
            XCTFail("对话也不该交给别的工具")
        } catch {}
    }

    // MARK: 一种失败不拖累别的

    func testOneToolFailingKeepsTheOthers() async throws {
        let composite = AgentHistoryCompositeSource([claude(), codex(error: AgentHistoryFakeError.offline)])
        let projects = try await composite.projects()
        XCTAssertEqual(Set(projects.map(\.tool)), [.claude])
        let failures = await composite.failures
        XCTAssertEqual(failures.keys.sorted { $0.rawValue < $1.rawValue }, [.codex])
    }

    func testAllFailingThrows() async {
        let composite = AgentHistoryCompositeSource([
            AgentHistoryFakeSource(tool: .claude, sessions: [], projectsError: AgentHistoryFakeError.offline),
            codex(error: AgentHistoryFakeError.missing),
        ])
        do {
            _ = try await composite.projects()
            XCTFail("全都失败要抛错")
        } catch {
            XCTAssertEqual(error as? AgentHistoryFakeError, .offline, "抛的是第一种的错")
        }
    }

    /// 成功的那几种一条记录都没有、又有一种失败了：报失败（能重试），不说「没有历史会话」。
    func testEmptyPlusFailureThrows() async {
        let composite = AgentHistoryCompositeSource([AgentHistoryFakeSource(tool: .claude, sessions: []),
                                                     codex(error: AgentHistoryFakeError.offline)])
        do {
            _ = try await composite.projects()
            XCTFail("要抛错")
        } catch {}
    }

    // MARK: 搜索

    func testSearchSkipsUnsupportedToolsAndMergesByRecency() async throws {
        let claudeSource = claude(hits: true)
        let codexSource = codex(supportsSearch: false, hits: true)
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claudeSource, codexSource]),
                                      preferredDirectory: nil, followsCurrentProject: false)
        await model.start()
        await drainMetadata(model)
        XCTAssertEqual(model.searchExcludedTools, [.codex])

        model.searchText = "登录"
        model.submitSearch()
        try await waitUntil { model.search?.phase == .finished }

        let searched = await codexSource.searchedPaths
        XCTAssertTrue(searched.isEmpty, "不能搜的工具不发命令")
        XCTAssertEqual(model.search?.sessions.map(\.file.sessionID), ["c-new", "c-old"])
    }

    func testSearchAcrossToolsCombinesProgressAndOrdersSessions() async throws {
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(hits: true), codex(hits: true)]),
                                      preferredDirectory: nil, followsCurrentProject: false)
        await model.start()
        await drainMetadata(model)
        model.searchText = "登录"
        model.submitSearch()
        try await waitUntil { model.search?.phase == .finished }

        let search = try XCTUnwrap(model.search)
        XCTAssertEqual(search.sessions.map(\.file.sessionID), ["c-new", "x-mid", "c-old"], "几路的结果按会话新旧排")
        XCTAssertEqual(search.total, 3)
        XCTAssertEqual(search.searched, 3)
        XCTAssertFalse(search.truncated)
    }

    func testSearchStopsAtTotalHitsAcrossTools() async throws {
        let limits = AgentHistorySearchLimits(totalHits: 2, hitsPerSession: 5, candidateLinesPerSession: 30, maxLineBytes: 1024)
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(hits: true), codex(hits: true)]),
                                      preferredDirectory: nil, searchLimits: limits, followsCurrentProject: false)
        await model.start()
        await drainMetadata(model)
        model.searchText = "登录"
        model.submitSearch()
        try await waitUntil { model.search?.phase == .finished }

        let search = try XCTUnwrap(model.search)
        XCTAssertLessThanOrEqual(search.hitCount, 2)
        XCTAssertTrue(search.truncated)
    }

    func testSearchFailsOnlyWhenEveryToolFails() async throws {
        let failing = AgentHistoryFakeSource(tool: .codex, sessions: [
            Session(id: "x", projectID: "p", projectDirectory: "/p", modifiedAt: now),
        ], searchError: AgentHistorySearchError.missingTools)
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(hits: true), failing]),
                                      preferredDirectory: nil, followsCurrentProject: false)
        await model.start()
        await drainMetadata(model)
        model.searchText = "登录"
        model.submitSearch()
        try await waitUntil { model.search?.phase == .finished }
        XCTAssertEqual(model.search?.sessions.count, 2, "Codex 搜不了，Claude 的结果照常出")
    }

    func testOnlyUnsupportedToolsInScopeExplainsInsteadOfSearching() async throws {
        let only = codex(supportsSearch: false, hits: true)
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(), only]), preferredDirectory: nil,
                                      followsCurrentProject: false)
        await model.start()
        model.setShownTools([.codex])
        model.searchText = "登录"
        model.submitSearch()
        XCTAssertEqual(model.search?.phase, .failed(AgentHistoryText.searchUnsupported([.codex])))
        let searched = await only.searchedPaths
        XCTAssertTrue(searched.isEmpty)
    }

    // MARK: 模型

    func testModelKnowsWhichToolsArePresent() async throws {
        let mixed = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(), codex()]), preferredDirectory: nil,
                                      followsCurrentProject: false)
        await mixed.start()
        XCTAssertEqual(mixed.availableTools, [.claude, .codex])
        XCTAssertTrue(mixed.isMultiTool)
        XCTAssertEqual(mixed.scope, .all)

        // 建了两种的数据源，主机上只有一种的记录：收敛成一种（不出工具标记、「工具」分组、「显示」）。
        let single = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(), AgentHistoryFakeSource(tool: .codex, sessions: [])]),
                                       preferredDirectory: nil, followsCurrentProject: false)
        await single.start()
        XCTAssertEqual(single.availableTools, [.claude])
        XCTAssertFalse(single.isMultiTool)
        single.setShownTools([.codex])
        XCTAssertEqual(single.files.count, 2, "只有一种工具时「显示」的选择不起作用")
    }

    func testShownToolsFilterListAndDeselect() async throws {
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(), codex()]), preferredDirectory: nil,
                                      followsCurrentProject: false)
        await model.start()
        await drainMetadata(model)
        let codexFile = try XCTUnwrap(model.visibleFiles.first { $0.tool == .codex })
        model.select(codexFile)

        model.setShownTools([.claude])
        XCTAssertEqual(model.files.map(\.sessionID), ["c-new", "c-old"])
        XCTAssertEqual(model.visibleFiles.map(\.sessionID), ["c-new", "c-old"], "读过的信息都还在，不用重读")
        XCTAssertNil(model.selectedFile, "选中的会话被筛掉了")

        model.setShownTools(nil)
        XCTAssertEqual(model.visibleFiles.map(\.sessionID), ["c-new", "x-mid", "c-old"])
    }

    func testToolFailuresReachModel() async throws {
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(), codex(error: AgentHistoryFakeError.offline)]),
                                      preferredDirectory: nil, followsCurrentProject: false)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(model.toolFailures[.codex])
        XCTAssertEqual(model.availableTools, [.claude])
    }

    /// 后台重列时一种工具连项目都没列出来（辅助程序断了一下）：它上一次列到的会话留着，不从侧栏上一下子全消失。
    func testBackgroundReloadKeepsSessionsOfAToolThatFailedToList() async throws {
        let failing = codex()
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(), failing]), preferredDirectory: nil,
                                      followsCurrentProject: false)
        await model.start()
        await drainMetadata(model)
        XCTAssertEqual(model.visibleFiles.map(\.sessionID), ["c-new", "x-mid", "c-old"])

        await failing.setProjectsError(AgentHistoryFakeError.offline)
        await model.reload(showsLoading: false)
        await drainMetadata(model)
        XCTAssertNotNil(model.toolFailures[.codex])
        XCTAssertEqual(model.visibleFiles.map(\.sessionID), ["c-new", "x-mid", "c-old"], "列不出来的那种工具的会话留着")

        await failing.setProjectsError(nil)
        await model.reload(showsLoading: false)
        XCTAssertNil(model.toolFailures[.codex])
        XCTAssertEqual(model.visibleFiles.map(\.sessionID), ["c-new", "x-mid", "c-old"])
    }

    func testCurrentProjectAcrossToolsPicksNearest() async throws {
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(), codex()]),
                                      preferredDirectory: shop + "/internal")
        await model.start()
        let current = try XCTUnwrap(model.currentProject)
        XCTAssertEqual(current.directory, shop)
        XCTAssertEqual(model.scope, .project(current), "iOS 照旧落在当前项目上")
    }

    func testResumeAndNewSessionCommandsRouteByTool() async throws {
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude(), codex(startsSessions: false)]),
                                      preferredDirectory: nil, followsCurrentProject: false)
        await model.start()
        await drainMetadata(model)
        let codexFile = try XCTUnwrap(model.visibleFiles.first { $0.tool == .codex })
        XCTAssertEqual(model.resumeCommand(for: codexFile)?.command, "cd -- '\(shop)' && codex resume x-mid")
        let claudeFile = try XCTUnwrap(model.visibleFiles.first { $0.tool == .claude })
        XCTAssertEqual(model.resumeCommand(for: claudeFile)?.command, "cd -- '\(shop)' && claude resume c-new")

        XCTAssertEqual(model.newSessionTools(directory: shop), [.claude], "不能在终端里新开的工具不进可选项")
        XCTAssertEqual(model.newSessionCommand(tool: .claude, directory: shop), "cd -- '\(shop)' && claude")
        XCTAssertEqual(model.newSessionTools(directory: nil), [])
    }

    // MARK: Claude Code 的新会话命令

    func testClaudeNewSessionCommandQuotesDirectory() {
        let source = ClaudeHistorySource(provider: MockSFTP(), home: "/h")
        XCTAssertEqual(source.newSessionCommand(directory: "/home/dev/it's here"), #"cd -- '/home/dev/it'\''s here' && claude"#)
        XCTAssertNil(source.newSessionCommand(directory: "relative/dir"))
        XCTAssertNil(source.newSessionCommand(directory: "/tmp/a\nrm -rf ~"))
    }

    // MARK: 辅助

    /// 列表读完一批会话信息（假数据源立刻返回）。
    private func drainMetadata(_ model: AgentHistoryModel) async {
        for _ in 0..<200 where model.hasMore || model.isListing {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "等不到")
    }
}
