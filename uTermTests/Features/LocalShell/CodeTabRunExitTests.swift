import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI
import UPaneGroups
import XCTest
@testable import uTerm

/// 「Code 标签页里一个会话退出后，整个 Code 标签页没了」的回归：真窗口里挂着终端区，窗口里一个普通标签页 + 一个
/// Code 标签页（前台），Code 标签页里起会话，让它退出（程序退出、结束标记到；或者 shell 自己退出），
/// Code 标签页要还在、还是前台，右边回到空态（继续的会话回到它的记录），旁边的普通标签页不动。
///
/// 本机终端窗口用真的保持进程 + 真 shell，会话放在测试自己的命名空间里（同 `CodeTabHolderRestoreTests`），
/// 不碰正式版与开发版的会话；「编码工具」换成一条等一行输入就退出的命令。SSH 终端窗口接假后端。
/// 列表接的都是手写的假数据源，不读这台机器上的真实记录。
@MainActor
final class CodeTabRunExitTests: XCTestCase {
    private static let namespace = "integration-test"
    private let client = LocalShellAgentClient()
    private var sessionIDs: Set<UUID> = []
    /// 假的编码工具：读一行就退出。
    private static let fakeTool = "head -n 1"

    override func tearDown() async throws {
        for id in sessionIDs { await HolderProbe.terminate(id, client: client, namespace: Self.namespace) }
        client.invalidate()
        try await super.tearDown()
    }

    // MARK: 搭台子

