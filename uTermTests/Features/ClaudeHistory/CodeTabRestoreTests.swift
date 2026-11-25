import UPaneGroups
import UPaneTree
import XCTest
@testable import uTerm

/// 重启之后 Code 标签页还是 Code 标签页：在原位开回来，里面跑着的会话回到它里面、对上原来的记录，右边看的那个还原；
/// 空的 Code 标签页跟着窗口回来；App 不在时程序已经退出的会话收尾；旧版存的布局照旧接回、旧版读到新版存的也不丢会话。
///
/// 不起真 shell / 真 SSH：布局写进每个会话要交给保持进程的归属，这里取那份归属走一遍 JSON（保持进程里存的就是它），
/// 交给全新的窗口模型接回（同 `HeldSessionLayoutRestoreTests`）。记录是手写的假数据。
@MainActor
final class CodeTabRestoreTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private static let shop = "/srv/shop"
    private static let infra = "/srv/infra"
    private let registry = TerminalSessionRegistry()

    // MARK: 夹具

    private func session(_ id: String, in directory: String, title: String, ago seconds: TimeInterval) -> Session {
        Session(id: id, projectID: ClaudeProjectPath.encode(directory), resumeDirectory: directory, title: title,
                modifiedAt: Date().addingTimeInterval(-seconds))
    }

    private func history(_ source: AgentHistoryFakeSource) async -> AgentHistoryModel {
        let history = AgentHistoryModel(source: source, preferredDirectory: Self.shop, followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return history
    }

    private func file(_ history: AgentHistoryModel, _ id: String) throws -> AgentHistorySessionFile {
        try XCTUnwrap(history.files.first { $0.sessionID == id })
    }

    private func localModel(windowID: UUID) -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { _ in })
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: windowID,
                                              windowKind: TerminalWindowKind.terminal))
        return model
    }

    private func localTree(_ model: LocalShellWindowModel) -> UPaneGroupsSnapshot<UUID> {
        model.groups.snapshot(LocalShellWindowModel.layoutTabID)
    }

    /// 等布局（含 Code 标签页）写进每个 shell，返回各自存进保持进程的归属，已经过一遍 JSON。
    private func storedLocal(_ model: LocalShellWindowModel, file: StaticString = #filePath, line: UInt = #line)
        async throws -> [(id: UUID, attributes: LocalShellSessionAttributes)] {
        let tree = localTree(model)
        let codeTabs = model.codeTabRecords()
        let written = await wait {
            model.panes.allSatisfy { $0.attributes?.layout?.tree == tree && ($0.attributes?.layout?.codeTabs ?? []) == codeTabs }
        }
        XCTAssertTrue(written, "布局没写进每个会话", file: file, line: line)
        return try model.panes.map { pane in
            let data = try JSONEncoder().encode(try XCTUnwrap(pane.attributes))
            return (pane.id, try JSONDecoder().decode(LocalShellSessionAttributes.self, from: data))
        }
    }

    private func wait(timeout: TimeInterval = 3, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: 本机终端窗口

    func testLocalShellCodeTabComesBackInPlaceWithItsRunsAndSelection() async throws {
        let windowID = UUID()
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [
            session("a1", in: Self.shop, title: "登录接口偶发 500", ago: 600),
            session("b2", in: Self.infra, title: "升级 nginx", ago: 3600),
        ])
        let model = localModel(windowID: windowID)
        let left = model.addTab(directory: Self.shop)
        let codeID = model.openCodeTab(directory: Self.shop)
        let right = model.addTab()
        // 分屏：Code 标签页和左边那个 shell 一组，右边一个 shell 一组。
        let group = try XCTUnwrap(model.groups.locateTab(right)?.groupID)
        model.groups.moveTab(right, toGroup: group, zone: .trailing)
        let code = try XCTUnwrap(model.groups.tab(codeID)?.payload.codeTab)
        let before = await history(source)
        code.install(AgentHistoryConnection(history: before))
        let resumed = try XCTUnwrap(code.resume(try file(before, "a1")))
        let fresh = try XCTUnwrap(code.startNewSession(tool: .codex, command: "codex", directory: Self.infra))
        code.selectRun(resumed.id)
        XCTAssertTrue(model.reveal(resumed.id), "Code 标签页在前台，右边是继续的那个会话")
        let marker = try XCTUnwrap(model.pane(resumed.id)?.session.trackedRun?.id)
        let expected = localTree(model)
        XCTAssertEqual(expected.groups.map(\.tabs), [[left, codeID], [right]])

        let stored = try await storedLocal(model)
        XCTAssertEqual(Set(stored.map(\.id)), [left, right, resumed.id, fresh.id], "Code 标签页里跑着的 shell 也各存一份")
        let record = try XCTUnwrap(stored.first?.attributes.layout?.codeTabs?.first)
        XCTAssertEqual(record.id, codeID)
        XCTAssertEqual(record.runs.map(\.session), [resumed.id, fresh.id])
        XCTAssertEqual(record.runs.map(\.sessionID), ["a1", nil], "对上了的记工具 + 会话 ID，新会话没有")
        XCTAssertEqual(record.runs.map(\.tool), ["claude", "codex"])
        XCTAssertEqual(record.runs.first?.marker, marker)
        XCTAssertEqual(record.selectedRun, resumed.id)
        XCTAssertEqual(record.directory, Self.shop)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.contains("登录接口") || json.contains("/fake/"), "不存标题、不存记录文件的路径")
        model.disposeAll()

        let restored = localModel(windowID: windowID)
        LocalShellRestorer.adopt(stored.shuffled(), windowID: windowID, into: restored)
        XCTAssertEqual(localTree(restored), expected, "Code 标签页回到原位（顺序、分组）")
        XCTAssertEqual(restored.active?.id, codeID, "它原来在前台")
        XCTAssertEqual(restored.groups.allTabs.count, 3, "里面的会话不再各开一个标签页")
        let back = try XCTUnwrap(restored.groups.tab(codeID)?.payload.codeTab)
        XCTAssertEqual(back.runs.map(\.id), [resumed.id, fresh.id], "会话回到这个标签页里")
        XCTAssertEqual(Set(restored.panes.map(\.id)), [left, right, resumed.id, fresh.id], "照普通终端那样登记、关窗确认看得到")
        XCTAssertEqual(back.detail, .terminal(resumed.id), "列表还没读出来就先看它的终端")
        XCTAssertEqual(restored.focusedSessionID, resumed.id)
        let trackedRun = try XCTUnwrap(restored.pane(resumed.id)?.session.trackedRun)
        XCTAssertEqual(trackedRun.id, marker, "命令起止标记沿用原来的编号")
        XCTAssertEqual(trackedRun.phase, .running)
        XCTAssertTrue(trackedRun.injected, "不再打一遍命令")
        XCTAssertEqual(back.newSessionDirectory, Self.shop)

        // 列表读出来：继续的那个对回原来的记录，右边还是它的终端、列表选中它；新会话照旧等着对。
        let after = await history(source)
        back.install(AgentHistoryConnection(history: after))
        back.applyRestoredState()
        XCTAssertEqual(back.runs.first?.path, try file(after, "a1").path)
        XCTAssertNil(back.runs.last?.path)
        XCTAssertEqual(after.selectedFile?.sessionID, "a1")
        XCTAssertEqual(back.detail, .terminal(resumed.id))
        XCTAssertEqual(back.title(of: try XCTUnwrap(back.runs.first)), "登录接口偶发 500")
        XCTAssertEqual(back.unlistedRuns(shown: Set(after.visibleFiles.map(\.path))).map(\.id), [fresh.id],
                       "对回记录的回到列表里那一行（标「运行中」），新会话还在顶上")
        restored.disposeAll()
    }

    func testRestoredNewSessionStillMatchesItsRecord() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("old", in: Self.shop, title: "旧的", ago: 3600)])
        let terminal = FakeTerminal()
        let code = CodeTabModel(hostName: "h", directory: Self.shop) { _ in nil }
        let startedAt = Date().addingTimeInterval(-30)
        code.restore(CodeTabRecord(id: UUID(), runs: [
            CodeRunRecord(session: terminal.id, tool: .claude, sessionID: nil, directory: Self.shop, startedAt: startedAt,
                          marker: "1a2b3c4d"),
        ], selectedRun: terminal.id), terminals: [terminal.id: terminal])
        XCTAssertEqual(terminal.restoredMarker, "1a2b3c4d")
        let model = await history(source)
        code.install(AgentHistoryConnection(history: model))
        code.applyRestoredState()
        XCTAssertNil(code.runs.first?.path, "记录还没写出来：留着，不去认那份旧的（改的比它起得早）")
        XCTAssertEqual(code.detail, .terminal(terminal.id))

        await source.add(session("fresh", in: Self.shop, title: "给订单接口加分页", ago: 5))
        await code.refreshList()
        XCTAssertEqual(code.runs.first?.path, try file(model, "fresh").path, "按原来的规则对上")
        XCTAssertEqual(code.runs.first?.key, AgentHistoryPinKey(tool: .claude, sessionID: "fresh"))
        XCTAssertEqual(model.selectedFile?.sessionID, "fresh")
        XCTAssertEqual(code.detail, .terminal(terminal.id))
        code.close()
    }

    /// 右边看的是一份只读记录：列表读出来之后选回它。那份记录找不到了：退到第一个跑着的会话，没有就空着。
    func testRestoredRecordSelection() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [
            session("a1", in: Self.shop, title: "a", ago: 60),
            session("b2", in: Self.shop, title: "b", ago: 120),
        ])
        let model = await history(source)

        let reading = CodeTabModel(hostName: "h", directory: Self.shop) { _ in nil }
        reading.restore(CodeTabRecord(id: UUID(), selectedRecord: "claude:b2"), terminals: [:])
        XCTAssertEqual(reading.detail, .empty, "列表还没读出来")
        reading.install(AgentHistoryConnection(history: model))
        reading.applyRestoredState()
        XCTAssertEqual(model.selectedFile?.sessionID, "b2")
        XCTAssertEqual(reading.detail, .transcript)

        let terminal = FakeTerminal()
        let gone = CodeTabModel(hostName: "h", directory: Self.shop) { _ in nil }
        gone.restore(CodeTabRecord(id: UUID(), runs: [
            CodeRunRecord(session: terminal.id, tool: .claude, sessionID: "a1", directory: Self.shop, startedAt: Date()),
        ], selectedRecord: "claude:deleted"), terminals: [terminal.id: terminal])
        let other = await history(source)
        gone.install(AgentHistoryConnection(history: other))
        gone.applyRestoredState()
        XCTAssertEqual(gone.detail, .terminal(terminal.id), "记录没了：选中第一个跑着的会话")

        let empty = CodeTabModel(hostName: "h", directory: Self.shop) { _ in nil }
        empty.restore(CodeTabRecord(id: UUID(), selectedRecord: "claude:deleted"), terminals: [:])
        let third = await history(source)
        empty.install(AgentHistoryConnection(history: third))
        empty.applyRestoredState()
        XCTAssertEqual(empty.detail, .empty, "也没有跑着的：空着")

        // 看的是一个跑着的会话的记录（「查看记录」）：还原成看记录。
        let viewing = FakeTerminal()
        let transcript = CodeTabModel(hostName: "h", directory: Self.shop) { _ in nil }
        transcript.restore(CodeTabRecord(id: UUID(), runs: [
            CodeRunRecord(session: viewing.id, tool: .claude, sessionID: "a1", directory: Self.shop, startedAt: Date(),
                          showsTranscript: true),
        ], selectedRun: viewing.id), terminals: [viewing.id: viewing])
        let fourth = await history(source)
        transcript.install(AgentHistoryConnection(history: fourth))
        transcript.applyRestoredState()
        XCTAssertEqual(fourth.selectedFile?.sessionID, "a1")
        XCTAssertEqual(transcript.detail, .transcript)
        XCTAssertNotNil(transcript.run(for: try file(fourth, "a1").path), "记录标题行上是「返回终端」")

        // 用户先点了别的：不再还原。
        let clicked = CodeTabModel(hostName: "h", directory: Self.shop) { _ in nil }
        clicked.restore(CodeTabRecord(id: UUID(), selectedRecord: "claude:b2"), terminals: [:])
        let fifth = await history(source)
        clicked.install(AgentHistoryConnection(history: fifth))
        fifth.select(try file(fifth, "a1"))
        clicked.historySelectionChanged()
        clicked.applyRestoredState()
        XCTAssertEqual(fifth.selectedFile?.sessionID, "a1")
    }

    /// 窗口因为别的标签页被接回时，里面没有会话在跑的 Code 标签页也在原位回来。
    func testEmptyCodeTabComesBackWithTheWindow() async throws {
        let windowID = UUID()
        let model = localModel(windowID: windowID)
        let codeID = model.openCodeTab(directory: Self.shop)
        let shell = model.addTab()
        model.groups.reorderTab(codeID, before: shell)
        let expected = localTree(model)
        XCTAssertEqual(expected.groups.map(\.tabs), [[codeID, shell]])
        let stored = try await storedLocal(model)
        XCTAssertEqual(stored.map(\.id), [shell])
        model.disposeAll()

        let restored = localModel(windowID: windowID)
        LocalShellRestorer.adopt(stored, windowID: windowID, into: restored)
        XCTAssertEqual(localTree(restored), expected)
        XCTAssertEqual(restored.groups.tab(codeID)?.payload.codeTab?.runs.count, 0)
        XCTAssertEqual(restored.groups.tab(codeID)?.payload.codeTab?.newSessionDirectory, Self.shop)
        restored.disposeAll()
    }

    /// App 不在时结束了的会话（保持进程里已经没有它）：Code 标签页照样回来，只是没有它；看着的是它就退到别的跑着的会话。
    func testRunThatEndedWhileAwayIsNotRestored() throws {
        let windowID = UUID(), codeID = UUID(), alive = UUID(), ended = UUID()
        let layout = HeldSessionLayout(
            revision: 1,
            tree: .init(root: .leaf(groupIndex: 0), groups: [.init(tabs: [codeID], activeIndex: 0)], activeGroupIndex: 0),
            codeTabs: [CodeTabRecord(id: codeID, directory: Self.shop, runs: [
                CodeRunRecord(session: ended, tool: .claude, sessionID: "a1", directory: Self.shop, startedAt: Date()),
                CodeRunRecord(session: alive, tool: .codex, sessionID: nil, directory: Self.shop, startedAt: Date()),
            ], selectedRun: ended)])
        let restored = localModel(windowID: windowID)
        LocalShellRestorer.adopt([(alive, LocalShellSessionAttributes(windowID: windowID, ordinal: 2, layout: layout))],
                                 windowID: windowID, into: restored)
        let code = try XCTUnwrap(restored.groups.tab(codeID)?.payload.codeTab)
        XCTAssertEqual(code.runs.map(\.id), [alive])
        XCTAssertEqual(code.detail, .terminal(alive), "看着的那个没了：退到第一个跑着的")
        XCTAssertEqual(restored.groups.allTabs.count, 1)
        restored.disposeAll()
    }

    /// 认不出的工具（以后删掉的）：那个会话退回普通终端标签页，不丢。
    func testRunWithUnknownToolFallsBackToATerminalTab() throws {
        let windowID = UUID(), codeID = UUID(), run = UUID()
        let json = #"""
        {"revision":1,"tree":{"root":{"leaf":{"groupIndex":0}},"groups":[{"tabs":["\#(codeID.uuidString)"],"activeIndex":0}],"activeGroupIndex":0},
         "codeTabs":[{"id":"\#(codeID.uuidString)","runs":[{"session":"\#(run.uuidString)","tool":"someday","directory":"/srv","startedAt":0}]}]}
        """#
        let layout = try JSONDecoder().decode(HeldSessionLayout.self, from: Data(json.utf8))
        let restored = localModel(windowID: windowID)
        LocalShellRestorer.adopt([(run, LocalShellSessionAttributes(windowID: windowID, ordinal: 1, layout: layout))],
                                 windowID: windowID, into: restored)
        XCTAssertEqual(restored.groups.tab(codeID)?.payload.codeTab?.runs.count, 0)
        XCTAssertTrue(restored.groups.tab(run)?.payload.isTerminal == true, "照普通标签页接回")
        restored.disposeAll()
    }

    // MARK: 程序退出

    /// 接回后连上就问一次前台进程：停在提示符上 = App 不在时程序已经退出了，标成跑完；还有程序、判断不了都当它在跑。
    func testRestoredCommandEndsOnlyWhenTheShellIsBackAtThePrompt() async throws {
        for (activity, ended) in [(TerminalActivity.idle, true), (.running("claude"), false), (.unknown, false)] {
            let session = TerminalSession()
            session.restoreCodeCommand(marker: "feedbeef", startedAt: Date())
            XCTAssertFalse(session.codeCommandHasEnded, "没连上：当它在跑")
            let backend = MockBackend()
            await backend.setForegroundActivity(activity)
            await session.connect(using: backend)
            XCTAssertEqual(session.connectionState, .connected)
            if ended {
                let settled = await wait { session.codeCommandHasEnded }
                XCTAssertTrue(settled, "停在提示符上：标成跑完")
            } else {
                try? await Task.sleep(for: .milliseconds(800))
                XCTAssertFalse(session.codeCommandHasEnded, "\(activity)：当它还在跑")
            }
            session.dispose()
        }
    }

    /// 接回之后程序才退出：结束标记沿用原来的编号，照样认得出来。
    func testEndMarkerAfterRestoreIsRecognized() async throws {
        let session = TerminalSession()
        session.restoreCodeCommand(marker: "feedbeef", startedAt: Date())
        session.handleUnknownOSC(Data("6973;D;other;0".utf8), cursor: nil)
        XCTAssertFalse(session.codeCommandHasEnded, "别的命令的标记不算")
        session.handleUnknownOSC(Data("6973;D;feedbeef;0".utf8), cursor: nil)
        XCTAssertTrue(session.codeCommandHasEnded)
        session.dispose()
    }

    /// 标签页这一层：接回的会话程序退出了照常收尾，回到它的记录。
    func testRestoredRunThatEndedGoesBackToItsRecord() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a1", in: Self.shop, title: "a", ago: 60)])
        let terminal = FakeTerminal()
        let code = CodeTabModel(hostName: "h", directory: Self.shop) { _ in nil }
        code.restore(CodeTabRecord(id: UUID(), runs: [
            CodeRunRecord(session: terminal.id, tool: .claude, sessionID: "a1", directory: Self.shop, startedAt: Date()),
        ], selectedRun: terminal.id), terminals: [terminal.id: terminal])
        let model = await history(source)
        code.install(AgentHistoryConnection(history: model))
        code.applyRestoredState()
        terminal.codeCommandHasEnded = true
        code.checkRuns()
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertTrue(terminal.disposed)
        XCTAssertEqual(code.detail, .transcript)
        XCTAssertEqual(model.selectedFile?.sessionID, "a1")

        // 列表还没读出来就认出程序退出了：列表读出来之后选中它的记录。
        let early = FakeTerminal()
        let second = CodeTabModel(hostName: "h", directory: Self.shop) { _ in nil }
        second.restore(CodeTabRecord(id: UUID(), runs: [
            CodeRunRecord(session: early.id, tool: .claude, sessionID: "a1", directory: Self.shop, startedAt: Date()),
        ], selectedRun: early.id), terminals: [early.id: early])
        early.codeCommandHasEnded = true
        second.checkRuns()
        XCTAssertEqual(second.runs.first?.isEnded, true, "还不知道有没有对话记录：终端先留着")
        let later = await history(source)
        second.install(AgentHistoryConnection(history: later))
        second.applyRestoredState()
        XCTAssertTrue(second.runs.isEmpty, "找回了有对话的记录：照常收尾")
        XCTAssertTrue(early.disposed)
        XCTAssertEqual(later.selectedFile?.sessionID, "a1")
        XCTAssertEqual(second.detail, .transcript)
    }

    // MARK: 新读旧、旧读新

    /// 旧版存的布局（没有 `codeTabs`、树里没有 Code 标签页）：照旧接回。
    func testOldLayoutWithoutCodeTabsRestoresAsBefore() throws {
        let windowID = UUID(), a = UUID(), b = UUID()
        let json = #"""
        {"revision":3,"tree":{"root":{"leaf":{"groupIndex":0}},"groups":[{"tabs":["\#(b.uuidString)","\#(a.uuidString)"],"activeIndex":1}],"activeGroupIndex":0}}
        """#
        let layout = try JSONDecoder().decode(HeldSessionLayout.self, from: Data(json.utf8))
        XCTAssertNil(layout.codeTabs)
        let restored = localModel(windowID: windowID)
        LocalShellRestorer.adopt([
            (a, LocalShellSessionAttributes(windowID: windowID, ordinal: 1, layout: layout)),
            (b, LocalShellSessionAttributes(windowID: windowID, ordinal: 2, layout: layout)),
        ], windowID: windowID, into: restored)
        XCTAssertEqual(restored.panes.map(\.id), [b, a])
        XCTAssertEqual(restored.active?.id, a)
        restored.disposeAll()
    }

    /// `codeTabs` 是别的版本写的、解不开：整份布局照用，那些会话退回普通终端标签页。
    func testUnreadableCodeTabsKeepTheRestOfTheLayout() throws {
        let a = UUID()
        let json = #"""
        {"revision":1,"tree":{"root":{"leaf":{"groupIndex":0}},"groups":[{"tabs":["\#(a.uuidString)"],"activeIndex":0}],"activeGroupIndex":0},"codeTabs":{"v":9}}
        """#
        let layout = try JSONDecoder().decode(HeldSessionLayout.self, from: Data(json.utf8))
        XCTAssertNil(layout.codeTabs)
        XCTAssertEqual(layout.tree.groups.first?.tabs, [a])
    }

    /// 旧版读到新版存的布局（用户降级，保持进程里留着新格式）：用旧结构体的副本解，解得开，
    /// 按旧版的接回规则（只认会话 id）Code 标签页里的会话照普通终端标签页接回，一个不丢，别的标签照原位。
    func testOldVersionReadingNewLayoutKeepsEverySession() async throws {
        /// 旧版的 `HeldSessionLayout`（2.x 加 Code 标签页之前）与两种归属：只有这些字段，合成的解码器。
        struct OldLayout: Codable {
            var revision: Double
            var tree: UPaneGroupsSnapshot<UUID>
            var window: HeldWindowFrame?
        }
        struct OldLocalAttributes: Decodable {
            var windowID: UUID
            var ordinal: Int
            var layout: OldLayout?
        }
        struct OldSSHAttributes: Decodable {
            var windowID: UUID
            var serverID: UUID
            var title: String
            var order: Double
            var layout: OldLayout?
        }

        let windowID = UUID()
        let model = localModel(windowID: windowID)
        let left = model.addTab()
        let codeID = model.openCodeTab(directory: Self.shop)
        let right = model.addTab()
        let code = try XCTUnwrap(model.groups.tab(codeID)?.payload.codeTab)
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: Self.shop))
        let stored = try await storedLocal(model)
        model.disposeAll()

        // 旧版解得开新版写的归属（`codeTabs` 这个键它不认识、忽略），布局也在。
        let old = try stored.map { entry in
            (entry.id, try JSONDecoder().decode(OldLocalAttributes.self, from: JSONEncoder().encode(entry.attributes)))
        }
        let oldLayout = try XCTUnwrap(old.first?.1.layout)
        XCTAssertEqual(oldLayout.tree.groups.first?.tabs, [left, codeID, right], "树里记着 Code 标签页的 id")

        // 旧版的接回：只拿会话 id 套布局（它不知道 Code 标签页）。
        let restored = localModel(windowID: windowID)
        restored.adopt(old.map { (id: $0.0, ordinal: $0.1.ordinal) },
                       layout: HeldSessionLayout(revision: oldLayout.revision, tree: oldLayout.tree, window: oldLayout.window))
        XCTAssertEqual(Set(restored.panes.map(\.id)), [left, right, run.id], "一个会话都不丢")
        XCTAssertEqual(restored.groups.allTabs.map(\.id), [left, right, run.id],
                       "Code 标签页那一格丢掉，里面的会话接在后面成普通终端标签页")
        XCTAssertTrue(restored.groups.allTabs.allSatisfy { $0.payload.isTerminal })
        restored.disposeAll()

        // SSH 那边的归属同理。
        let server = UUID()
        let workspace = WorkspaceModel()
        workspace.attachSessionRegistry(registry, windowID: windowID, windowKind: TerminalWindowKind.terminal)
        workspace.openServer(profileID: server, title: "prod-web-01")
        let sshCodeID = workspace.openCodeTab(serverID: server, hostName: "prod-web-01", directory: Self.shop)
        let sshCode = try XCTUnwrap(workspace.terminalGroups.tab(sshCodeID)?.payload.codeTab)
        _ = try XCTUnwrap(sshCode.startNewSession(tool: .claude, command: "claude", directory: Self.shop))
        let panes = workspace.terminalPanes
        let written = await wait { panes.allSatisfy { $0.heldAttributes()?.layout?.codeTabs?.first?.runs.count == 1 } }
        XCTAssertTrue(written)
        for pane in panes {
            let data = try JSONEncoder().encode(try XCTUnwrap(pane.heldAttributes()))
            let decoded = try JSONDecoder().decode(OldSSHAttributes.self, from: data)
            XCTAssertEqual(decoded.serverID, server)
            XCTAssertNotNil(decoded.layout)
        }
        workspace.dispose()
    }

    // MARK: SSH 终端窗口

    func testSSHTerminalWindowCodeTabComesBackWithItsRuns() async throws {
        let windowID = UUID(), server = UUID()
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a1", in: Self.shop, title: "t", ago: 60)])
        let workspace = WorkspaceModel()
        workspace.attachSessionRegistry(registry, windowID: windowID, windowKind: TerminalWindowKind.terminal)
        let first = workspace.openServer(profileID: server, title: "prod-web-01")
        let codeID = workspace.openCodeTab(serverID: server, hostName: "prod-web-01", directory: Self.shop)
        let codePane = try XCTUnwrap(workspace.terminalGroups.tab(codeID)?.payload)
        let code = try XCTUnwrap(codePane.codeTab)
        code.install(AgentHistoryConnection(history: await history(source)))
        let run = try XCTUnwrap(code.resume(try file(try XCTUnwrap(code.history), "a1")))
        workspace.terminalGroups.reorderTab(codeID, before: first)
        let firstPane = try XCTUnwrap(workspace.terminalGroups.tab(first)?.payload.id)
        let expected = workspace.terminalGroups.snapshot(WorkspaceModel.layoutTabID)
        XCTAssertEqual(expected.groups.map(\.tabs), [[codePane.id, firstPane]])

        let panes = workspace.terminalPanes
        let written = await wait {
            panes.allSatisfy { $0.heldAttributes()?.layout?.tree == expected && $0.heldAttributes()?.layout?.codeTabs?.count == 1 }
        }
        XCTAssertTrue(written, "布局没写进每条会话")
        let sessions = try panes.map { pane -> SSHSessionRestorer.Session in
            let data = try JSONEncoder().encode(try XCTUnwrap(pane.heldAttributes()))
            let attributes = try JSONDecoder().decode(SSHSessionAttributes.self, from: data)
            return SSHSessionRestorer.Session(id: pane.id, serverID: attributes.serverID, title: attributes.title,
                                              order: attributes.order, layout: attributes.layout)
        }
        workspace.dispose()

        let restored = WorkspaceModel()
        restored.attachSessionRegistry(registry, windowID: windowID, windowKind: TerminalWindowKind.terminal)
        restored.adoptHeldSessions(sessions, knownServerIDs: [server])
        XCTAssertEqual(restored.terminalGroups.snapshot(WorkspaceModel.layoutTabID), expected, "Code 标签页回到原位")
        let tab = try XCTUnwrap(restored.terminalGroups.allTabs.first)
        let back = try XCTUnwrap(tab.payload.codeTab)
        XCTAssertEqual(tab.payload.serverProfileID, server)
        XCTAssertEqual(back.hostName, "prod-web-01")
        XCTAssertEqual(back.runs.map(\.id), [run.id], "会话回到这个标签页里")
        XCTAssertEqual(restored.terminalGroups.allTabs.count, 2)
        XCTAssertEqual(Set(restored.terminalPanes.map(\.id)), [firstPane, run.id])
        XCTAssertEqual(restored.focusedTerminalSessionID, run.id)
        XCTAssertEqual((back.runs.first?.terminal as? PaneModel)?.tabTitle, "prod-web-01")

        // 主机已经删了：Code 标签页不开（会话本身由恢复器按同一张表筛）。
        let deleted = WorkspaceModel()
        deleted.adoptHeldSessions(sessions.filter { $0.id == firstPane }, knownServerIDs: [UUID()])
        XCTAssertTrue(deleted.terminalGroups.allTabs.allSatisfy { $0.payload.codeTab == nil })
        restored.dispose()
        deleted.dispose()
    }

    /// 工作区窗口：标签的位置以工作区自己的快照为准（快照里没有 Code 标签页），Code 标签页插回它在布局里的邻居旁边，
    /// 不动已有标签的位置和前台。
    func testWorkspaceWindowInsertsCodeTabNextToItsNeighbors() async throws {
        let windowID = UUID(), server = UUID()
        let workspace = WorkspaceModel()
        workspace.attachSessionRegistry(registry, windowID: windowID, windowKind: TerminalWindowKind.workspace)
        let a = workspace.openServer(profileID: server, title: "h")
        let codeID = workspace.openCodeTab(serverID: server, hostName: "h", directory: Self.shop)
        let b = workspace.openServer(profileID: server, title: "h")
        let code = try XCTUnwrap(workspace.terminalGroups.tab(codeID)?.payload.codeTab)
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: Self.shop))
        workspace.terminalGroups.activateTab(groupID: try XCTUnwrap(workspace.terminalGroups.activeGroupID), index: 2)
        let paneA = try XCTUnwrap(workspace.terminalGroups.tab(a)?.payload.id)
        let paneB = try XCTUnwrap(workspace.terminalGroups.tab(b)?.payload.id)
        let codePaneID = try XCTUnwrap(workspace.terminalGroups.tab(codeID)?.payload.id)
        let snapshot = workspace.snapshot()
        let panes = workspace.terminalPanes
        let written = await wait { panes.allSatisfy { $0.heldAttributes()?.layout?.codeTabs?.count == 1 } }
        XCTAssertTrue(written)
        let sessions = try panes.map { pane -> SSHSessionRestorer.Session in
            let attributes = try XCTUnwrap(pane.heldAttributes())
            return SSHSessionRestorer.Session(id: pane.id, serverID: server, title: attributes.title,
                                              order: attributes.order, layout: attributes.layout)
        }
        workspace.dispose()

        let restored = WorkspaceModel()
        restored.restore(from: snapshot, knownServerIDs: [server])
        XCTAssertEqual(restored.terminalGroups.allTabs.map(\.payload.id), [paneA, paneB], "快照里没有 Code 标签页")
        restored.adoptHeldSessions(sessions, knownServerIDs: [server])
        XCTAssertEqual(restored.terminalGroups.allTabs.map(\.payload.id), [paneA, codePaneID, paneB], "插回原来的位置")
        XCTAssertEqual(restored.terminalGroups.activeTab?.payload.id, paneB, "不抢前台")
        XCTAssertEqual(restored.terminalGroups.allTabs[1].payload.codeTab?.runs.map(\.id), [run.id])
        restored.dispose()
    }

    // MARK: 假终端

    private final class FakeTerminal: CodeTabTerminal {
        let id = UUID()
        private(set) var disposed = false
        private(set) var restoredMarker: String?
        var codeCommandHasEnded = false
        func runCodeCommand(_ command: String) {}
        func dispose() { disposed = true }
        func restoreCodeCommand(marker: String?, startedAt: Date) { restoredMarker = marker }
    }
}
