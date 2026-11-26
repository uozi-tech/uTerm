import UPaneGroups
import XCTest
@testable import uTerm

/// SSH 主机的工作区 / 终端窗口把它的 Code 标签页报给远控（63 号消息的来源，`WorkspaceModel.remoteCodeTabs` →
/// `TerminalSessionRegistry.codeTabs`）：哪台主机、哪些会话归它、结束了没有、排在哪（跨窗口，同本机终端窗口一起算）、
/// 挪出去 / 在 Mac 上结束（8 号消息走的那条）之后、窗口关了之后。本机的照旧（`CodeTabRemotePublishTests`），老设备只认
/// 本机的那个（`mirrored()`）。会话接假后端，不连真主机。
@MainActor
final class WorkspaceCodeTabPublishTests: XCTestCase {
    private var rigs: [SSHCodeTabWindowRig] = []
    private var locals: [LocalShellWindowModel] = []

    override func tearDown() async throws {
        for rig in rigs { rig.dispose() }
        for model in locals { model.disposeAll() }
        rigs = []
        locals = []
        try await super.tearDown()
    }

    private func sshWindow(_ registry: TerminalSessionRegistry, host: UUID = UUID(), name: String = "prod-web")
        -> SSHCodeTabWindowRig {
        let rig = SSHCodeTabWindowRig(registry: registry, host: host, hostName: name)
        rigs.append(rig)
        return rig
    }

