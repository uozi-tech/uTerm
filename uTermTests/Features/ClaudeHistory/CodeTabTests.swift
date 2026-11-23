import UPaneGroups
import XCTest
@testable import uTerm

/// Code 标签页：右边三种状态、继续 / 新开在本标签页里跑、切走再切回、程序退出后回到记录、新会话对上真实记录、关标签页；
/// 两种宿主（SSH 的终端区、本机终端窗口）里开得出来、不进保持进程的布局。终端都是假的，不连主机、不起 shell。
@MainActor
final class CodeTabTests: XCTestCase {
    /// 假终端：记下打进去的命令、有没有被结束；「命令跑完了」由用例拨。不碰终端引擎（`CodeTabModel` 只认这个协议）。
    private final class FakeTerminal: CodeTabTerminal {
        let id = UUID()
        let directory: String
        private(set) var command: String?
        private(set) var disposed = false
        var codeCommandHasEnded = false
        init(directory: String) { self.directory = directory }
        func runCodeCommand(_ command: String) { self.command = command }
        func dispose() { disposed = true }
    }

    private typealias Session = AgentHistoryFakeSource.Session
    private static let shop = "/srv/shop"
    private static let infra = "/srv/infra"

    private var made: [FakeTerminal] = []

    private func makeCode(sessions: [Session], directory: String? = CodeTabTests.shop) async
        -> (CodeTabModel, AgentHistoryModel, AgentHistoryFakeSource) {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = AgentHistoryModel(source: source, preferredDirectory: directory, followsCurrentProject: false)
        await history.start()
        await settle(history)
        let code = CodeTabModel(hostName: "prod-web-01", directory: directory) { [unowned self] directory in
            let terminal = FakeTerminal(directory: directory)
            made.append(terminal)
            return terminal
        }
        code.install(AgentHistoryConnection(history: history))
        return (code, history, source)
    }

    private func settle(_ history: AgentHistoryModel) async {
        for _ in 0..<200 where history.hasMore || history.isListing {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func session(_ id: String, in directory: String, title: String, ago seconds: TimeInterval) -> Session {
        Session(id: id, projectID: ClaudeProjectPath.encode(directory), resumeDirectory: directory, title: title,
                modifiedAt: Date().addingTimeInterval(-seconds))
    }

    private func file(_ history: AgentHistoryModel, _ id: String) throws -> AgentHistorySessionFile {
        try XCTUnwrap(history.files.first { $0.sessionID == id })
    }

    // MARK: 右边三种状态

    func testDetailFollowsSelectionAndRuns() async throws {
        let (code, history, _) = await makeCode(sessions: [
            session("a", in: Self.shop, title: "登录接口偶发 500", ago: 600),
            session("b", in: Self.infra, title: "升级 nginx", ago: 3600),
        ])
        XCTAssertEqual(code.detail, .empty, "没选会话")

        let a = try file(history, "a")
        history.select(a)
        XCTAssertEqual(code.detail, .transcript, "没在跑的会话：只读对话")

        let run = try XCTUnwrap(code.resume(a))
        XCTAssertEqual(code.detail, .terminal(run.id), "继续之后右边就是它的终端，留在这个标签页里")
        XCTAssertEqual(run.path, a.path)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].directory, Self.shop, "终端开在会话的目录里")
        XCTAssertEqual(made[0].command, "cd -- '\(Self.shop)' && claude resume a")
        XCTAssertTrue(code.displayedTerminal === made[0])
    }

