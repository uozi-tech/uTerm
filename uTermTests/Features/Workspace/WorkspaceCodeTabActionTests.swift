import UPaneGroups
import XCTest
@testable import uTerm

/// 设备请 Mac 在某台 SSH 主机的 Code 标签页里做事（64 号消息带 `server`）：`RemoteCodeTabActor.route` 按主机分流，
/// `WorkspaceCodeTabActions.perform` 在那台主机的窗口里找。继续、新会话（有 Code 标签页的、要新开的）、重新开始、移到新
/// 标签页；那台主机一个窗口都没有时回错误、绝不落到本机终端上；`server` 没带或是本机的照旧交给本机终端窗口；开关没开时
/// 一律拒绝。会话接假后端，不连真主机。
@MainActor
final class WorkspaceCodeTabActionTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private static let shop = "/srv/shop"

    private var rigs: [SSHCodeTabWindowRig] = []
    private var locals: [LocalShellWindowModel] = []

    override func tearDown() async throws {
        for rig in rigs { rig.dispose() }
        for model in locals { model.disposeAll() }
        rigs = []
        locals = []
        try await super.tearDown()
    }

    private func sshWindow(_ registry: TerminalSessionRegistry, name: String = "prod-web") -> SSHCodeTabWindowRig {
        let rig = SSHCodeTabWindowRig(registry: registry, hostName: name)
        rigs.append(rig)
        return rig
    }

    private func localWindow(_ registry: TerminalSessionRegistry) -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { pane in
            Task { await pane.session.connect(using: MockBackend()) }
        })
        let id = UUID()
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: id, windowKind: TerminalWindowKind.terminal))
        registry.setCodeTabs(forWindow: id) { [weak model] in model?.remoteCodeTabs() ?? [] }
        locals.append(model)
        return model
    }

    /// 同 `RemoteCodeTabActor.live` 的分流（开关之后那一步），本机窗口与 SSH 窗口由测试给。
    private func route(_ action: RemoteCodeTabAction, local: [LocalShellWindowModel] = [],
                       registry: TerminalSessionRegistry, historyWait: Duration? = nil) async -> RemoteCodeTabActionResult {
        await RemoteCodeTabActor.route(action, localWindows: local, workspaces: registry.codeTabWorkspaces(),
                                       openLocalWindow: { _ in .failure(.init(message: "不该开本机终端窗口")) },
                                       historyWait: historyWait)
    }

    private func session(_ id: String) -> Session {
        Session(id: id, projectID: ClaudeProjectPath.encode(Self.shop), resumeDirectory: Self.shop, title: "修登录页",
                modifiedAt: Date().addingTimeInterval(-600))
    }

    private func success(_ result: RemoteCodeTabActionResult, _ action: RemoteCodeTabAction,
                         file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        XCTAssertEqual(result.requestID, action.requestID, file: file, line: line)
        XCTAssertNil(result.error, file: file, line: line)
        return try XCTUnwrap(result.session, "没做成：\(result.error ?? "")", file: file, line: line)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: 继续 / 新会话

    /// 两台主机各一个窗口、本机也有 Code 标签页：只交给 `server` 那台的窗口，前台切回它的 Code 标签页。
    func test_start_and_resume_go_to_the_code_tab_of_that_host_only() async throws {
        let registry = TerminalSessionRegistry()
        let local = localWindow(registry)
        let localCode = try XCTUnwrap(local.groups.tab(local.openCodeTab(directory: Self.shop))?.payload.codeTab)
        let other = sshWindow(registry, name: "db")
        let made1 = await other.openCodeTab(directory: Self.shop)
        let (_, otherCode) = try XCTUnwrap(made1)
        let ssh = sshWindow(registry)
        let made2 = await ssh.openTerminal()
        let terminal = try XCTUnwrap(made2)
        let fakeSessions = [session("a")]
        let made3 = await ssh.openCodeTab(directory: Self.shop, sessions: fakeSessions)
        let (codeID, code) = try XCTUnwrap(made3)
        ssh.workspace.revealTerminal(paneID: terminal)   // 前台是终端标签页：做完要切回 Code 标签页

        let start = RemoteCodeTabAction(action: .start, tab: codeID, tool: AgentHistoryTool.claude.rawValue,
                                        directory: Self.shop, server: ssh.host)
        let started = try success(await route(start, local: [local], registry: registry), start)
        XCTAssertEqual(code.runs.map(\.id), [started])
        XCTAssertEqual(ssh.workspace.terminalGroups.activeTab?.payload.id, codeID, "Mac 上切到那个 Code 标签页")
        XCTAssertTrue(otherCode.runs.isEmpty, "别的主机的不动")
        XCTAssertTrue(localCode.runs.isEmpty, "本机的不动")
        let published = await waitUntil {
            registry.codeTabs().first { $0.serverID == ssh.host }?.runs.map(\.session) == [started]
        }
        XCTAssertTrue(published, "63 号消息里有新会话")

        let history = try XCTUnwrap(code.history)
        let path = try XCTUnwrap(history.files.first?.path)
        let resume = RemoteCodeTabAction(action: .resume, tab: codeID, path: path, tool: AgentHistoryTool.claude.rawValue,
                                         sessionID: "a", directory: Self.shop, server: ssh.host)
        let resumed = try success(await route(resume, local: [local], registry: registry), resume)
        XCTAssertEqual(code.runs.map(\.id), [started, resumed])
        XCTAssertEqual(code.runs.last?.path, path)
        XCTAssertTrue(otherCode.runs.isEmpty)
        XCTAssertTrue(localCode.runs.isEmpty)
    }

    /// 那台主机的窗口里还没有 Code 标签页：在连着它的窗口里新开一个，等列表接好再起会话；设备点名的标签页不认得也照样找主机。
    func test_start_opens_the_code_tab_in_the_window_of_that_host() async throws {
        let registry = TerminalSessionRegistry()
        let other = sshWindow(registry, name: "db")
        let made4 = await other.openTerminal()
        XCTAssertNotNil(made4)
        let ssh = sshWindow(registry)
        let made5 = await ssh.openTerminal()
        XCTAssertNotNil(made5)
        XCTAssertNil(ssh.workspace.codeTabID(of: ssh.host))

        let action = RemoteCodeTabAction(action: .start, tab: UUID(), tool: AgentHistoryTool.claude.rawValue,
                                         directory: Self.shop, server: ssh.host)
        let task = Task { await self.route(action, registry: registry) }
        let made6 = await ssh.installHistoryWhenOpened(directory: Self.shop)
        let code = try XCTUnwrap(made6)
        let id = try success(await task.value, action)
        XCTAssertEqual(code.runs.map(\.id), [id])
        XCTAssertEqual(code.hostName, "prod-web", "主机名取那台主机的终端")
        XCTAssertEqual(code.newSessionDirectory, Self.shop)
        XCTAssertNil(other.workspace.codeTabID(of: ssh.host), "别的主机的窗口不开")
        XCTAssertNil(other.workspace.codeTabID(of: other.host))
        let ownerTab = try XCTUnwrap(ssh.workspace.codeTabID(of: ssh.host))
        XCTAssertEqual(registry.codeTabs().map(\.id), [ownerTab])
        XCTAssertEqual(registry.codeTabs().first?.serverID, ssh.host)
    }

    /// 窗口里还没开过终端、但窗口就是这台主机的（工作区窗口绑定的那台）：也在这里开。
    func test_window_bound_to_the_host_can_open_its_code_tab() async throws {
        let registry = TerminalSessionRegistry()
        let ssh = sshWindow(registry)
        ssh.workspace.bindDefaultServer(id: ssh.host, title: "prod-web")
        let action = RemoteCodeTabAction(action: .start, tool: AgentHistoryTool.claude.rawValue,
                                         directory: Self.shop, server: ssh.host)
        let result = await route(action, registry: registry, historyWait: .milliseconds(200))
        XCTAssertEqual(result.error, LocalShellCodeTabText.notReady, "列表没接上就报没准备好")
        XCTAssertNotNil(ssh.workspace.codeTabID(of: ssh.host), "Code 标签页开在这个窗口")
    }

    /// Mac 上没有开着这台主机的窗口：回错误，不在本机终端里开（本机有 Code 标签页、有本机终端窗口也不碰），也不开窗口。
    func test_no_window_for_the_host_fails_without_touching_the_local_shell() async throws {
        let registry = TerminalSessionRegistry()
        let local = localWindow(registry)
        let localCodeID = local.openCodeTab(directory: Self.shop)
        let localCode = try XCTUnwrap(local.groups.tab(localCodeID)?.payload.codeTab)
        localCode.install(await SSHCodeTabWindowRig.connection(directory: Self.shop, sessions: []))
        let other = sshWindow(registry, name: "db")
        let made7 = await other.openTerminal()
        XCTAssertNotNil(made7)
        let tabsBefore = local.groups.allTabs.map(\.id)

        let host = UUID()
        for action in [RemoteCodeTabAction(action: .start, tab: localCodeID, tool: AgentHistoryTool.claude.rawValue,
                                           directory: Self.shop, server: host),
                       RemoteCodeTabAction(action: .resume, path: "/x.jsonl", tool: AgentHistoryTool.claude.rawValue,
                                           sessionID: "a", directory: Self.shop, server: host)] {
            let result = await route(action, local: [local], registry: registry)
            XCTAssertEqual(result.requestID, action.requestID)
            XCTAssertNil(result.session)
            XCTAssertEqual(result.error, WorkspaceCodeTabText.noHostWindow)
        }
        XCTAssertTrue(localCode.runs.isEmpty, "本机的 Code 标签页里没起会话")
        XCTAssertEqual(local.groups.allTabs.map(\.id), tabsBefore)
        XCTAssertNil(other.workspace.codeTabID(of: other.host), "别的主机的窗口不开 Code 标签页")
        XCTAssertNil(other.workspace.codeTabID(of: host))
    }

    // MARK: 重新开始 / 移到新标签页

    func test_restart_and_move_find_the_run_in_that_hosts_window() async throws {
        let registry = TerminalSessionRegistry()
        let local = localWindow(registry)
        let ssh = sshWindow(registry)
        let made8 = await ssh.openCodeTab(directory: Self.shop)
        let (codeID, code) = try XCTUnwrap(made8)
        let first = try XCTUnwrap(code.startNewSession(tool: .claude, in: Self.shop))
        let second = try XCTUnwrap(code.startNewSession(tool: .claude, in: "/srv/infra"))
        let up = await ssh.waitForRegistration(first.id)
        XCTAssertTrue(up)

        let running = RemoteCodeTabAction(action: .restart, tab: codeID, session: first.id, server: ssh.host)
        let stillRunning = await route(running, registry: registry)
        XCTAssertEqual(stillRunning.error, LocalShellCodeTabText.stillRunning)

        await ssh.backends[first.id]?.emitExit()
        let pane = try XCTUnwrap(first.terminal as? PaneModel)
        let down = await waitUntil { pane.session.connectionState == .disconnected }
        XCTAssertTrue(down)
        code.checkRuns()
        XCTAssertEqual(code.runs.first?.isEnded, true)

        // 主机不对、没带主机（老设备，当本机的做）：找不到它。
        let wrongHost = RemoteCodeTabAction(action: .restart, tab: codeID, session: first.id, server: UUID())
        let wrong = await route(wrongHost, local: [local], registry: registry)
        XCTAssertEqual(wrong.error, LocalShellCodeTabText.sessionGone)
        let asLocal = RemoteCodeTabAction(action: .restart, tab: codeID, session: first.id)
        let local1 = await route(asLocal, local: [local], registry: registry)
        XCTAssertEqual(local1.error, LocalShellCodeTabText.sessionGone)
        XCTAssertEqual(code.runs.map(\.id), [first.id, second.id], "没动")

        let restart = RemoteCodeTabAction(action: .restart, tab: codeID, session: first.id, server: ssh.host)
        let restarted = try success(await route(restart, registry: registry), restart)
        XCTAssertNotEqual(restarted, first.id)
        XCTAssertEqual(code.runs.map(\.id), [restarted, second.id], "新的放在旧的位置上")
        XCTAssertEqual(code.detail, .terminal(restarted), "Mac 上右边是新的")
        XCTAssertEqual(ssh.workspace.terminalGroups.activeTab?.payload.id, codeID)

        let move = RemoteCodeTabAction(action: .moveToTab, tab: codeID, session: second.id, server: ssh.host)
        let moved = await route(move, registry: registry)
        XCTAssertEqual(try success(moved, move), second.id, "同一个会话")
        XCTAssertEqual(code.runs.map(\.id), [restarted])
        XCTAssertTrue(ssh.workspace.hasTerminalTab(second.id), "成了普通终端标签页")
        XCTAssertEqual(registry.codeTabs().first?.runs.map(\.session), [restarted])
        let again = await route(move, registry: registry)
        XCTAssertEqual(again.error, LocalShellCodeTabText.sessionGone, "已经挪出去了")
    }

    // MARK: 本机照旧、开关

    /// `server` 是本机的那个 id：同没带一样交给本机终端窗口，SSH 窗口不碰。
    func test_local_server_id_is_the_local_shell() async throws {
        let registry = TerminalSessionRegistry()
        let local = localWindow(registry)
        let localCodeID = local.openCodeTab(directory: Self.shop)
        let localCode = try XCTUnwrap(local.groups.tab(localCodeID)?.payload.codeTab)
        localCode.install(await SSHCodeTabWindowRig.connection(directory: Self.shop, sessions: []))
        let ssh = sshWindow(registry)
        let made9 = await ssh.openCodeTab(directory: Self.shop)
        let (_, sshCode) = try XCTUnwrap(made9)

        for server in [nil, RemoteConstants.localShellServerID] {
            let action = RemoteCodeTabAction(action: .start, tab: localCodeID, tool: AgentHistoryTool.claude.rawValue,
                                             directory: Self.shop, server: server)
            XCTAssertNil(action.sshServer)
            let id = try success(await route(action, local: [local], registry: registry), action)
            XCTAssertTrue(localCode.runs.contains { $0.id == id })
        }
        XCTAssertEqual(localCode.runs.count, 2)
        XCTAssertTrue(sshCode.runs.isEmpty, "SSH 主机的不碰")
    }

    /// 「允许打开本机终端」没开：SSH 主机的也拒绝（同一个开关）。
    func test_switch_off_refuses_ssh_host_actions_too() async throws {
        let registry = TerminalSessionRegistry()
        let ssh = sshWindow(registry)
        let made10 = await ssh.openCodeTab(directory: Self.shop)
        let (codeID, code) = try XCTUnwrap(made10)
        let suite = "WorkspaceCodeTabActionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RemoteControlSettings(defaults: defaults)
        XCTAssertFalse(settings.isLocalShellEnabled)
        let actor = RemoteCodeTabActor.live(settings: settings, registry: registry)
        let action = RemoteCodeTabAction(action: .start, tab: codeID, tool: AgentHistoryTool.claude.rawValue,
                                         directory: Self.shop, server: ssh.host)
        let result = await actor.perform(action)
        XCTAssertNil(result.session)
        XCTAssertTrue(result.error?.contains("允许打开本机终端") == true, result.error ?? "")
        XCTAssertTrue(code.runs.isEmpty)

        settings.isLocalShellEnabled = true
        let id = try success(await actor.perform(action), action)
        XCTAssertEqual(code.runs.map(\.id), [id], "打开之后照常做")
    }
}