    /// 同 `LocalShellWindowView` 的登记（同 `CodeTabRemotePublishTests`）。
    private func localWindow(_ registry: TerminalSessionRegistry) -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { pane in
            Task { await pane.session.connect(using: MockBackend()) }
        })
        let id = UUID()
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: id, windowKind: TerminalWindowKind.terminal))
        registry.setTabOrder(forWindow: id) { [weak model] in
            model?.groups.snapshot(LocalShellWindowModel.heldSessionID).tabOrder ?? []
        }
        registry.setCodeTabs(forWindow: id) { [weak model] in model?.remoteCodeTabs() ?? [] }
        locals.append(model)
        return model
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func test_ssh_code_tab_is_published_with_its_host_and_slot_after_the_local_window() async throws {
        let registry = TerminalSessionRegistry()
        let local = localWindow(registry)
        let shell = local.addTab()
        let localCodeID = local.openCodeTab(directory: "/tmp")
        let ssh = sshWindow(registry)
        let made1 = await ssh.openTerminal()
        let terminal = try XCTUnwrap(made1)
        let made2 = await ssh.openCodeTab(directory: "/srv/shop")
        let (codeID, code) = try XCTUnwrap(made2)
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, in: "/srv/shop"))
        let registered = await ssh.waitForRegistration(run.id)
        let shellUp = await waitUntil { registry.entries.contains { $0.id == shell } }
        XCTAssertTrue(registered && shellUp)

        let tabs = registry.codeTabs()
        XCTAssertEqual(tabs.map(\.id), [localCodeID, codeID], "窗口按登记的先后")
        let info = try XCTUnwrap(tabs.last)
        XCTAssertEqual(info.serverID, ssh.host, "主机是那台的 ServerProfile")
        XCTAssertEqual(info.serverName, "prod-web")
        XCTAssertEqual(info.directory, "/srv/shop")
        XCTAssertEqual(info.runs.map(\.session), [run.id])
        XCTAssertEqual(info.runs.first?.tool, AgentHistoryTool.claude.rawValue)
        XCTAssertEqual(info.runs.first?.directory, "/srv/shop")
        XCTAssertNil(info.runs.first?.endedAt)
        XCTAssertEqual(info.selectedRun, run.id)
        XCTAssertEqual(info.slot, 2, "排在本机窗口的 shell 和这个窗口的终端标签页后面")
        XCTAssertEqual(tabs.first?.slot, 1, "本机的照旧")
        XCTAssertEqual(registry.orderedEntries().map(\.id).prefix(2), [shell, terminal])

        // 老设备只镜像本机的；按主机的各一个。
        XCTAssertEqual(tabs.mirrored()?.id, localCodeID)
        XCTAssertEqual(tabs.mirrored(serverID: ssh.host)?.id, codeID)
        XCTAssertEqual(tabs.mirroredPerHost.map(\.id), [localCodeID, codeID])

        // Code 标签页拖到终端标签页前面：位置跟着变。
        let terminalTab = try XCTUnwrap(ssh.workspace.terminalGroups.allTabs.first { $0.payload.id == terminal }?.id)
        let codeTab = try XCTUnwrap(ssh.workspace.terminalGroups.allTabs.first { $0.payload.id == codeID }?.id)
        ssh.workspace.terminalGroups.arrangeTabs(by: [codeTab, terminalTab]) { $0.id }
        XCTAssertEqual(registry.codeTabs().last?.slot, 1)
    }

    /// 两个窗口、两台主机：各报各的，第二个窗口的位置数上第一个窗口的会话。
    func test_each_host_window_publishes_its_own_code_tab() async throws {
        let registry = TerminalSessionRegistry()
        let first = sshWindow(registry, name: "web")
        let second = sshWindow(registry, name: "db")
        let made3 = await first.openTerminal()
        let a = try XCTUnwrap(made3)
        let made4 = await second.openTerminal()
        let b = try XCTUnwrap(made4)
        let made5 = await first.openCodeTab(directory: "/srv/web")
        let (firstCode, _) = try XCTUnwrap(made5)
        let made6 = await second.openCodeTab(directory: "/srv/db")
        let (secondCode, _) = try XCTUnwrap(made6)

        let tabs = registry.codeTabs()
        XCTAssertEqual(tabs.map(\.id), [firstCode, secondCode])
        XCTAssertEqual(tabs.map(\.serverID), [first.host, second.host])
        XCTAssertEqual(tabs.map(\.serverName), ["web", "db"])
        XCTAssertEqual(tabs.map(\.slot), [1, 2])
        XCTAssertEqual(registry.orderedEntries().map(\.id), [a, b])
        XCTAssertNil(tabs.mirrored(), "没有本机的：老设备什么都不镜像")
    }

    /// 程序退出：会话留着、标成已结束；「移到新标签页」：不再归 Code 标签页；Mac 上结束会话（手机「结束会话」的 8 号消息走
    /// `requestClose` → `closeTerminal` → `CodeTabModel.end`）：从 Code 标签页里拿掉、断开。窗口关了一并撤掉。
    func test_ended_detached_and_closed_runs() async throws {
        let registry = TerminalSessionRegistry()
        let ssh = sshWindow(registry)
        let made7 = await ssh.openCodeTab(directory: "/srv/shop")
        let (codeID, code) = try XCTUnwrap(made7)
        let exits = try XCTUnwrap(code.startNewSession(tool: .claude, in: "/srv/shop"))
        let moved = try XCTUnwrap(code.startNewSession(tool: .claude, in: "/srv/shop"))
        let closed = try XCTUnwrap(code.startNewSession(tool: .claude, in: "/srv/shop"))
        for run in [exits, moved, closed] {
            let up = await ssh.waitForRegistration(run.id)
            XCTAssertTrue(up)
        }
        XCTAssertEqual(registry.codeTabs().first?.runs.map(\.session), [exits.id, moved.id, closed.id])

        await ssh.backends[exits.id]?.emitExit()
        let exitPane = try XCTUnwrap(code.runs.first { $0.id == exits.id }?.terminal as? PaneModel)
        let down = await waitUntil { exitPane.session.connectionState == .disconnected }
        XCTAssertTrue(down)
        code.checkRuns()
        XCTAssertNotNil(registry.codeTabs().first?.runs.first { $0.session == exits.id }?.endedAt, "报了结束的时刻")

        let codeTab = try XCTUnwrap(ssh.workspace.terminalGroups.allTabs.first { $0.payload.id == codeID }?.id)
        ssh.workspace.moveCodeRunToTab(moved.id, fromCodeTab: codeTab)
        XCTAssertEqual(registry.codeTabs().first?.runs.map(\.session), [exits.id, closed.id])
        XCTAssertEqual(registry.codeTabs().first?.slot, 0, "挪出去的标签排在 Code 标签页后面")

        let backend = try XCTUnwrap(ssh.backends[closed.id])
        XCTAssertTrue(registry.requestClose(sessionID: closed.id), "8 号消息走的那条找得到它的窗口")
        XCTAssertEqual(registry.codeTabs().first?.runs.map(\.session), [exits.id])
        XCTAssertFalse(registry.entries.contains { $0.id == closed.id }, "注销了")
        var backendClosed = false
        for _ in 0..<300 where !backendClosed {
            backendClosed = await backend.didClose
            if !backendClosed { try? await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(backendClosed, "连接断开")
        XCTAssertEqual(registry.codeTabs().first?.id, codeID, "Code 标签页还在")

        registry.forgetWindow(ssh.windowID)
        XCTAssertEqual(registry.codeTabs(), [])
        XCTAssertTrue(registry.codeTabWorkspaces().isEmpty)
    }

    /// 窗口关掉（`dispose` 抹掉它在注册表里的入口）：不再报、不再交给它做事。
    func test_disposed_window_publishes_nothing() async throws {
        let registry = TerminalSessionRegistry()
        let ssh = sshWindow(registry)
        let made8 = await ssh.openCodeTab(directory: "/srv/shop")
        XCTAssertNotNil(made8)
        XCTAssertEqual(registry.codeTabs().count, 1)
        XCTAssertTrue(registry.codeTabWorkspaces().first === ssh.workspace)
        ssh.dispose()
        XCTAssertEqual(registry.codeTabs(), [])
        XCTAssertTrue(registry.codeTabWorkspaces().isEmpty)
    }
}