    func testSwitchingAwayKeepsTheRunAndSwitchingBackShowsItsTerminal() async throws {
        let (code, history, _) = await makeCode(sessions: [
            session("a", in: Self.shop, title: "登录接口偶发 500", ago: 600),
            session("b", in: Self.infra, title: "升级 nginx", ago: 3600),
        ])
        let a = try file(history, "a"), b = try file(history, "b")
        let run = try XCTUnwrap(code.resume(a))

        history.select(b)
        code.historySelectionChanged()
        XCTAssertEqual(code.detail, .transcript, "点别的会话：看它的记录")
        XCTAssertEqual(code.runs.count, 1, "不打断正在跑的")
        XCTAssertFalse(made[0].disposed)
        XCTAssertNil(code.displayedTerminal)

        code.selectRun(run.id)
        XCTAssertEqual(history.selectedFile?.path, a.path)
        XCTAssertEqual(code.detail, .terminal(run.id), "点回去就回到它的终端")

        XCTAssertTrue(code.resume(a)?.id == run.id, "再点「继续」不再起一个")
        XCTAssertEqual(made.count, 1)
    }

    func testTerminalAndRecordToggle() async throws {
        let (code, history, _) = await makeCode(sessions: [session("a", in: Self.shop, title: "t", ago: 60)])
        let run = try XCTUnwrap(code.resume(try file(history, "a")))
        code.setShowsTranscript(true, for: run.id)
        XCTAssertEqual(code.detail, .transcript, "切到「记录」")
        XCTAssertEqual(code.displayedRun?.id, run.id, "顶上那条还是这个跑着的会话")
        code.setShowsTranscript(false, for: run.id)
        XCTAssertEqual(code.detail, .terminal(run.id))
    }

    func testRunEndsWhenTheProgramExitsAndTheRecordComesBack() async throws {
        let (code, history, _) = await makeCode(sessions: [session("a", in: Self.shop, title: "t", ago: 60)])
        let a = try file(history, "a")
        let run = try XCTUnwrap(code.resume(a))
        let before = history.transcript

        code.checkRuns()
        XCTAssertEqual(code.runs.count, 1, "命令还没跑完")

        made[0].codeCommandHasEnded = true
        code.checkRuns()
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertTrue(made[0].disposed, "程序退出了：这个终端结束")
        XCTAssertEqual(code.detail, .transcript, "回到只读对话")
        XCTAssertEqual(history.selectedFile?.path, a.path)
        XCTAssertFalse(history.transcript === before, "记录从末尾重新读到最新")
        XCTAssertFalse(code.runs.contains { $0.id == run.id })
    }

    /// Mac 的终端怎么算「跑完了」：命令的结束标记到了，或者 shell 退出；连接失败不算（面板上给重试）。
    func testMacTerminalEndsOnFinishedCommandNotOnFailure() {
        let pane = PaneModel(serverProfileID: UUID())
        pane.runCodeCommand("claude")
        XCTAssertEqual(pane.session.trackedRun?.command, "claude")
        XCTAssertEqual(pane.session.trackedRun?.inSubshell, false, "不包子 shell")
        XCTAssertFalse(pane.codeCommandHasEnded)
        pane.session.markFailed("x")
        XCTAssertFalse(pane.codeCommandHasEnded, "连接失败不算结束")
        pane.session.trackedRun?.phase = .finished(0)
        XCTAssertTrue(pane.codeCommandHasEnded)
    }

    // MARK: 新会话与真实记录

