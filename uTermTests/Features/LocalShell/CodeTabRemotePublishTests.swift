import UPaneGroups
import XCTest
@testable import uTerm

/// 本机终端窗口把 Code 标签页报给远控（63 号消息的来源，`LocalShellWindowModel.remoteCodeTabs` →
/// `TerminalSessionRegistry.codeTabs`）：哪些会话归它、结束了没有、对上的记录、排在哪、挪出去 / 接回之后。
/// shell 接的是假后端（`MockBackend`），不起真 shell。
@MainActor
final class CodeTabRemotePublishTests: XCTestCase {
    private var models: [LocalShellWindowModel] = []

    override func tearDown() async throws {
        for model in models { model.disposeAll() }
        models = []
        try await super.tearDown()
    }

    /// 同 `LocalShellWindowView` 的登记：凭条、标签顺序、Code 标签页、关闭入口。
    private func window(_ registry: TerminalSessionRegistry, id: UUID = UUID()) -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { pane in
            Task { await pane.session.connect(using: MockBackend()) }
        })
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: id, windowKind: TerminalWindowKind.terminal))
        registry.setTabOrder(forWindow: id) { [weak model] in
            model?.groups.snapshot(LocalShellWindowModel.heldSessionID).tabOrder ?? []
        }
        registry.setCodeTabs(forWindow: id) { [weak model] in model?.remoteCodeTabs() ?? [] }
        registry.setCloser(forWindow: id) { [weak model] paneID in model?.close(paneID) ?? false }
        models.append(model)
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

    func test_runs_belong_to_the_code_tab_and_it_sits_after_the_shell_before_it() async throws {
        let registry = TerminalSessionRegistry()
        let model = window(registry)
        let shell = model.addTab()
        let codeID = model.openCodeTab(directory: "/tmp")
        let code = try XCTUnwrap(model.groups.tab(codeID)?.payload.codeTab)
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: "/tmp"))
        let registered = await waitUntil { Set(registry.entries.map(\.id)) == [shell, run.id] }
        XCTAssertTrue(registered)

        let tabs = registry.codeTabs()
        XCTAssertEqual(tabs.map(\.id), [codeID])
        let info = try XCTUnwrap(tabs.first)
        XCTAssertEqual(info.serverID, RemoteConstants.localShellServerID)
        XCTAssertEqual(info.runs.map(\.session), [run.id])
        XCTAssertEqual(info.runs.first?.tool, AgentHistoryTool.claude.rawValue)
        XCTAssertEqual(info.runs.first?.title, AgentHistoryText.newSession)
        XCTAssertNil(info.runs.first?.endedAt)
        XCTAssertEqual(info.selectedRun, run.id, "右边看着新会话")
        XCTAssertEqual(info.slot, 1, "排在 shell 后面")
        XCTAssertEqual(info.directory, "/tmp")
        XCTAssertEqual(registry.orderedEntries().map(\.id), [shell, run.id], "跑着的会话不在标签顺序里，排在最后")

        // Code 标签页拖到 shell 前面：位置跟着变。
        model.groups.arrangeTabs(by: [codeID, shell]) { $0.id }
        XCTAssertEqual(registry.codeTabs().first?.slot, 0)
    }

    /// 「移到新标签页」：会话不再归 Code 标签页，成了普通的 shell 标签；Mac 上关掉会话（手机「结束会话」走的那条）
    /// 同样从 Code 标签页里拿掉。
    func test_detached_and_closed_runs_leave_the_code_tab() async throws {
        let registry = TerminalSessionRegistry()
        let model = window(registry)
        let shell = model.addTab()
        let codeID = model.openCodeTab(directory: "/tmp")
        let code = try XCTUnwrap(model.groups.tab(codeID)?.payload.codeTab)
        let moved = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: "/tmp"))
        let ended = try XCTUnwrap(code.startNewSession(tool: .codex, command: "codex", directory: "/tmp"))
        let registered = await waitUntil { registry.entries.count == 3 }
        XCTAssertTrue(registered)
        XCTAssertEqual(Set(registry.codeTabs().first?.runs.map(\.session) ?? []), [moved.id, ended.id])

        model.moveCodeRunToTab(moved.id, fromCodeTab: codeID)
        XCTAssertEqual(registry.codeTabs().first?.runs.map(\.session), [ended.id])
        XCTAssertEqual(registry.orderedEntries().map(\.id).prefix(2), [shell, moved.id], "挪出去的成了标签")

        let registryClosed = registry.requestClose(sessionID: ended.id)
        XCTAssertTrue(registryClosed)
        XCTAssertEqual(registry.codeTabs().first?.runs, [], "关掉的会话从 Code 标签页里拿掉")
        XCTAssertEqual(registry.codeTabs().first?.id, codeID, "Code 标签页还在")
    }

    /// App 重启后接回：Code 标签页还是原来的 id，会话回到它里面，对上的记录、选中的会话照旧报。
    func test_restored_code_tab_keeps_its_id_and_runs() async throws {
        let registry = TerminalSessionRegistry()
        let model = window(registry)
        let shell = UUID(), codeID = UUID(), run = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let layout = HeldSessionLayout(
            revision: 1,
            tree: UPaneGroupsSnapshot(root: .leaf(groupIndex: 0), groups: [.init(tabs: [shell, codeID], activeIndex: 0)],
                                      activeGroupIndex: 0),
            codeTabs: [CodeTabRecord(id: codeID, directory: "/tmp", runs: [
                CodeRunRecord(session: run, tool: .claude, sessionID: "abc-123", directory: "/tmp", startedAt: startedAt),
            ], selectedRun: run)])
        model.adopt([(id: shell, ordinal: 1), (id: run, ordinal: 2)], layout: layout)
        let registered = await waitUntil { registry.entries.count == 2 }
        XCTAssertTrue(registered)

        let info = try XCTUnwrap(registry.codeTabs().first)
        XCTAssertEqual(info.id, codeID)
        XCTAssertEqual(info.runs.map(\.session), [run])
        XCTAssertEqual(info.runs.first?.sessionID, "abc-123")
        XCTAssertEqual(info.runs.first?.startedAt, startedAt)
        XCTAssertEqual(info.selectedRun, run)
        XCTAssertEqual(info.slot, 1)
    }

    /// 窗口关了：它的 Code 标签页一并撤掉。
    func test_forgotten_window_publishes_nothing() {
        let registry = TerminalSessionRegistry()
        let id = UUID()
        let model = window(registry, id: id)
        _ = model.openCodeTab(directory: nil)
        XCTAssertEqual(registry.codeTabs().count, 1)
        registry.forgetWindow(id)
        XCTAssertEqual(registry.codeTabs(), [])
    }
}

