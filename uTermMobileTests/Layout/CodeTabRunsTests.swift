import SwiftData
import SwiftUI
import XCTest
@testable import uTermMobile

/// Code 标签页里「继续聊天」：状态机（`CodeRunBoard`，不沾界面）与它接到真终端、工作区之后的样子——继续、切走再切回、
/// 程序退出回到记录、新会话的占位与认领、关标签页的确认与结束、键盘归属、归档、深链接、长按入口、窄屏详情在记录与终端之间换。
/// 终端接假传输（`MobileFakeTerminalTransport`），记录是手写的假数据源，不连任何真主机。
@MainActor
final class CodeTabRunsTests: XCTestCase {

    private final class FakeTerminal {}

    /// 连上之后像 zsh 那样出提示符、打开括号粘贴：行编辑器起来了，命令马上会打进去。
    private static let prompt = MobileFakeTerminalScript.transcript("% \u{1B}[?2004h")

    override func tearDown() async throws {
        MobileProbeWindow.closeAll()
        try await super.tearDown()
    }

    // MARK: - 状态机

    func testResumingTheSameSessionReturnsToItsRun() {
        let board = CodeRunBoard<FakeTerminal>()
        var made = 0
        let first = board.resume(sessionPath: "/p/a.jsonl", sessionID: "a", tool: .claude, directory: "/w") {
            made += 1
            return FakeTerminal()
        }
        XCTAssertNotNil(first)
        XCTAssertEqual(board.focusedID, first?.id)
        XCTAssertNotNil(board.shownTerminal)

        let other = board.resume(sessionPath: "/p/b.jsonl", sessionID: "b", tool: .codex, directory: "/w") {
            made += 1
            return FakeTerminal()
        }
        XCTAssertEqual(board.runningCount, 2, "点别的会话不打断正在跑的")
        XCTAssertEqual(board.focusedID, other?.id)

        board.setShowsTerminal(try! XCTUnwrap(first).id, false)
        let again = board.resume(sessionPath: "/p/a.jsonl", sessionID: "a", tool: .claude, directory: "/w") {
            made += 1
            return FakeTerminal()
        }
        XCTAssertNil(again, "同一份记录不另起")
        XCTAssertEqual(made, 2)
        XCTAssertEqual(board.focusedID, first?.id, "回到它的终端")
        XCTAssertEqual(board.focused?.showsTerminal, true)
    }

    func testQuickExitIsKeptAndLongRunReturnsToTheRecord() {
        let board = CodeRunBoard<FakeTerminal>()
        let start = Date(timeIntervalSince1970: 1_000)
        let quick = board.startNew(tool: .claude, directory: "/w", now: start, terminal: FakeTerminal())
        XCTAssertEqual(board.ended(quick.id, now: start.addingTimeInterval(2)), .kept, "很快就退出：留着给人看报错")
        XCTAssertEqual(board.run(id: quick.id)?.isRunning, false)
        XCTAssertEqual(board.runningCount, 0)
        XCTAssertEqual(board.remove(quick.id), .removed(sessionPath: nil, wasFocused: true))

        let long = board.resume(sessionPath: "/p/a.jsonl", sessionID: "a", tool: .claude, directory: "/w", now: start) {
            FakeTerminal()
        }!
        let other = board.startNew(tool: .codex, directory: "/w", now: start, terminal: FakeTerminal())
        XCTAssertEqual(board.focusedID, other.id)
        XCTAssertEqual(board.ended(long.id, now: start.addingTimeInterval(60)), .removed(sessionPath: "/p/a.jsonl", wasFocused: false))
        XCTAssertEqual(board.runs.map(\.id), [other.id])
        XCTAssertEqual(board.ended(long.id), .unknown)
    }