    func testNewSessionGetsMergedIntoTheRealRecordOnce() async throws {
        let (code, history, source) = await makeCode(sessions: [session("old", in: Self.shop, title: "旧的", ago: 600)])
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "cd -- '/srv/shop' && claude",
                                                      directory: Self.shop))
        XCTAssertNil(run.path)
        XCTAssertEqual(code.detail, .terminal(run.id), "新会话直接在右边跑")
        XCTAssertNil(history.selectedFile)
        XCTAssertEqual(code.runningRows().map(\.title), [AgentHistoryText.newSession], "「正在运行」里先是一行「新会话」")

        await code.refreshList()
        XCTAssertNil(code.runs.first?.path, "记录还没写出来：对不上，留着")
        XCTAssertEqual(code.runs.count, 1)

        await source.add(session("fresh", in: Self.shop, title: "给订单接口加分页", ago: -1))
        await code.refreshList()
        await settle(history)
        code.matchNewSessions()
        let merged = try XCTUnwrap(code.runs.first)
        XCTAssertEqual(merged.path, try file(history, "fresh").path, "对上了起之后才出现的那一份")
        XCTAssertEqual(history.selectedFile?.sessionID, "fresh", "右边看着它的继续看着它：改由列表选中那份记录")
        XCTAssertEqual(code.detail, .terminal(run.id))
        XCTAssertEqual(code.runningRows().map(\.title), ["给订单接口加分页"], "换成记录的标题，不重复")
        XCTAssertEqual(code.runs.count, 1)
    }

    func testMatchRules() {
        let now = Date()
        func file(_ id: String, tool: AgentHistoryTool = .claude, directory: String, modified: TimeInterval)
            -> AgentHistorySessionFile {
            let project = AgentHistoryProject(id: tool == .claude ? ClaudeProjectPath.encode(directory) : "2026-11-20",
                                              path: "/fake/\(id)", modifiedAt: nil,
                                              directory: tool == .claude ? nil : directory, tool: tool)
            return AgentHistorySessionFile(sessionID: id, project: project, path: "/fake/\(id).jsonl", size: 1,
                                           modifiedAt: now.addingTimeInterval(modified))
        }
        func run(tool: AgentHistoryTool = .claude, directory: String, known: Set<String> = []) -> CodeTabModel.Run {
            CodeTabModel.Run(terminal: FakeTerminal(directory: directory), tool: tool, directory: directory,
                             startedAt: now, path: nil, knownPaths: known, title: nil)
        }
        let shop = run(directory: Self.shop, known: ["/fake/old.jsonl"])
        let files = [
            file("old", directory: Self.shop, modified: 5),
            file("other-dir", directory: Self.infra, modified: 5),
            file("codex", tool: .codex, directory: Self.shop, modified: 5),
            file("stale", directory: Self.shop, modified: -3600),
            file("new", directory: Self.shop, modified: 3),
            file("newer", directory: Self.shop, modified: 8),
        ]
        XCTAssertEqual(CodeTabModel.match([shop], files: files, metadata: [:], claimed: []),
                       [shop.id: "/fake/newer.jsonl"],
                       "同工具、同目录、起之后才出现的；有几份取最近改过的")
        XCTAssertEqual(CodeTabModel.match([shop], files: files, metadata: [:], claimed: ["/fake/newer.jsonl"]),
                       [shop.id: "/fake/new.jsonl"], "被别的会话占着的不要")
        let codex = run(tool: .codex, directory: Self.shop)
        XCTAssertEqual(CodeTabModel.match([codex], files: files, metadata: [:], claimed: []), [codex.id: "/fake/codex.jsonl"],
                       "Codex 的项目带着目录")
        let twin = run(directory: Self.shop)
        XCTAssertTrue(CodeTabModel.match([shop, twin], files: files, metadata: [:], claimed: []).isEmpty,
                      "同一个目录同时等着两个新会话：分不清，都不对")
    }

    // MARK: 关标签页

    func testCloseEndsEveryRun() async throws {
        let (code, history, _) = await makeCode(sessions: [
            session("a", in: Self.shop, title: "a", ago: 60),
            session("b", in: Self.infra, title: "b", ago: 120),
        ])
        _ = code.resume(try file(history, "a"))
        _ = code.resume(try file(history, "b"))
        _ = code.startNewSession(tool: .claude, command: "claude", directory: Self.shop)
        XCTAssertEqual(code.terminals.count, 3)
        code.close()
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertTrue(made.allSatisfy(\.disposed), "确认后这些会话一起结束")
        XCTAssertNil(code.startNewSession(tool: .claude, command: "claude", directory: Self.shop), "关了就不再起")
    }

    func testClosePromptCountsBusySessions() {
        XCTAssertNil(TerminalClosePrompt.forTab([.idle, .idle], tabName: "Code"), "都停在提示符上：不问")
        XCTAssertEqual(TerminalClosePrompt.forTab([.running("claude"), .idle], tabName: "Code"),
                       TerminalActivity.running("claude").closePrompt(tabName: "Code"), "只有一个在跑：和普通标签页说的一样")
        let many = TerminalClosePrompt.forTab([.running("claude"), .unknown, .idle], tabName: "Code")
        XCTAssertNotNil(many)
        XCTAssertTrue(many?.title.contains("2") == true, "好几个：说个数")
    }

    // MARK: SSH 的终端区

    func testWorkspaceOpensCodeTabForTheFrontHostAndKeepsItOutOfTheLayout() throws {
        let workspace = WorkspaceModel()
        let host = UUID(), other = UUID()
        workspace.openServer(profileID: host, title: "prod-web-01")
        let codeID = workspace.openCodeTab(fallbackServerID: other) { $0 == host ? "prod-web-01" : "fallback" }
        let tab = try XCTUnwrap(workspace.terminalGroups.tab(codeID))
        let code = try XCTUnwrap(tab.payload.codeTab)
        XCTAssertEqual(tab.payload.serverProfileID, host, "开的是前台标签页那台")
        XCTAssertEqual(code.hostName, "prod-web-01")
        XCTAssertEqual(workspace.terminalGroups.activeTab?.id, codeID)
        XCTAssertEqual(workspace.focusedTerminalServerID, host, "标题栏跟着 Code 标签页的主机")
        XCTAssertNil(workspace.focusedTerminalSession(), "右边没有终端")

        XCTAssertNil(WorkspaceModel.heldSessionID(tab), "Code 标签页不进保持进程的布局")
        XCTAssertEqual(workspace.snapshot().terminalGroups?.groups.flatMap(\.tabs).count, 1, "也不进工作区快照")

        let empty = WorkspaceModel()
        let fallbackID = empty.openCodeTab(fallbackServerID: other) { _ in "fallback" }
        XCTAssertEqual(empty.terminalGroups.tab(fallbackID)?.payload.serverProfileID, other, "一个标签页都没有：开本窗口那台")
        workspace.dispose()
        empty.dispose()
    }

    func testWorkspaceRunsAreRealTerminalsOutsideTheTree() throws {
        let workspace = WorkspaceModel()
        let host = UUID()
        var connected: [UUID] = []
        workspace.connectCodeRun = { connected.append($0.id) }
        workspace.openServer(profileID: host, title: "prod-web-01")
        let codeID = workspace.openCodeTab(fallbackServerID: host) { _ in "prod-web-01" }
        let code = try XCTUnwrap(workspace.terminalGroups.tab(codeID)?.payload.codeTab)
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: Self.shop))
        let pane = try XCTUnwrap(run.terminal as? PaneModel)

        XCTAssertEqual(connected, [pane.id], "建好就去连，不等面板显示出来")
        XCTAssertEqual(pane.serverProfileID, host)
        XCTAssertEqual(pane.tabTitle, "prod-web-01", "重启后以普通标签页接回时的名字")
        XCTAssertEqual(workspace.terminalGroups.allTabs.count, 2, "不在标签树里")
        XCTAssertTrue(workspace.terminalPanes.contains { $0 === pane }, "关窗口的确认、注册表都看得到它")
        XCTAssertTrue(workspace.terminalSessions.contains { $0 === pane.session })
        XCTAssertEqual(workspace.focusedTerminalSessionID, pane.id, "右边是它的终端时它就是前台会话")
        XCTAssertTrue(workspace.focusedTerminalSession() === pane.session)

        // 点系统通知回到它：切到 Code 标签页，右边换成它。
        workspace.terminalGroups.activateTab(groupID: try XCTUnwrap(workspace.terminalGroups.activeGroupID), index: 0)
        XCTAssertTrue(workspace.revealTerminal(paneID: pane.id))
        XCTAssertEqual(workspace.terminalGroups.activeTab?.id, codeID)
        XCTAssertEqual(code.detail, .terminal(pane.id))

        // 挪成普通标签页：同一条会话，不重开。
        workspace.moveCodeRunToTab(pane.id, fromCodeTab: codeID)
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertTrue(workspace.terminalGroups.tab(pane.id)?.payload === pane)
        XCTAssertEqual(WorkspaceModel.heldSessionID(try XCTUnwrap(workspace.terminalGroups.tab(pane.id))), pane.id)
        workspace.dispose()
    }

    func testWorkspaceCloseTerminalEndsARunAndClosingTheTabEndsTheRest() throws {
        let workspace = WorkspaceModel()
        let host = UUID()
        let codeID = workspace.openCodeTab(serverID: host, hostName: "h", directory: Self.shop)
        let code = try XCTUnwrap(workspace.terminalGroups.tab(codeID)?.payload.codeTab)
        let first = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: Self.shop))
        let second = try XCTUnwrap(code.startNewSession(tool: .codex, command: "codex", directory: Self.shop))

        XCTAssertTrue(workspace.closeTerminal(paneID: first.id), "手机远控「同时关闭 Mac 上的终端」")
        XCTAssertEqual(code.runs.map(\.id), [second.id])

        workspace.terminalGroups.closeTabs { $0.id == codeID }
        XCTAssertTrue(code.runs.isEmpty, "关 Code 标签页：里面的会话一起结束")
        XCTAssertTrue(workspace.terminalPanes.isEmpty)
        workspace.dispose()
    }

    func testRightClickHistoryReusesTheCodeTabInTheSameGroup() throws {
        let workspace = WorkspaceModel()
        let host = UUID()
        let terminalID = workspace.openServer(profileID: host, title: "prod-web-01")
        let terminal = try XCTUnwrap(workspace.terminalGroups.tab(terminalID)?.payload)

        workspace.showCodeTab(for: terminal, hostName: "prod-web-01")
        XCTAssertEqual(workspace.terminalGroups.allTabs.count, 2, "没有就新开")
        let codeTab = try XCTUnwrap(workspace.terminalGroups.activeTab)
        XCTAssertNotNil(codeTab.payload.codeTab)

        workspace.terminalGroups.activateTab(groupID: try XCTUnwrap(workspace.terminalGroups.activeGroupID), index: 0)
        workspace.showCodeTab(for: terminal, hostName: "prod-web-01")
        XCTAssertEqual(workspace.terminalGroups.allTabs.count, 2, "组里已经有同一台主机的：切过去")
        XCTAssertEqual(workspace.terminalGroups.activeTab?.id, codeTab.id)

        let otherHost = workspace.openServer(profileID: UUID(), title: "other")
        workspace.showCodeTab(for: try XCTUnwrap(workspace.terminalGroups.tab(otherHost)?.payload), hostName: "other")
        XCTAssertEqual(workspace.terminalGroups.allTabs.filter { $0.payload.codeTab != nil }.count, 2, "别的主机另开一个")
        workspace.dispose()
    }

    func testRevealRequestRepeats() {
        let code = CodeTabModel(hostName: "h", directory: nil) { _ in nil }
        code.requestReveal(directory: "/srv/app")
        let first = code.reveal
        XCTAssertEqual(first?.directory, "/srv/app")
        code.requestReveal(directory: "/srv/app")
        XCTAssertNotEqual(code.reveal, first, "同一个目录再要一次也要再滚过去")
        code.requestReveal(directory: nil)
        XCTAssertEqual(code.reveal?.directory, "/srv/app", "不知道目录就只切过去，不动列表")
    }

    // MARK: 本机终端窗口

    func testLocalShellWindowOpensCodeTabAndRunsShellsInIt() throws {
        var started: [UUID] = []
        let model = LocalShellWindowModel(startShell: { started.append($0.id) })
        let shell = model.addTab(directory: "/Users/me/shop")
        let codeID = model.openCodeTab(in: model.groups.activeGroupID)
        let tab = try XCTUnwrap(model.groups.tab(codeID))
        let code = try XCTUnwrap(tab.payload.codeTab)
        XCTAssertEqual(started, [shell], "Code 标签页本身不起 shell")
        XCTAssertEqual(code.newSessionDirectory, "/Users/me/shop", "「＋」新会话的目录取前台标签页的")
        XCTAssertEqual(code.hostName, LocalShellIdentity.serverName)
        XCTAssertNil(LocalShellWindowModel.heldSessionID(tab), "不进保持进程的布局")
        XCTAssertEqual(model.panes.map(\.id), [shell], "也不算一个 shell")
        XCTAssertNil(model.focusedSessionID)

        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: "/Users/me/shop"))
        let pane = try XCTUnwrap(run.terminal as? LocalShellPane)
        XCTAssertEqual(started, [shell, pane.id], "继续 / 新开在 Code 标签页里起一个真的本机 shell")
        XCTAssertEqual(pane.workingDirectory, "/Users/me/shop")
        XCTAssertEqual(pane.session.trackedRun?.command, "claude", "命令交给这个 shell 的会话")
        XCTAssertEqual(model.groups.allTabs.count, 2, "不另开标签页")
        XCTAssertEqual(Set(model.panes.map(\.id)), [shell, pane.id], "关窗口的确认、退出流程看得到它")
        XCTAssertEqual(model.focusedSessionID, pane.id)
        XCTAssertEqual(model.pane(pane.id)?.defaultTitle, pane.defaultTitle)

        model.groups.activateTab(groupID: try XCTUnwrap(model.groups.activeGroupID), index: 0)
        XCTAssertTrue(model.reveal(pane.id), "点系统通知回到它")
        XCTAssertEqual(model.active?.id, codeID)

        XCTAssertTrue(model.close(pane.id), "手机远控关它：只结束这个 shell")
        XCTAssertTrue(pane.isDisposed)
        XCTAssertEqual(model.groups.allTabs.count, 2)
        model.disposeAll()
    }

    func testLocalShellRightClickHistoryReusesAndMovesRunToTab() throws {
        let model = LocalShellWindowModel(startShell: { _ in })
        let shellID = model.addTab(directory: "/Users/me/blog")
        let shell = try XCTUnwrap(model.groups.tab(shellID)?.payload)
        model.showCodeTab(for: shell)
        let codeTab = try XCTUnwrap(model.active)
        let code = try XCTUnwrap(codeTab.codeTab)
        XCTAssertEqual(code.reveal?.directory, "/Users/me/blog", "定位到那个 shell 所在目录的那一组")

        model.groups.activateTab(groupID: try XCTUnwrap(model.groups.activeGroupID), index: 0)
        model.showCodeTab(for: shell)
        XCTAssertEqual(model.groups.allTabs.count, 2, "组里已经有了：切过去")
        XCTAssertEqual(model.active?.id, codeTab.id)

        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: "/Users/me/blog"))
        model.moveCodeRunToTab(run.id, fromCodeTab: codeTab.id)
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertEqual(model.groups.allTabs.count, 3, "挪成普通标签页")
        XCTAssertNotNil(LocalShellWindowModel.heldSessionID(try XCTUnwrap(model.groups.tab(run.id))))

        // ⌘W 按标签页数：三个标签页时只关前台那个（Code 标签页里跑着的不算标签页）。
        var closedWindow = false
        model.handleCloseShortcut { closedWindow = true }
        XCTAssertFalse(closedWindow)
        model.disposeAll()
    }

    // MARK: 模式开关

    func testTerminalWindowModeToggleHasTwoSegments() {
        XCTAssertEqual(TerminalWindowContentMode.allCases, [.terminal, .agent], "Code 是标签页，不是一档模式")
    }
}