/// `CodeTabModel.remoteInfo`：结束了的、对上记录的会话怎么报（终端是假的）。
@MainActor
final class CodeTabRemoteInfoTests: XCTestCase {
    private final class FakeTerminal: CodeTabTerminal {
        let id = UUID()
        var codeCommandHasEnded = false
        func runCodeCommand(_ command: String) {}
        func dispose() {}
    }

    func test_ended_run_reports_when_it_ended_and_keeps_its_title() throws {
        var made: [FakeTerminal] = []
        let code = CodeTabModel(hostName: "这台 Mac", directory: "/tmp") { _ in
            let terminal = FakeTerminal()
            made.append(terminal)
            return terminal
        }
        let run = try XCTUnwrap(code.startNewSession(tool: .codex, command: "codex", directory: "/tmp"))
        let id = UUID()
        XCTAssertNil(code.remoteInfo(id: id).runs.first?.endedAt)

        // 新会话没说话就退出：没有记录可看，终端留着、标成已结束。
        made.first?.codeCommandHasEnded = true
        code.checkRuns()
        let info = code.remoteInfo(id: id)
        XCTAssertEqual(info.id, id)
        XCTAssertEqual(info.runs.map(\.session), [run.id])
        XCTAssertNotNil(info.runs.first?.endedAt)
        XCTAssertEqual(info.runs.first?.tool, AgentHistoryTool.codex.rawValue)
        XCTAssertNil(info.slot, "位置由注册表算")
        code.close()
    }
}
