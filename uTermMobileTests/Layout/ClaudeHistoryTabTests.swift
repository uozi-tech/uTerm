import Network
import SwiftData
import SwiftUI
import XCTest
@testable import uTermMobile

/// 「Claude 历史会话」标签：放进工作区、一台主机一个、关掉放掉通道、远控 Mac 没有 `files` 能力时不给入口，
/// 以及「继续这个会话」新开的终端标签在行编辑器起来之后才打进命令。文件读的是手写的假树（`MobileFakeClaudeTree`），
/// 终端接假传输，不建任何真实连接。
@MainActor
final class ClaudeHistoryTabTests: XCTestCase {

    private func host(_ name: String = "prod-web-01") -> ServerProfile {
        let host = ServerProfile()
        host.name = name
        return host
    }

    private func unreachableMac() -> RemoteMacClient {
        RemoteMacClient(macName: "老 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                        identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
    }

    // MARK: - 打开 / 关闭

    func testOpensInFocusedPaneAndListsCommandLineSessions() async throws {
        let ws = MobileWorkspace()
        let server = host()
        let (shell, _) = MobileFakeTerminal.tab(host: server, .idle)
        ws.open(.terminal(shell))
        let tree = MobileClaudeFixture.standard()

        let history = ws.openHistory(MobileFakeClaudeHistory.tab(host: server, tree: tree))

        XCTAssertEqual(ws.activeTab?.id, history.id, "开在聚焦格的前台")
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertEqual(ws.activeTab?.kind, .sftp)
        XCTAssertEqual(ws.activeTab?.title, "prod-web-01")
        let settled = await MobileFakeClaudeHistory.settle(history)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(history.connection.history)
        XCTAssertEqual(model.scope, .project(try XCTUnwrap(model.currentProject)), "先列终端当前目录所在的项目")
        XCTAssertEqual(model.visibleFiles.map { model.metadata[$0.path]?.title },
                       ["登录接口偶发 500", "给订单接口加分页", "排查 502"], "新的在前，桌面版的不列")
        XCTAssertEqual(model.hiddenCount, 1)
        XCTAssertEqual(model.resumeCommand(for: model.visibleFiles[0])?.command,
                       "cd -- '\(MobileClaudeFixture.directory)' && claude --resume \(MobileClaudeFixture.sessionID(1))")
    }

    func testSameHostReusesItsHistoryTab() {
        let ws = MobileWorkspace()
        let server = host()
        let first = ws.openHistory(MobileFakeClaudeHistory.tab(host: server, tree: MobileClaudeFixture.standard()))
        let files = FileTab(host: server)
        ws.open(.files(files))
        XCTAssertEqual(ws.activeTab?.id, files.id)

        let again = ws.openHistory(MobileFakeClaudeHistory.tab(host: server, tree: MobileClaudeFixture.standard()))

        XCTAssertTrue(again === first, "一台主机至多一个")
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertEqual(ws.activeTab?.id, first.id, "带到前台")
        // 打开主机（终端 / 文件）不会复用历史标签。
        XCTAssertEqual(ws.existing(host: server.persistentModelID, kind: .sftp)?.id, files.id)
        let other = ws.openHistory(MobileFakeClaudeHistory.tab(host: host("db-01"), tree: MobileClaudeFixture.standard()))
        XCTAssertFalse(other === first)
        XCTAssertEqual(ws.tabs.count, 3)
    }

    func testClosingReleasesTheFileChannel() async throws {
        let ws = MobileWorkspace()
        let tree = MobileClaudeFixture.standard()
        let history = ws.openHistory(MobileFakeClaudeHistory.tab(host: host(), tree: tree))
        let settled = await MobileFakeClaudeHistory.settle(history)
        XCTAssertTrue(settled)

        let removed = try XCTUnwrap(ws.close(history.id))
        removed.shutdown()
        removed.disposeSession()

        XCTAssertTrue(ws.isEmpty)
        try await Task.sleep(for: .milliseconds(100))   // 关通道是丢给任务做的
        let closed = await tree.didClose
        XCTAssertTrue(closed, "关标签放掉文件通道")
    }

    func testHistoryTabsAreNotArchived() async throws {
        let ws = MobileWorkspace()
        ws.openHistory(MobileFakeClaudeHistory.tab(host: host(), tree: MobileClaudeFixture.standard()))
        XCTAssertTrue(ws.terminalTabs.isEmpty, "标签归档只看终端标签，历史标签重启不恢复")
    }

    // MARK: - 子代理

    /// 列表 → 对话 → 子代理 → 子代理派的子代理，一层层进去、一层层返回；子代理的记录只读。
    func testSubagentsOpenAndCloseLevelByLevel() async throws {
        let ws = MobileWorkspace()
        let history = ws.openHistory(MobileFakeClaudeHistory.tab(host: host(), tree: MobileClaudeFixture.withSubagents()))
        let settled = await MobileFakeClaudeHistory.settle(history)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(history.connection.history)
        model.select(try XCTUnwrap(model.visibleFiles.first))
        let main = try XCTUnwrap(model.transcript)
        let linked = await MobileFakeTerminal.waitUntil { main.reachedStart && main.subagentLinks.count == 2 }
        XCTAssertTrue(linked)
        XCTAssertEqual(main.subagentLinks["toolu_s2"]?.agentType, "Explore")

        model.openSubagent(try XCTUnwrap(main.subagentLinks["toolu_s2"]))
        let second = try XCTUnwrap(model.displayedTranscript)
        XCTAssertEqual(second.subagent?.description, "排查订单列表的慢查询")
        let nested = await MobileFakeTerminal.waitUntil { second.reachedStart && second.subagentLinks["toolu_s3"] != nil }
        XCTAssertTrue(nested, "第二层的子代理靠 meta 对上")
        XCTAssertEqual(second.items.first?.kind, .userText("订单列表接口偶尔要 2 秒，找出慢在哪。"))

        model.openSubagent(try XCTUnwrap(second.subagentLinks["toolu_s3"]))
        XCTAssertEqual(model.subagentStack.count, 2)
        model.closeSubagent()
        XCTAssertTrue(model.displayedTranscript === second)
        model.closeSubagent()
        XCTAssertTrue(model.displayedTranscript === main)
        model.select(nil)
        XCTAssertNil(model.displayedTranscript, "窄屏回到列表")
    }

    // MARK: - 搜索

    /// 列表顶上的搜索：按回车才搜，结果按会话分组；点一条命中进到对话、停在那一条上，后面按需往后读；
    /// 窄屏返回回到结果。主机是会答搜索命令的假树（`ClaudeSearchHostEmulator`）。
    func testSearchOpensTheHitAndBackReturnsToTheResults() async throws {
        let ws = MobileWorkspace()
        let history = ws.openHistory(MobileFakeClaudeHistory.tab(host: host(), tree: MobileClaudeFixture.standard()))
        let settled = await MobileFakeClaudeHistory.settle(history)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(history.connection.history)
        defer { MobileProbeWindow.closeAll() }
        _ = MobileProbeWindow.make(size: CGSize(width: 390, height: 700),
                                   rootView: ClaudeHistoryBrowser(history: model, canResume: false, onResume: { _ in }))

        model.searchText = "连接池"
        XCTAssertNil(model.search, "打字时不搜")
        model.submitSearch()
        let finished = await MobileFakeTerminal.waitUntil { model.search?.phase == .finished }
        XCTAssertTrue(finished)
        let session = try XCTUnwrap(model.search?.sessions.first)
        XCTAssertEqual(model.search?.sessions.map(\.metadata.title), ["登录接口偶发 500"])
        XCTAssertEqual(session.hits.map(\.role), [.assistant], "思考里的那次不算")
        let hit = try XCTUnwrap(session.hits.first)
        XCTAssertEqual(hit.snippet.match, "连接池")

        model.openHit(hit, in: session)
        let transcript = try XCTUnwrap(model.transcript)
        let loaded = await MobileFakeTerminal.waitUntil { !transcript.items.isEmpty }
        XCTAssertTrue(loaded)
        XCTAssertEqual(transcript.items.last?.id, hit.itemID, "第一页到命中那一条为止")
        XCTAssertEqual(transcript.highlightedItemID, hit.itemID)
        XCTAssertFalse(transcript.reachedEnd)
        await transcript.loadLater()
        XCTAssertTrue(transcript.reachedEnd)
        XCTAssertEqual(transcript.items.last?.kind, .assistantText("改好了，`TestLoginTimeout` 现在能过。"))

        // 窄屏左上角返回：回到搜索结果，不是原来的列表。
        model.select(nil)
        XCTAssertEqual(model.search?.sessions.count, 1)
        model.clearSearch()
        XCTAssertNil(model.search)
        XCTAssertEqual(model.visibleFiles.count, 3, "清空后回到原来的列表")
    }

    /// 标成只许 SFTP 的主机：搜索给一句说明，不往主机上发命令；别的照常。
    func testSFTPOnlyHostExplainsWhySearchIsUnavailable() async throws {
        let server = host()
        server.sftpOnly = true
        let tree = MobileClaudeFixture.standard()
        let tab = ClaudeHistoryTab(host: server, connection: AgentHistoryConnection(
            preferredDirectory: MobileClaudeFixture.directory, allowsCommands: { !server.sftpOnly }) { _ in tree })
        let ws = MobileWorkspace()
        let history = ws.openHistory(tab)
        let settled = await MobileFakeClaudeHistory.settle(history)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(history.connection.history)
        model.searchText = "连接池"
        model.submitSearch()
        XCTAssertEqual(model.search?.phase, .failed(AgentHistoryText.searchCannotExecute))
        XCTAssertEqual(model.visibleFiles.count, 3)
    }

    // MARK: - 实时跟随

    /// 标签在前台时盯着文件末尾，接上新写的；标签退到后面（`isActive` 为 false）就停。
    func testFollowsOnlyWhileTheTabIsInFront() async throws {
        let ws = MobileWorkspace()
        let tree = MobileClaudeFixture.standard()
        let history = ws.openHistory(MobileFakeClaudeHistory.tab(host: host(), tree: tree))
        let settled = await MobileFakeClaudeHistory.settle(history)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(history.connection.history)
        let file = try XCTUnwrap(model.visibleFiles.first)
        model.select(file)
        let transcript = try XCTUnwrap(model.transcript)
        _ = await MobileFakeTerminal.waitUntil { transcript.reachedStart }
        let count = transcript.items.count

        // 挂上真的视图：前台 → 开始跟；退到后面、App 进后台 → 停。探针窗口不在 SwiftUI 的场景里，场景阶段由用例给。
        defer { MobileProbeWindow.closeAll() }
        func browser(active: Bool, phase: ScenePhase = .active) -> some View {
            ClaudeHistoryBrowser(history: model, canResume: false, isActive: active, onResume: { _ in })
                .environment(\.scenePhase, phase)
        }
        let (_, host) = MobileProbeWindow.make(size: CGSize(width: 390, height: 700), rootView: browser(active: true))
        let following = await MobileFakeTerminal.waitUntil { transcript.isFollowing }
        XCTAssertTrue(following)
        await tree.append(file.path, MobileClaudeFixture.assistant(MobileClaudeFixture.text("新写的一句"), uuid: "a-new") + "\n")
        // 跟随的循环自己会查到（每 2 秒一次）。
        let appended = await MobileFakeTerminal.waitUntil(timeout: .seconds(6)) { transcript.items.count == count + 1 }
        XCTAssertTrue(appended)
        XCTAssertEqual(transcript.items.last?.kind, .assistantText("新写的一句"))

        host.rootView = browser(active: false)
        let stopped = await MobileFakeTerminal.waitUntil { !transcript.isFollowing }
        XCTAssertTrue(stopped, "标签退到后面还在查")

        host.rootView = browser(active: true)
        let resumed = await MobileFakeTerminal.waitUntil { transcript.isFollowing }
        XCTAssertTrue(resumed, "回到前台没接着跟")
        host.rootView = browser(active: true, phase: .background)
        let backgrounded = await MobileFakeTerminal.waitUntil { !transcript.isFollowing }
        XCTAssertTrue(backgrounded, "App 进后台还在查")
    }

    // MARK: - 配对的 Mac

    /// 远控标签：Mac 没报 `files` 能力（老版本，或还没连上不知道）时长按菜单里不出「Claude 历史会话」——
    /// 老版本 Mac 收到不认识的消息会断开整条连接。
    func testRemoteTerminalOfMacWithoutFilesDoesNotOfferHistory() {
        let client = unreachableMac()
        XCTAssertFalse(client.supportsFiles)
        let sessionID = UUID()
        let remote = TermTab(host: client.tabHost(for: sessionID), remote: MRemoteSource(client: client, sessionID: sessionID))
        XCTAssertFalse(remote.offersClaudeHistory)
        XCTAssertNil(remote.claudeHistoryDirectory, "远控协议里没有 Mac 终端的当前目录")

        let (direct, _) = MobileFakeTerminal.tab(host: host(), .idle)
        XCTAssertTrue(direct.offersClaudeHistory)
        let (demo, _) = MobileFakeTerminal.tab(host: DemoHostProfile.shared, .idle)
        XCTAssertFalse(demo.offersClaudeHistory, "体验主机没有真文件系统")
    }

    /// 硬开（「+」菜单选了一台连不上的 Mac）：标签里说清楚连不上，不会发出文件请求。
    func testPairedMacThatCannotBeReachedFailsInsideTheTab() async throws {
        let ws = MobileWorkspace()
        let client = unreachableMac()
        let history = ws.openHistory(ClaudeHistoryTab(pairedMac: client))
        XCTAssertTrue(history.remoteMac === client)
        XCTAssertEqual(ws.remoteTabIDs(of: client), [history.id], "断开整台 Mac 时一起收掉")

        let failed = await MobileFakeTerminal.waitUntil(timeout: .seconds(30)) { history.connection.failureMessage != nil }
        XCTAssertTrue(failed)
        XCTAssertNil(history.connection.history)
        XCTAssertFalse(history.connection.failureMessage?.isEmpty ?? true)
        XCTAssertTrue(ws.openHistory(ClaudeHistoryTab(pairedMac: client)) === history, "一台 Mac 一个")
        XCTAssertEqual(ws.endTakeover(of: client), [history.id])
    }

    // MARK: - 继续这个会话

    /// 新开的终端标签：连上了、行编辑器还没起来时不打；zsh 打开括号粘贴之后打进命令和回车。
    func testResumeTypesCommandOnceLineEditorIsReady() async throws {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let server = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let ws = MobileWorkspace()
        ws.openHistory(MobileFakeClaudeHistory.tab(host: server, tree: MobileClaudeFixture.standard()))
        let command = "cd -- '/home/user/projects/shop-api' && claude --resume \(MobileClaudeFixture.sessionID(1))"
        // 连上之后 0.7 秒才出提示符（rc 跑得慢），提示符出来时打开括号粘贴。
        let (term, handles) = MobileFakeTerminal.tab(host: server, .transcript("Last login: today\r\n% \u{1B}[?2004h"))
        term.controller.start(profile: server, container: container, relay: HostKeyChallengeRelay())

        ws.open(.terminal(term), typing: command)

        XCTAssertEqual(ws.activeTab?.id, term.id, "开到前台")
        let settled = await MobileFakeTerminal.waitUntilConnected(term.controller)
        XCTAssertTrue(settled)
        try await Task.sleep(for: .milliseconds(300))
        let early = await handles.latest?.writtenText ?? ""
        XCTAssertFalse(early.contains("claude --resume"), "行编辑器还没起来，不打")
        let deadline = ContinuousClock.now + .seconds(5)
        var written = ""
        while ContinuousClock.now < deadline {
            written = await handles.latest?.writtenText ?? ""
            if written.contains(command) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(written.hasSuffix(command + "\r"), "打进命令和回车：\(written.debugDescription)")
        XCTAssertEqual(written.components(separatedBy: "claude --resume").count, 2, "只打一次")
        term.controller.close()
    }
}