    func testNewSessionsClaimTheirRecordsOnceAndInOrder() {
        let board = CodeRunBoard<FakeTerminal>()
        let start = Date(timeIntervalSince1970: 10_000)
        let first = board.startNew(tool: .codex, directory: "/w/shop", now: start, terminal: FakeTerminal())
        let second = board.startNew(tool: .codex, directory: "/w/shop", now: start.addingTimeInterval(30),
                                    terminal: FakeTerminal())
        let claude = board.startNew(tool: .claude, directory: "/w/blog", now: start, terminal: FakeTerminal())
        board.setShowsTerminal(first.id, false)
        XCTAssertEqual(board.run(id: first.id)?.showsTerminal, true, "还没有记录的新会话只能看终端")

        typealias C = CodeRunBoard<FakeTerminal>.Candidate
        let noise = [
            C(path: "/old", sessionID: "old", tool: .codex, directory: "/w/shop", modifiedAt: start.addingTimeInterval(-600)),
            C(path: "/elsewhere", sessionID: "e", tool: .codex, directory: "/w/infra", modifiedAt: start.addingTimeInterval(40)),
            C(path: "/claude", sessionID: "c", tool: .claude, directory: "/w/shop", modifiedAt: start.addingTimeInterval(40)),
            C(path: "/nodir", sessionID: "n", tool: .codex, directory: nil, modifiedAt: start.addingTimeInterval(40)),
        ]
        XCTAssertEqual(board.reconcile(noise), [], "旧的、别的目录、别的工具、不知道目录的都不认")
        XCTAssertTrue(board.hasUnmatchedNewSessions)

        let real = noise + [
            C(path: "/x1", sessionID: "x1", tool: .codex, directory: "/w/shop/", modifiedAt: start.addingTimeInterval(50)),
        ]
        XCTAssertEqual(board.reconcile(real), [first.id], "一份记录只给一个新会话")
        XCTAssertEqual(board.run(id: first.id)?.sessionPath, "/x1")
        XCTAssertNil(board.run(id: second.id)?.sessionPath, "对不上的留着占位，不丢")
        XCTAssertNil(board.run(id: claude.id)?.sessionPath)

        let later = real + [
            C(path: "/x2", sessionID: "x2", tool: .codex, directory: "/w/shop", modifiedAt: start.addingTimeInterval(80)),
        ]
        XCTAssertEqual(board.reconcile(later), [second.id])
        XCTAssertEqual(board.run(id: second.id)?.sessionPath, "/x2")
        XCTAssertEqual(board.run(id: first.id)?.sessionPath, "/x1", "认下来的不再换")
        XCTAssertEqual(Set(board.runs.compactMap(\.sessionPath)).count, 2, "不重复")
        XCTAssertEqual(board.run(forSession: "/x2")?.id, second.id, "认下来之后再「继续」那份记录回到它")
    }

    /// 列表里没有行的 run 放在列表最顶上：没对上记录的新会话、对上了但列表里还没那一行的；列表里有行的不再出（不重复）。
    func testUnlistedRunsStayOnTopUntilTheirRecordIsListed() {
        let board = CodeRunBoard<FakeTerminal>()
        let start = Date(timeIntervalSince1970: 20_000)
        let fresh = board.startNew(tool: .codex, directory: "/w/shop", now: start, terminal: FakeTerminal())
        let resumed = board.resume(sessionPath: "/p/a.jsonl", sessionID: "a", tool: .claude, directory: "/w",
                                   now: start) { FakeTerminal() }!
        XCTAssertEqual(board.unlistedRuns(shown: ["/p/a.jsonl"]).map(\.id), [fresh.id], "新会话在顶上；继续的在它自己那一行")

        typealias C = CodeRunBoard<FakeTerminal>.Candidate
        board.reconcile([C(path: "/x1", sessionID: "x1", tool: .codex, directory: "/w/shop",
                           modifiedAt: start.addingTimeInterval(10))])
        XCTAssertEqual(board.unlistedRuns(shown: ["/p/a.jsonl"]).map(\.id), [fresh.id],
                       "对上了、但列表还没列出那份记录：留在顶上，不丢")
        XCTAssertTrue(board.unlistedRuns(shown: ["/p/a.jsonl", "/x1"]).isEmpty, "列出来了：回到那份记录平常的那一行")
        XCTAssertEqual(board.unlistedRuns(shown: []).map(\.id), [fresh.id, resumed.id])
    }