    private func localModel() -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { [weak self] pane in
            guard let self else { return }
            self.sessionIDs.insert(pane.id)
            let backend = LocalShellBackend(client: self.client, namespace: Self.namespace, sessionID: pane.id,
                                            directory: pane.workingDirectory, columns: 80, rows: 24)
            Task { await pane.session.connect(using: backend) }
        })
        let registry = TerminalSessionRegistry()
        let windowID = UUID()
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: windowID,
                                              windowKind: TerminalWindowKind.terminal))
        // 同 `LocalShellWindowView`：手机远控「同时关闭 Mac 上的终端」走这里。
        registry.setCloser(forWindow: windowID) { [weak model] in model?.close($0) ?? false }
        return model
    }

    /// 一个有一份记录（`a`，在 `directory` 里）的假列表；继续 / 新开都跑 `command`。
    private func fakeConnection(directory: String, command: String) async -> AgentHistoryConnection {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [
            AgentHistoryFakeSource.Session(id: "a", projectID: ClaudeProjectPath.encode(directory),
                                           resumeDirectory: directory, title: "假的会话",
                                           modifiedAt: Date().addingTimeInterval(-3600)),
        ], command: command)
        let history = AgentHistoryModel(source: source, preferredDirectory: directory, followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(10)) }
        return AgentHistoryConnection(history: history)
    }

    private func wait(_ what: String, timeout: TimeInterval = 20, for condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let met = await condition()
        XCTAssertTrue(met, "等不到：\(what)")
    }

    private func window(_ root: some View) -> NSWindow {
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                                      key: true, placement: .transparentOnScreen)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 1000, height: 600))
        window.contentView = host
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = NSView()
        window.orderOut(nil)
    }

    /// 让终端视图真的挂上、拿到焦点（用户就是在这个终端里打字退出的）。
    private func focus(_ session: TerminalSession, in window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(500))
        let view = session.ghostty.view
        if view.window === window { window.makeFirstResponder(view) }
    }

    struct LocalCase {
        /// 窗口里先有一个普通标签页。
        var withShellTab = true
        /// 继续那份记录（否则「＋」新会话）。
        var resumes = false
        /// 另外再跑一个不退出的会话。
        var keepsAnother = false
        /// 命令：程序退出后 shell 跟着退出（不打结束标记）。
        var shellExits = false
        /// 程序退出后接着在 shell 里打 `exit`。
        var typesExit = false
        /// 挂整个窗口的内容（`LocalShellWindowView`：⌘W 监听、关窗口确认、标题栏都在），用真的按键事件打字，
        /// 而不是直接往会话里写。
        var fullWindowAndKeys = false
    }

    private func runLocal(_ setup: LocalCase, file: StaticString = #filePath, line: UInt = #line) async throws {
        let model = localModel()
        let window = setup.fullWindowAndKeys
            ? window(LocalShellWindowView(windowID: LocalShellWindowID(id: UUID()), catalogModel: model)
                .environment(TerminalSessionRegistry()))
            : window(LocalShellTerminalArea(model: model))
        defer {
            model.disposeAll()
            close(window)
        }
        let directory = ClaudeProjectPath.normalized(NSTemporaryDirectory()) ?? NSTemporaryDirectory()
        let shellID = setup.withShellTab ? model.addTab(directory: directory) : nil
        let codeID = model.openCodeTab(directory: directory)
        let code = try XCTUnwrap(model.groups.tab(codeID)?.payload.codeTab)
        let command = setup.shellExits ? Self.fakeTool + "; exit" : Self.fakeTool
        // 视图第一次显示前装好假数据：`CodeTabView` 的 `open` 就不再去建真的文件通道。
        code.install(await fakeConnection(directory: directory, command: command))
        let history = try XCTUnwrap(code.history)
        if let shellID, let shell = model.groups.tab(shellID)?.payload {
            await wait("普通标签页的 shell 起来") { shell.session.connectionState == .connected }
        }
        var other: LocalShellPane?
        if setup.keepsAnother {
            let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "sleep 600", directory: directory))
            other = model.pane(run.id)
        }
        let started: CodeTabModel.Run
        if setup.resumes {
            started = try XCTUnwrap(code.resume(try XCTUnwrap(history.files.first)))
        } else {
            started = try XCTUnwrap(code.startNewSession(tool: .claude, command: "cd -- '\(directory)' && " + command,
                                                         directory: directory))
        }
        let run = try XCTUnwrap(model.pane(started.id))
        await wait("会话里的命令跑起来") { await run.session.foregroundActivity() == .running("head") }
        XCTAssertEqual(code.detail, .terminal(run.id), "右边是它的终端")
        XCTAssertEqual(model.active?.id, codeID)
        try await focus(run.session, in: window)

        let input = setup.typesExit ? "bye\rexit\r" : "bye\r"
        if setup.fullWindowAndKeys {
            XCTAssertTrue(window.firstResponder === run.session.ghostty.view, "按键要进会话的终端", file: file, line: line)
            try type(input, into: window)
        } else {
            run.session.writeRemoteInput(Data(input.replacingOccurrences(of: "\r", with: "\n").utf8))
        }
        await wait("会话收尾") { !code.runs.contains { $0.id == run.id } }
        // 收尾之后再看一会儿：视图拿掉终端那一下之后的事。
        try await Task.sleep(for: .seconds(2))

        let expectedTabs = [shellID, codeID].compactMap { $0 }
        XCTAssertEqual(model.groups.allTabs.map(\.id), expectedTabs, "标签页都还在", file: file, line: line)
        XCTAssertEqual(model.active?.id, codeID, "Code 标签页还是前台", file: file, line: line)
        XCTAssertTrue(model.groups.tab(codeID)?.payload.codeTab === code, file: file, line: line)
        XCTAssertEqual(code.detail, setup.resumes ? .transcript : .empty, "右边回到记录 / 空态", file: file, line: line)
        XCTAssertTrue(run.isDisposed, "会话的 shell 结束了", file: file, line: line)
        if let other {
            XCTAssertEqual(code.runs.map(\.id), [other.id], "另一个会话照跑", file: file, line: line)
            XCTAssertEqual(other.session.connectionState, .connected, file: file, line: line)
        }
        if let shellID {
            XCTAssertEqual(model.groups.tab(shellID)?.payload.session.connectionState, .connected,
                           "旁边的普通标签页没动", file: file, line: line)
        }
    }

    /// 按真的键盘事件打字（经窗口分发到第一响应者，同用户在终端里敲）。只认小写字母和回车。
    private func type(_ text: String, into window: NSWindow) throws {
        let codes: [Character: Int] = ["b": kVK_ANSI_B, "y": kVK_ANSI_Y, "e": kVK_ANSI_E, "x": kVK_ANSI_X,
                                       "i": kVK_ANSI_I, "t": kVK_ANSI_T, "\r": kVK_Return]
        for character in text {
            let code = try XCTUnwrap(codes[character])
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: String(character),
                    charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: UInt16(code)))
                window.sendEvent(event)
            }
        }
    }

    // MARK: 本机终端窗口

    func test_full_window_with_real_key_events_keeps_the_code_tab() async throws {
        try await runLocal(.init(fullWindowAndKeys: true))
        try await runLocal(.init(typesExit: true, fullWindowAndKeys: true))
        try await runLocal(.init(shellExits: true, fullWindowAndKeys: true))
    }

    func test_new_session_program_exit_keeps_the_code_tab() async throws {
        try await runLocal(.init())
    }

    func test_new_session_shell_exit_keeps_the_code_tab() async throws {
        try await runLocal(.init(shellExits: true))
    }

    func test_program_exit_then_typing_exit_keeps_the_code_tab() async throws {
        try await runLocal(.init(typesExit: true))
    }

    func test_resumed_session_exit_returns_to_its_record() async throws {
        try await runLocal(.init(resumes: true))
    }

    func test_code_tab_alone_in_the_window_survives_its_run_exiting() async throws {
        try await runLocal(.init(withShellTab: false))
        try await runLocal(.init(withShellTab: false, shellExits: true))
    }

    func test_one_of_two_runs_exiting_keeps_the_other() async throws {
        try await runLocal(.init(keepsAnother: true))
        try await runLocal(.init(keepsAnother: true, shellExits: true))
    }

    // MARK: ⌘W（记下现在的行为，不是要求）

    /// Code 标签页在前台时按 ⌘W：关的是整个 Code 标签页（连同里面所有会话），不是右边那一个会话。
    /// 这里走的是右边那个会话已经结束、回到空态之后的那一下：没有在跑的会话，不问，直接关，露出旁边的普通标签页。
    /// 还有会话的前台在跑程序时会先问一次（`TerminalCloseGuard`，弹的是模态确认，测试里不走那条）。
    func test_command_w_on_the_code_tab_closes_the_whole_tab() async throws {
        let model = localModel()
        let window = window(LocalShellWindowView(windowID: LocalShellWindowID(id: UUID()), catalogModel: model)
            .environment(TerminalSessionRegistry()))
        defer {
            model.disposeAll()
            close(window)
        }
        let directory = ClaudeProjectPath.normalized(NSTemporaryDirectory()) ?? NSTemporaryDirectory()
        let shellID = model.addTab(directory: directory)
        let codeID = model.openCodeTab(directory: directory)
        let code = try XCTUnwrap(model.groups.tab(codeID)?.payload.codeTab)
        code.install(await fakeConnection(directory: directory, command: Self.fakeTool))
        let started = try XCTUnwrap(code.startNewSession(tool: .claude, command: Self.fakeTool, directory: directory))
        let run = try XCTUnwrap(model.pane(started.id))
        await wait("会话里的命令跑起来") { await run.session.foregroundActivity() == .running("head") }
        try await focus(run.session, in: window)
        run.session.writeRemoteInput(Data("bye\n".utf8))
        await wait("会话收尾") { code.runs.isEmpty }
        XCTAssertEqual(model.groups.allTabs.map(\.id), [shellID, codeID], "会话退出本身不关标签页")

        try commandW(window)
        await wait("Code 标签页关掉") { model.groups.tab(codeID) == nil }
        XCTAssertEqual(model.groups.allTabs.map(\.id), [shellID])
        XCTAssertEqual(model.active?.id, shellID, "露出旁边的普通标签页")
    }

    private func commandW(_ window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_W)))
        // ⌘W 由窗口里的本地事件监听接（`WorkspaceCloseShortcutInstaller`），要经 `NSApp` 分发才看得到。
        NSApp.sendEvent(event)
    }

    // MARK: SSH 终端窗口（假后端）

    func test_ssh_code_tab_survives_its_run_exiting() async throws {
        for shellExits in [false, true] {
            try await runSSH(shellExits: shellExits)
        }
    }

    private func runSSH(shellExits: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let container = try ModelContainer(for: Schema(ModelRegistry.types),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        // 主机不进库：面板查不到它（`profileCount == 0`）就不去真连，终端只接下面的假后端。
        let server = ServerProfile()
        server.name = "prod-web-01"
        let workspace = WorkspaceModel()
        var backends: [UUID: MockBackend] = [:]
        workspace.connectCodeRun = { pane in
            let backend = MockBackend()
            backends[pane.id] = backend
            pane.session.attentionSink = { _ in }
            Task { await pane.session.connect(using: backend) }
        }
        let terminalID = workspace.openServer(profileID: server.id, title: server.name)
        for pane in workspace.terminalPanes {
            pane.session.attentionSink = { _ in }
            await pane.session.connect(using: MockBackend())
        }
        let window = window(TerminalArea(workspace: workspace, server: server).modelContainer(container))
        defer {
            workspace.dispose()
            close(window)
        }
        let directory = "/srv/shop"
        let codeID = workspace.openCodeTab(serverID: server.id, hostName: server.name, directory: directory)
        let code = try XCTUnwrap(workspace.terminalGroups.tab(codeID)?.payload.codeTab)
        code.install(await fakeConnection(directory: directory, command: "claude"))
        let started = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: directory))
        let pane = try XCTUnwrap(started.terminal as? PaneModel)
        await wait("会话连上") { pane.session.connectionState == .connected }
        let backend = try XCTUnwrap(backends[pane.id])
        try await focus(pane.session, in: window)

        if shellExits {
            await backend.emitExit()
        } else {
            // 假后端没有行编辑器，命令不会真打进去：直接放出起止标记（同 shell 里 `printf` 打出来的）。
            let id = try XCTUnwrap(pane.session.trackedRun?.id)
            let code = TerminalTrackedRun.oscCode
            await backend.emitOutput(Data("\u{1B}]\(code);S;\(id)\u{07}hi\r\n\u{1B}]\(code);D;\(id);0\u{07}".utf8))
        }
        await wait("会话收尾") { code.runs.isEmpty }
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(workspace.terminalGroups.allTabs.map(\.id), [terminalID, codeID], "标签页都还在",
                       file: file, line: line)
        XCTAssertEqual(workspace.terminalGroups.activeTab?.id, codeID, "Code 标签页还是前台", file: file, line: line)
        XCTAssertEqual(code.detail, .empty, file: file, line: line)
        XCTAssertEqual(workspace.terminalGroups.tab(terminalID)?.payload.session.connectionState, .connected,
                       file: file, line: line)
    }
}
