import UPaneGroups
import XCTest
@testable import uTerm

/// 设备请 Mac 在它的 Code 标签页里做的事（远控 64 号消息）落到本机终端窗口上：`LocalShellWindowModel.performCodeTabAction`
/// 与找窗口的 `LocalShellCodeTabActions.perform`。继续（列表里有的、还没列到的、已经在跑的）、新会话、重新开始、移到新标签页、
/// 认不出的动作；Mac 上还没有 Code 标签页、连本机终端窗口都没有的时候。
///
/// shell 接的是假后端（`MockBackend`），不起真 shell；记录是内存里的假数据源。设备那头的 Code 标签页靠 63 号消息，
/// 它的来源是注册表的 `codeTabs()`，这里一并核对。
@MainActor
final class CodeTabRemoteActionTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private static let shop = "/srv/shop"

    private var models: [LocalShellWindowModel] = []
    private var backends: [UUID: MockBackend] = [:]

    override func tearDown() async throws {
        for model in models { model.disposeAll() }
        models = []
        backends = [:]
        try await super.tearDown()
    }

    /// 同 `LocalShellWindowView` 的登记（同 `CodeTabRemotePublishTests`）。每个 shell 的假后端记在 `backends`。
    private func window(_ registry: TerminalSessionRegistry) -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { [weak self] pane in
            let backend = MockBackend()
            self?.backends[pane.id] = backend
            Task { await pane.session.connect(using: backend) }
        })
        let id = UUID()
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: id, windowKind: TerminalWindowKind.terminal))
        registry.setTabOrder(forWindow: id) { [weak model] in
            model?.groups.snapshot(LocalShellWindowModel.heldSessionID).tabOrder ?? []
        }
        registry.setCodeTabs(forWindow: id) { [weak model] in model?.remoteCodeTabs() ?? [] }
        registry.setCloser(forWindow: id) { [weak model] paneID in model?.close(paneID) ?? false }
        models.append(model)
        return model
    }

    private func connection(_ source: AgentHistoryFakeSource) async -> AgentHistoryConnection {
        let history = AgentHistoryModel(source: source, preferredDirectory: Self.shop, followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(10)) }
        return AgentHistoryConnection(history: history)
    }

    private func source(_ sessions: [Session] = []) -> AgentHistoryFakeSource {
        AgentHistoryFakeSource(tool: .claude, sessions: sessions)
    }

    private func session(_ id: String, title: String? = "修登录页") -> Session {
        Session(id: id, projectID: ClaudeProjectPath.encode(Self.shop), resumeDirectory: Self.shop, title: title,
                modifiedAt: Date().addingTimeInterval(-600))
    }

    /// 开好 Code 标签页、接好列表。
    private func codeTab(in model: LocalShellWindowModel, _ source: AgentHistoryFakeSource) async throws
        -> (id: UUID, code: CodeTabModel) {
        let id = model.openCodeTab(directory: Self.shop)
        let code = try XCTUnwrap(model.groups.tab(id)?.payload.codeTab)
        code.install(await connection(source))
        return (id, code)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func success(_ result: RemoteCodeTabActionResult, _ action: RemoteCodeTabAction,
                         file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        XCTAssertEqual(result.requestID, action.requestID, file: file, line: line)
        XCTAssertNil(result.error, file: file, line: line)
        return try XCTUnwrap(result.session, "没做成：\(result.error ?? "")", file: file, line: line)
    }

    // MARK: 继续

    func test_resume_listed_record_runs_it_in_the_code_tab_and_again_returns_the_same_run() async throws {
        let registry = TerminalSessionRegistry()
        let model = window(registry)
        let shell = model.addTab()
        let fake = source([session("a")])
        let (codeID, code) = try await codeTab(in: model, fake)
        model.reveal(shell)   // 前台是 shell 标签：做完要切回 Code 标签页
        let path = fake.sessionPath(session("a"))

        let action = RemoteCodeTabAction(action: .resume, tab: codeID, path: path, tool: AgentHistoryTool.claude.rawValue,
                                         sessionID: "a", directory: Self.shop)
        let id = try success(await model.performCodeTabAction(action), action)
        let run = try XCTUnwrap(code.runs.first { $0.id == id })
        XCTAssertEqual(run.path, path)
        XCTAssertEqual(run.directory, Self.shop)
        XCTAssertEqual(code.detail, .terminal(id), "Mac 上右边是它的终端")
        XCTAssertEqual(model.active?.id, codeID, "切到 Code 标签页")

        let registered = await waitUntil { registry.entries.contains { $0.id == id } }
        XCTAssertTrue(registered)
        XCTAssertEqual(registry.codeTabs().first?.runs.map(\.session), [id], "设备收到的 63 号消息里有它")
        XCTAssertEqual(registry.codeTabs().first?.runs.first?.path, path)

        let again = RemoteCodeTabAction(action: .resume, tab: codeID, path: path, tool: AgentHistoryTool.claude.rawValue,
                                        sessionID: "a", directory: Self.shop)
        let result1 = await model.performCodeTabAction(again)
        XCTAssertEqual(try success(result1, again), id, "已经在跑：回到它，不再起一个")
        XCTAssertEqual(code.runs.count, 1)
    }

    /// 设备上看得到、Mac 的列表还没列到的记录：照样继续（按会话 ID 现算命令），列表列到之后就是它那一行。
    func test_resume_record_not_listed_yet_still_starts_and_matches_it_later() async throws {
        let registry = TerminalSessionRegistry()
        let model = window(registry)
        let fake = source([session("a")])
        let (codeID, code) = try await codeTab(in: model, fake)
        let late = session("b", title: "刚写出来的会话")
        let path = fake.sessionPath(late)

        let action = RemoteCodeTabAction(action: .resume, tab: codeID, path: path, tool: AgentHistoryTool.claude.rawValue,
                                         sessionID: "b", directory: Self.shop)
        let id = try success(await model.performCodeTabAction(action), action)
        let run = try XCTUnwrap(code.runs.first { $0.id == id })
        XCTAssertEqual(run.key, AgentHistoryPinKey(tool: .claude, sessionID: "b"))
        XCTAssertEqual(run.path, path)
        XCTAssertEqual(run.directory, Self.shop)
        XCTAssertTrue(run.resumesRecord)
        XCTAssertFalse(run.isUnmatched, "不当新会话去对别的记录")
        XCTAssertEqual(code.detail, .terminal(id))

        let again = RemoteCodeTabAction(action: .resume, tab: codeID, path: path, tool: AgentHistoryTool.claude.rawValue,
                                        sessionID: "b", directory: Self.shop)
        let result2 = await model.performCodeTabAction(again)
        XCTAssertEqual(try success(result2, again), id, "还没列到时再点：也回到它")

        await fake.add(late)
        await code.refreshList()
        XCTAssertEqual(code.run(for: path)?.id, id, "列到之后列表里那一行就是它")
        XCTAssertEqual(code.runs.count, 1)

        let result3 = await model.performCodeTabAction(again)
        XCTAssertEqual(try success(result3, again), id, "列到之后再点：还是它")
    }

    func test_resume_without_session_id_or_unknown_tool_fails() async throws {
        let model = window(TerminalSessionRegistry())
        let (codeID, code) = try await codeTab(in: model, source())
        let noID = RemoteCodeTabAction(action: .resume, tab: codeID, path: "/fake/claude/x/c.jsonl",
                                       tool: AgentHistoryTool.claude.rawValue, directory: Self.shop)
        let failed = await model.performCodeTabAction(noID)
        XCTAssertNil(failed.session)
        XCTAssertEqual(failed.error, LocalShellCodeTabText.resumeFailed)

        let alien = RemoteCodeTabAction(action: .resume, tab: codeID, tool: "gemini-cli", sessionID: "c",
                                        directory: Self.shop)
        let result4 = await model.performCodeTabAction(alien)
        XCTAssertEqual(result4.error, LocalShellCodeTabText.unsupportedTool)
        XCTAssertTrue(code.runs.isEmpty)
    }

    // MARK: 新会话

    func test_start_opens_a_new_session_in_the_directory() async throws {
        let registry = TerminalSessionRegistry()
        let model = window(registry)
        let (codeID, code) = try await codeTab(in: model, source([session("a")]))

        let action = RemoteCodeTabAction(action: .start, tab: codeID, tool: AgentHistoryTool.claude.rawValue,
                                         directory: "/srv/infra")
        let id = try success(await model.performCodeTabAction(action), action)
        let run = try XCTUnwrap(code.runs.first { $0.id == id })
        XCTAssertEqual(run.directory, "/srv/infra")
        XCTAssertTrue(run.isUnmatched, "新会话，等对上记录")
        XCTAssertEqual(code.detail, .terminal(id))
        XCTAssertEqual(code.newSessionDirectory, "/srv/infra", "同起始页「开始」")
        let registered = await waitUntil { registry.codeTabs().first?.runs.map(\.session) == [id] }
        XCTAssertTrue(registered)

        // 不给目录：开在 Code 标签页「新会话」的目录里。
        let plain = RemoteCodeTabAction(action: .start, tab: codeID, tool: AgentHistoryTool.claude.rawValue)
        let second = try success(await model.performCodeTabAction(plain), plain)
        XCTAssertEqual(code.runs.first { $0.id == second }?.directory, "/srv/infra")
    }

    func test_start_where_the_tool_cannot_start_fails() async throws {
        let model = window(TerminalSessionRegistry())
        let fake = AgentHistoryFakeSource(tool: .claude, sessions: [], startsSessions: false)
        let (codeID, code) = try await codeTab(in: model, fake)
        let action = RemoteCodeTabAction(action: .start, tab: codeID, tool: AgentHistoryTool.claude.rawValue,
                                         directory: Self.shop)
        let result5 = await model.performCodeTabAction(action)
        XCTAssertEqual(result5.error, LocalShellCodeTabText.startFailed)
        XCTAssertTrue(code.runs.isEmpty)
    }

    // MARK: 重新开始 / 移到新标签页

    func test_restart_ended_run_puts_a_new_run_at_its_place() async throws {
        let registry = TerminalSessionRegistry()
        let model = window(registry)
        let (codeID, code) = try await codeTab(in: model, source())
        let first = try XCTUnwrap(code.startNewSession(tool: .claude, in: Self.shop))
        let second = try XCTUnwrap(code.startNewSession(tool: .claude, in: "/srv/infra"))

        let running = RemoteCodeTabAction(action: .restart, tab: codeID, session: first.id)
        let result6 = await model.performCodeTabAction(running)
        XCTAssertEqual(result6.error, LocalShellCodeTabText.stillRunning,
                       "还在跑的不重新开始")

        // 程序退出（shell 退出也算）：新会话没有记录可看，终端留着、标成已结束。
        let pane = try XCTUnwrap(model.pane(first.id))
        let exited = await waitUntil { self.backends[first.id] != nil && pane.session.connectionState == .connected }
        XCTAssertTrue(exited)
        await backends[first.id]?.emitExit()
        let disconnected = await waitUntil { pane.session.connectionState == .disconnected }
        XCTAssertTrue(disconnected)
        code.checkRuns()
        XCTAssertEqual(code.runs.first?.isEnded, true)

        let action = RemoteCodeTabAction(action: .restart, tab: codeID, session: first.id)
        let id = try success(await model.performCodeTabAction(action), action)
        XCTAssertNotEqual(id, first.id)
        XCTAssertEqual(code.runs.map(\.id), [id, second.id], "新的放在旧的位置上")
        XCTAssertEqual(code.runs.first?.directory, Self.shop)
        XCTAssertEqual(code.detail, .terminal(id), "Mac 上右边是新的")
        let published = await waitUntil { registry.codeTabs().first?.runs.map(\.session) == [id, second.id] }
        XCTAssertTrue(published, "63 号消息里换成新的")

        let gone = RemoteCodeTabAction(action: .restart, tab: codeID, session: first.id)
        let result7 = await model.performCodeTabAction(gone)
        XCTAssertEqual(result7.error, LocalShellCodeTabText.sessionGone)
    }

    func test_move_to_tab_turns_the_run_into_a_tab_of_the_group() async throws {
        let registry = TerminalSessionRegistry()
        let model = window(registry)
        let (codeID, code) = try await codeTab(in: model, source())
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, in: Self.shop))

        let action = RemoteCodeTabAction(action: .moveToTab, tab: codeID, session: run.id)
        let result8 = await model.performCodeTabAction(action)
        XCTAssertEqual(try success(result8, action), run.id, "同一个会话")
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertNotNil(model.groups.locateTab(run.id), "成了普通标签")
        XCTAssertEqual(registry.codeTabs().first?.runs, [])

        let result9 = await model.performCodeTabAction(action)
        XCTAssertEqual(result9.error, LocalShellCodeTabText.sessionGone,
                       "已经挪出去了")
    }

    func test_unknown_action_is_refused() async throws {
        let model = window(TerminalSessionRegistry())
        _ = try await codeTab(in: model, source())
        var action = RemoteCodeTabAction(action: .start, tool: AgentHistoryTool.claude.rawValue, directory: Self.shop)
        action.action = "fork"
        let result = await model.performCodeTabAction(action)
        XCTAssertEqual(result.requestID, action.requestID)
        XCTAssertNil(result.session)
        XCTAssertEqual(result.error, LocalShellCodeTabText.unknownAction)
        let routed = await LocalShellCodeTabActions.perform(action, windows: [model], openWindow: { _ in
            XCTFail("不该开窗口")
            return .failure(.init(message: ""))
        })
        XCTAssertEqual(routed.error, LocalShellCodeTabText.unknownAction)
    }

    // MARK: 还没有 Code 标签页

    /// 窗口里还没有 Code 标签页：先开一个，等它接好列表（宿主的视图出现时才接）再起会话。
    func test_start_without_a_code_tab_opens_one_and_waits_for_its_list() async throws {
        let registry = TerminalSessionRegistry()
        let model = window(registry)
        let shell = model.addTab()
        let fake = source()
        let action = RemoteCodeTabAction(action: .start, tool: AgentHistoryTool.claude.rawValue, directory: Self.shop)
        let task = Task { await model.performCodeTabAction(action) }

        let opened = await waitUntil { model.hasCodeTab }
        XCTAssertTrue(opened)
        let tab = try XCTUnwrap(model.groups.allTabs.first { $0.payload.codeTab != nil })
        let code = try XCTUnwrap(tab.payload.codeTab)
        XCTAssertEqual(code.newSessionDirectory, Self.shop)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(code.runs.isEmpty, "列表接好之前不起")
        code.install(await connection(fake))

        let id = try success(await task.value, action)
        XCTAssertEqual(code.runs.map(\.id), [id])
        XCTAssertEqual(model.active?.id, tab.id)
        XCTAssertNotNil(model.groups.locateTab(shell), "原来的标签不动")
    }

    func test_code_tab_that_never_gets_its_list_fails_in_time() async throws {
        let model = window(TerminalSessionRegistry())
        _ = model.addTab()
        let action = RemoteCodeTabAction(action: .start, tool: AgentHistoryTool.claude.rawValue, directory: Self.shop)
        let result = await model.performCodeTabAction(action, historyWait: .milliseconds(200))
        XCTAssertEqual(result.error, LocalShellCodeTabText.notReady)
        XCTAssertTrue(model.hasCodeTab, "Code 标签页留着")
    }

    /// 有 Code 标签页的窗口优先（这台 Mac 只开一个），不管哪个窗口最近活跃；「重新开始」「移到新标签页」找跑着那个会话的窗口。
    func test_routing_prefers_the_window_with_the_code_tab() async throws {
        let registry = TerminalSessionRegistry()
        let recent = window(registry)
        _ = recent.addTab()
        let owner = window(registry)
        let (codeID, code) = try await codeTab(in: owner, source())

        let start = RemoteCodeTabAction(action: .start, tab: codeID, tool: AgentHistoryTool.claude.rawValue,
                                        directory: Self.shop)
        let id = try success(await LocalShellCodeTabActions.perform(start, windows: [recent, owner], openWindow: { _ in
            XCTFail("不该开窗口")
            return .failure(.init(message: ""))
        }), start)
        XCTAssertEqual(code.runs.map(\.id), [id])
        XCTAssertFalse(recent.hasCodeTab)

        let move = RemoteCodeTabAction(action: .moveToTab, tab: codeID, session: id)
        let moved = await LocalShellCodeTabActions.perform(move, windows: [recent, owner],
                                                           openWindow: { _ in .failure(.init(message: "")) })
        XCTAssertEqual(try success(moved, move), id)
        XCTAssertNotNil(owner.groups.locateTab(id))

        let missing = RemoteCodeTabAction(action: .restart, session: UUID())
        let result = await LocalShellCodeTabActions.perform(missing, windows: [recent, owner],
                                                            openWindow: { _ in .failure(.init(message: "")) })
        XCTAssertEqual(result.error, LocalShellCodeTabText.sessionGone)
    }

    /// Mac 上一个本机终端窗口都没有：开一个，Code 标签页开在里面，窗口起的那个 shell 关掉，只留 Code 标签页。
    func test_no_window_at_all_opens_one_that_holds_only_the_code_tab() async throws {
        let registry = TerminalSessionRegistry()
        let fake = source([session("a")])
        let opened = OpenedWindows()
        let action = RemoteCodeTabAction(action: .resume, path: fake.sessionPath(session("a")),
                                         tool: AgentHistoryTool.claude.rawValue, sessionID: "a", directory: Self.shop)
        let task = Task {
            await LocalShellCodeTabActions.perform(action, windows: [], openWindow: { directory in
                opened.directories.append(directory)
                let model = self.window(registry)
                let first = model.addTab(directory: directory)
                opened.model = model
                return .success(.init(model: model, firstPane: first))
            })
        }
        let hasTab = await waitUntil { opened.model?.hasCodeTab == true }
        XCTAssertTrue(hasTab)
        let model = try XCTUnwrap(opened.model)
        let code = try XCTUnwrap(model.groups.allTabs.first { $0.payload.codeTab != nil }?.payload.codeTab)
        code.install(await connection(fake))

        let id = try success(await task.value, action)
        XCTAssertEqual(opened.directories, [Self.shop])
        XCTAssertEqual(model.groups.allTabs.count, 1, "只留 Code 标签页")
        XCTAssertNotNil(model.groups.allTabs.first?.payload.codeTab)
        XCTAssertEqual(code.runs.map(\.id), [id])
        XCTAssertEqual(code.runs.first?.path, fake.sessionPath(session("a")))

        // 开不了窗口：原因原样回给设备。
        let refused = await LocalShellCodeTabActions.perform(action, windows: [], openWindow: { _ in
            .failure(.init(message: "Mac 上的 uTerm 还没准备好打开窗口，稍后再试"))
        })
        XCTAssertEqual(refused.error, "Mac 上的 uTerm 还没准备好打开窗口，稍后再试")
    }
}

/// 替请求开的窗口（测试里记下开在哪、开出来的是哪个）。
@MainActor
private final class OpenedWindows {
    var directories: [String?] = []
    var model: LocalShellWindowModel?
}