    // MARK: - 接到真终端

    private func container() throws -> (ModelContainer, ServerProfile) {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        return (container, try XCTUnwrap(MobileFixtures.firstServer(in: container)))
    }

    /// 一个接着假记录的 Code 标签页，run 的终端接假传输；返回每个 run 的假传输句柄（按起的先后）。
    private func codeTab(host: ServerProfile, source: any AgentHistorySource = MobileAgentHistoryFixture.source(),
                         script: MobileFakeTerminalScript = prompt) async throws
        -> (ClaudeHistoryTab, AgentHistoryModel, () -> [MobileFakeTerminalHandles]) {
        let tab = MobileAgentHistoryFixture.tab(host: host, source: source)
        var handles: [MobileFakeTerminalHandles] = []
        tab.runTerminalFactory = { host in
            let (term, h) = MobileFakeTerminal.tab(host: host, script)
            handles.append(h)
            return term
        }
        tab.start()
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled)
        return (tab, try XCTUnwrap(tab.connection.history), { handles })
    }

    private func resume(_ tab: ClaudeHistoryTab, _ model: AgentHistoryModel, tool: AgentHistoryTool,
                        container: ModelContainer) throws -> AgentHistorySessionFile {
        let file = try XCTUnwrap(model.visibleFiles.first { $0.tool == tool })
        tab.select(file)
        let plan = try XCTUnwrap(model.resumeCommand(for: file))
        tab.resumeInPlace(file, command: plan.command, directory: plan.directory, container: container,
                          relay: HostKeyChallengeRelay())
        return file
    }

    /// 继续：就在标签页里起终端，连上之后打进命令（后面接 `; exit`）；连接中页撤下之前键盘不归它。
    /// 点别的会话不打断，点回去回到它；「记录」切换不另开一层。
    func testResumeRunsInTheTabAndSwitchingKeepsItRunning() async throws {
        let (container, host) = try container()
        let (tab, model, handles) = try await codeTab(host: host)
        let file = try resume(tab, model, tool: .codex, container: container)
        let run = try XCTUnwrap(tab.runs.focused)
        XCTAssertEqual(run.sessionPath, file.path)
        XCTAssertNotNil(tab.runCovers[run.id], "连接中页在详情里")
        XCTAssertNil(tab.keyboardTerminal, "连接中页盖着时键盘不归它")

        let connected = await MobileFakeTerminal.waitUntilConnected(run.terminal.controller)
        XCTAssertTrue(connected)
        let command = "cd -- '\(MobileAgentHistoryFixture.shop)' && codex resume x-tests; exit\r"
        // 假传输的账本在 actor 里：轮询着取。
        var written = ""
        for _ in 0..<100 {
            written = await handles().first?.latest?.writtenText ?? ""
            if written.contains(command) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(written.hasSuffix(command), "打进命令：\(written.debugDescription)")
        tab.finishCover(run.id)
        XCTAssertTrue(tab.keyboardTerminal === run.terminal)

        let other = try XCTUnwrap(model.visibleFiles.first { $0.tool == .claude })
        tab.select(other)
        XCTAssertNil(tab.runs.focused)
        XCTAssertEqual(model.selectedFile?.path, other.path)
        XCTAssertEqual(tab.runs.runningCount, 1, "点别的会话不打断")
        XCTAssertEqual(run.terminal.controller.state, .connected)
        XCTAssertNil(tab.keyboardTerminal)

        tab.select(file)
        XCTAssertEqual(tab.runs.focusedID, run.id, "点回去回到它的终端")
        XCTAssertTrue(tab.keyboardTerminal === run.terminal)
        tab.setShowsTerminal(run.id, false)
        XCTAssertEqual(model.selectedFile?.path, file.path, "「记录」看的是它自己的记录")
        XCTAssertNil(tab.keyboardTerminal, "看记录时键盘不归终端")
        XCTAssertEqual(tab.runs.focusedID, run.id, "还是这个会话，只是换了一面")
        tab.close()
    }

    /// 程序退出（shell 跟着结束）：跑得够久的回到只读记录，记录重新从末尾读；很快就退出的留着终端，标成已退出。
    func testProgramExitReturnsToTheFreshRecord() async throws {
        let (container, host) = try container()
        let (tab, model, handles) = try await codeTab(host: host)
        tab.runs.quickExit = 0
        let file = try resume(tab, model, tool: .claude, container: container)
        let run = try XCTUnwrap(tab.runs.focused)
        let connected = await MobileFakeTerminal.waitUntilConnected(run.terminal.controller)
        XCTAssertTrue(connected)
        let before = model.transcript

        await handles()[0].latest?.simulateDrop()
        let back = await MobileFakeTerminal.waitUntil { tab.runs.runs.isEmpty }
        XCTAssertTrue(back, "程序退出，会话回到记录")
        let reopened = await MobileFakeTerminal.waitUntil {
            model.selectedFile?.path == file.path && model.transcript != nil && model.transcript !== before
        }
        XCTAssertTrue(reopened, "记录重新读到最新")
        XCTAssertNil(tab.runs.focused)

        tab.runs.quickExit = 60
        _ = try resume(tab, model, tool: .codex, container: container)
        let quick = try XCTUnwrap(tab.runs.focused)
        _ = await MobileFakeTerminal.waitUntilConnected(quick.terminal.controller)
        await handles()[1].latest?.simulateDrop()
        let kept = await MobileFakeTerminal.waitUntil { tab.runs.run(id: quick.id)?.isRunning == false }
        XCTAssertTrue(kept, "很快就退出的留着给人看")
        XCTAssertNil(tab.keyboardTerminal, "已退出的不拿键盘")
        tab.endRun(quick.id)
        XCTAssertTrue(tab.runs.runs.isEmpty)
        tab.close()
    }

    /// 「＋」新会话：先占「新会话」的位置，主机上写出记录之后认下来、读到标题。
    func testNewSessionPlaceholderIsMatchedToItsRecord() async throws {
        let (container, host) = try container()
        let start = Date()
        let source = MobileFakeAgentSource(tool: .codex, sessions: [
            .init(id: "x-old", projectID: "2026-11-01", projectDirectory: MobileAgentHistoryFixture.shop,
                  resumeDirectory: MobileAgentHistoryFixture.shop, title: "很早以前的", modifiedAt: start.addingTimeInterval(-86_400)),
            .init(id: "x-new", projectID: "2026-11-23", projectDirectory: MobileAgentHistoryFixture.shop,
                  resumeDirectory: MobileAgentHistoryFixture.shop, title: "刚开的这个", modifiedAt: start.addingTimeInterval(30)),
        ])
        let (tab, model, _) = try await codeTab(host: host, source: AgentHistoryCompositeSource([
            source, MobileFakeAgentSource(tool: .claude, sessions: []),
        ]))
        let command = try XCTUnwrap(model.newSessionCommand(tool: .codex, directory: MobileAgentHistoryFixture.shop))
        tab.startNewInPlace(tool: .codex, command: command, directory: MobileAgentHistoryFixture.shop,
                            container: container, relay: HostKeyChallengeRelay())
        let run = try XCTUnwrap(tab.runs.focused)
        XCTAssertTrue(run.isNewSession)
        XCTAssertEqual(tab.title(of: run), AgentHistoryText.newSession)
        XCTAssertNil(model.selectedFile)

        await tab.matchNewSessions()
        let matched = try XCTUnwrap(tab.runs.run(id: run.id))
        XCTAssertEqual(matched.sessionID, "x-new")
        XCTAssertEqual(tab.title(of: matched), "刚开的这个")
        XCTAssertFalse(tab.runs.hasUnmatchedNewSessions)
        tab.close()
    }

    /// 长按菜单的「置顶」/「取消置顶」：置顶的会话进最上面一组「置顶」，原来那一组里不再出现；取消后回去。按主机记、存本机偏好。
    func testLongPressMenuPinsAndUnpins() async throws {
        // 容器要活到用例结束：主机是它里面的模型。
        let (container, host) = try container()
        defer { withExtendedLifetime(container) {} }
        let suite = "CodeTabRunsTests.pins.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tab = MobileAgentHistoryFixture.tab(host: host, source: MobileAgentHistoryFixture.source(), pinDefaults: defaults)
        tab.start()
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(tab.connection.history)
        let pins = try XCTUnwrap(model.pins, "直连的主机能置顶")
        XCTAssertEqual(pins.host, .server(host.id))
        XCTAssertNil(MobileAgentHistoryFixture.tab(host: host, source: MobileAgentHistoryFixture.source()).connection.history?.pins)

        let codex = try XCTUnwrap(model.visibleFiles.first { $0.tool == .codex })
        let claude = try XCTUnwrap(model.visibleFiles.first { $0.tool == .claude })
        XCTAssertEqual(AgentHistoryText.pinAction(isPinned: pins.isPinned(codex)), AgentHistoryText.pinAction(isPinned: false))
        pins.toggle(codex)
        pins.toggle(claude)
        XCTAssertEqual(model.pinnedFiles.map(\.path), [codex.path, claude.path], "置顶的先后：新置顶的排最后（同 Mac 的菜单）")
        let groups = AgentHistoryListing.groups(model.visibleFiles, by: .project, metadata: model.metadata,
                                                pinned: model.pinnedFiles)
        XCTAssertEqual(groups.first?.kind, .pinned)
        XCTAssertTrue(groups.first?.mixesTools == true, "「置顶」里混着两种工具：行上写工具名")
        XCTAssertFalse(groups.dropFirst().flatMap(\.files).contains { $0.path == codex.path }, "原来那一组里不再出现")
        XCTAssertEqual(AgentHistoryText.pinAction(isPinned: pins.isPinned(codex)), AgentHistoryText.pinAction(isPinned: true))

        pins.toggle(codex)
        XCTAssertEqual(model.pinnedFiles.map(\.path), [claude.path], "取消置顶")
        XCTAssertNotNil(defaults.data(forKey: DefaultsKey.agentHistoryPinnedSessions), "存在本机偏好（这里是一次性的）")
        tab.close()
    }

    // MARK: - 工作区

    /// 关 Code 标签页：里面有程序在跑就照终端标签页问；确认后里面的会话一起结束。
    func testClosingAsksWhileSessionsRunAndEndsThem() async throws {
        let (container, host) = try container()
        let (tab, model, handles) = try await codeTab(host: host)
        let ws = MobileWorkspace()
        ws.openHistory(tab)
        _ = try resume(tab, model, tool: .codex, container: container)
        let run = try XCTUnwrap(tab.runs.focused)
        _ = await MobileFakeTerminal.waitUntilConnected(run.terminal.controller)
        await handles()[0].latest?.setForegroundActivity(.running("codex"))

        let flow = MTabCloseFlow()
        var closed: [UUID] = []
        flow.request(try XCTUnwrap(ws.tab(tab.id))) { closed.append($0) }
        let asked = await MobileFakeTerminal.waitUntil { flow.pending != nil }
        XCTAssertTrue(asked, "有程序在跑：先问")
        XCTAssertEqual(flow.pending?.tabID, tab.id)
        XCTAssertEqual(closed, [])

        let removed = try XCTUnwrap(ws.close(tab.id))
        removed.shutdown()
        removed.disposeSession()
        XCTAssertTrue(tab.runs.runs.isEmpty, "里面的会话一起结束")
        XCTAssertEqual(run.terminal.controller.state, .disconnected)
        // 传输是丢给任务去关的：等一下。
        var closedCount = 0
        for _ in 0..<50 where closedCount == 0 {
            closedCount = await handles()[0].latest?.closeCount ?? 0
            if closedCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertGreaterThan(closedCount, 0, "连接关掉")

        // 没有会话在跑的 Code 标签页直接关。
        let idle = MobileAgentHistoryFixture.tab(host: host, source: MobileAgentHistoryFixture.source())
        ws.openHistory(idle)
        flow.request(try XCTUnwrap(ws.tab(idle.id))) { closed.append($0) }
        XCTAssertEqual(closed, [idle.id])
    }

    /// 键盘归属、实时活动、深链接、归档：Code 标签页里跑着的会话照终端标签页那样算。
    func testRunsCountAsTerminalsForKeyboardArchiveAndLinks() async throws {
        let (container, host) = try container()
        let (tab, model, _) = try await codeTab(host: host)
        let ws = MobileWorkspace()
        let (shell, _) = MobileFakeTerminal.tab(host: host, Self.prompt)
        shell.controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        ws.open(.terminal(shell))
        ws.openHistory(tab)
        _ = try resume(tab, model, tool: .codex, container: container)
        let run = try XCTUnwrap(tab.runs.focused)
        _ = await MobileFakeTerminal.waitUntilConnected(run.terminal.controller)
        _ = await MobileFakeTerminal.waitUntilConnected(shell.controller)
        tab.finishCover(run.id)

        XCTAssertEqual(ws.allTerminals.map(\.term.id), [shell.id, run.terminal.id])
        XCTAssertTrue(ws.allTerminals.allSatisfy { $0.paneID == ws.panes[0].id })
        ws.handKeyboard(to: tab.keyboardTerminal)
        XCTAssertTrue(run.terminal.controller.ownsKeyboard, "Code 标签页在前台、详情是终端：键盘归它")
        XCTAssertFalse(shell.controller.ownsKeyboard)

        let archive = ws.terminalTabArchive(showsWorkspace: true)
        XCTAssertEqual(archive.tabs.map(\.sessionID), [shell.controller.hostSessionID, run.terminal.controller.hostSessionID],
                       "按终端标签页记下会话 id，重新打开后以普通终端标签页接回")
        XCTAssertEqual(archive.activeIndex, 1, "前台是 Code 标签页里看着的那个会话")

        ws.activate(shell.id)
        tab.select(try XCTUnwrap(model.visibleFiles.first { $0.tool == .claude }))
        XCTAssertTrue(ws.revealTerminal(run.terminal.id), "灵动岛 / 通知的深链接找得到 Code 标签页里的会话")
        XCTAssertEqual(ws.activeTab?.id, tab.id)
        XCTAssertEqual(tab.runs.focusedID, run.id)

        // 挪成普通终端标签页：同一个终端，开在 Code 标签页那一格。
        let moved = try XCTUnwrap(tab.moveRunToTab(run.id, in: ws))
        XCTAssertTrue(moved === run.terminal)
        XCTAssertTrue(tab.runs.runs.isEmpty)
        XCTAssertEqual(ws.activeTab?.id, moved.id)
        XCTAssertEqual(moved.controller.state, .connected, "挪过去不断开")
        ws.close(moved.id)?.shutdown()
        shell.controller.close()
        tab.close()
    }

    /// 终端标签长按「历史会话」：开这台主机的 Code 标签页，定位到终端当前目录；已经开着的带到前台、再定位一次。
    func testLongPressOpensTheCodeTabAtTheTerminalDirectory() async throws {
        let (container, host) = try container()
        let ws = MobileWorkspace()
        let osc7 = "\u{1B}]7;file://box\(MobileAgentHistoryFixture.shop)\u{07}% "
        let (shell, _) = MobileFakeTerminal.tab(host: host, .transcript(osc7))
        shell.controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        ws.open(.terminal(shell))
        let reported = await MobileFakeTerminal.waitUntil { shell.claudeHistoryDirectory != nil }
        XCTAssertTrue(reported)

        let code = try XCTUnwrap(ws.showCode(for: shell, container: container))
        XCTAssertEqual(ws.activeTab?.id, code.id)
        XCTAssertEqual(code.pendingReveal?.directory, MobileAgentHistoryFixture.shop)
        XCTAssertEqual(code.connection.tools, AgentHistoryTool.allCases)
        code.pendingReveal = nil

        ws.activate(shell.id)
        let again = try XCTUnwrap(ws.showCode(for: shell, container: container))
        XCTAssertTrue(again === code, "一台主机一个")
        XCTAssertEqual(ws.activeTab?.id, code.id)
        XCTAssertEqual(code.pendingReveal?.directory, MobileAgentHistoryFixture.shop, "再定位一次")

        let (demo, _) = MobileFakeTerminal.tab(host: DemoHostProfile.shared, .idle)
        XCTAssertNil(ws.showCode(for: demo, container: container), "体验主机没有")
        code.close()
        shell.controller.close()
    }

    /// 窄屏：详情这一层在「终端」与「记录」之间换（不另开一层）；露着终端时终端算前台，看记录时不算。
    func testNarrowDetailSwitchesBetweenTerminalAndRecord() async throws {
        let (container, host) = try container()
        let (tab, model, _) = try await codeTab(host: host)
        let store = MobileStore()
        store.showWorkspace = true
        let relay = HostKeyChallengeRelay()
        let ws = MobileWorkspace()
        ws.openHistory(tab)
        _ = MobileProbeWindow.make(size: CGSize(width: 390, height: 760), rootView:
            ClaudeHistorySessionBody(tab: tab) { _, _ in }
                .environment(store).environment(relay).environment(ws)
                .modelContainer(container)
                .defaultAppStorage(UserDefaults(suiteName: "CodeTabRunsTests.narrow")!))
        defer { UserDefaults().removePersistentDomain(forName: "CodeTabRunsTests.narrow") }

        let file = try XCTUnwrap(model.visibleFiles.first { $0.tool == .codex })
        tab.select(file)
        let plan = try XCTUnwrap(model.resumeCommand(for: file))
        tab.resumeInPlace(file, command: plan.command, directory: plan.directory, container: container, relay: relay)
        let run = try XCTUnwrap(tab.runs.focused)
        let connected = await MobileFakeTerminal.waitUntilConnected(run.terminal.controller)
        XCTAssertTrue(connected)
        tab.finishCover(run.id)
        let foreground = await MobileFakeTerminal.waitUntil { run.terminal.controller.isForeground }
        XCTAssertTrue(foreground, "详情露着终端：终端算前台")
        XCTAssertNotNil(run.terminal.controller.terminal.view.window, "终端挂在窗口里")

        tab.setShowsTerminal(run.id, false)
        let background = await MobileFakeTerminal.waitUntil { !run.terminal.controller.isForeground }
        XCTAssertTrue(background, "看记录时终端不算前台（移到屏外，不是透明）")
        XCTAssertNotNil(model.transcript, "同一层里换成记录")
        XCTAssertEqual(tab.runs.runs.count, 1)

        tab.setShowsTerminal(run.id, true)
        let back = await MobileFakeTerminal.waitUntil { run.terminal.controller.isForeground }
        XCTAssertTrue(back)
        tab.backToList()
        let listed = await MobileFakeTerminal.waitUntil { !run.terminal.controller.isForeground }
        XCTAssertTrue(listed, "返回列表：终端退到后面，会话照跑")
        XCTAssertEqual(run.terminal.controller.state, .connected)
        tab.close()
    }
}
