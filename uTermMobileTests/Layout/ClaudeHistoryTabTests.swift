import Network
import SwiftData
import SwiftUI
import XCTest
@testable import uTermMobile

/// 「历史会话」标签：放进工作区、一台主机一个、关掉放掉通道、远控 Mac 没有 `files` 能力时不给入口，
/// 几种工具混排时的分组、筛选、定位接到界面上，「继续这个会话」「＋新会话」开新终端标签页、行编辑器起来之后才打进命令。
/// 文件读的是手写的假树（`MobileFakeClaudeTree`）或手写的假数据源（`MobileFakeAgentSource`），终端接假传输，
/// 不建任何真实连接。
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
        XCTAssertEqual(model.scope, .all, "一直列全部项目（按项目分组，定位到终端目录那一组）")
        XCTAssertEqual(history.pendingReveal?.directory, MobileClaudeFixture.directory)
        XCTAssertEqual(model.configuredTools, AgentHistoryTool.allCases, "几种工具都读")
        XCTAssertEqual(model.availableTools, [.claude], "树里只有 Claude Code 的记录：别的工具目录不存在，列出空的")
        XCTAssertFalse(model.isMultiTool)
        XCTAssertEqual(model.toolFailures, [:], "没有记录目录不算读不出来")
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

    /// Code 标签页不当终端标签页记；只有已保存的直连主机的记进归档（`CodeTabArchiveTests`），配对的 Mac 的不记。
    func testHistoryTabsAreArchivedOnlyForSavedDirectHosts() async throws {
        let ws = MobileWorkspace()
        let unsaved = ws.openHistory(MobileFakeClaudeHistory.tab(host: host(), tree: MobileClaudeFixture.standard()))
        let client = unreachableMac()
        let mac = ws.openHistory(ClaudeHistoryTab(pairedMac: client))
        XCTAssertTrue(ws.terminalTabs.isEmpty)
        let archive = ws.terminalTabArchive(showsWorkspace: true)
        XCTAssertTrue(archive.tabs.isEmpty, "Code 标签页不当终端标签页记")
        XCTAssertNil(archive.codeTabs, "没入库的主机、配对的 Mac 都不记（归档只管已保存的直连主机）")
        XCTAssertFalse(archive.showsWorkspace)
        unsaved.close()
        mac.close()
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

    // MARK: - 几种工具

    /// App 里建的两种标签：几种工具都读、一直列全部项目；直连主机记下终端目录并要求定位，配对的 Mac 没有目录、不定位。
    func testTabsReadEveryToolAndOnlyDirectHostsReveal() throws {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let server = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let direct = ClaudeHistoryTab(server: server, directory: MobileAgentHistoryFixture.shop, container: container)
        XCTAssertEqual(direct.connection.tools, AgentHistoryTool.allCases)
        XCTAssertEqual(direct.directory, MobileAgentHistoryFixture.shop, "「＋」新会话开在终端目录")
        XCTAssertEqual(direct.pendingReveal?.directory, MobileAgentHistoryFixture.shop)

        let picked = ClaudeHistoryTab(server: server, directory: nil, container: container)
        XCTAssertNil(picked.directory, "「+」菜单选主机开的：没有终端，不知道目录")
        XCTAssertNil(picked.pendingReveal)

        let mac = ClaudeHistoryTab(pairedMac: unreachableMac())
        XCTAssertEqual(mac.connection.tools, AgentHistoryTool.allCases, "配对的 Mac 同样几种工具")
        XCTAssertNil(mac.pendingReveal)
    }

    /// 几种工具混排：同一个目录下几种工具的会话并成一组；列表挂上之后定位到终端目录那一组（折着的展开），
    /// 已经开着的标签从终端再来一次也会再定位。
    func testMixedToolsGroupByProjectAndRevealTheTerminalDirectory() async throws {
        let (defaults, suite) = privateDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let ws = MobileWorkspace()
        let tab = ws.openHistory(MobileAgentHistoryFixture.tab(host: host(), source: MobileAgentHistoryFixture.source()))
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(tab.connection.history)
        XCTAssertTrue(model.isMultiTool)
        XCTAssertEqual(model.availableTools, [.claude, .codex, .antigravity])
        let groups = AgentHistoryListing.groups(model.visibleFiles, by: .project, metadata: model.metadata)
        let shopID = "project:" + MobileAgentHistoryFixture.shop
        let shop = try XCTUnwrap(groups.first { $0.id == shopID })
        XCTAssertEqual(Set(shop.files.map(\.tool)), [.claude, .codex, .antigravity], "同一个目录下几种工具并成一组")
        XCTAssertEqual(groups.count, 3)

        model.collapsedGroups = [shopID]
        defer { MobileProbeWindow.closeAll() }
        _ = MobileProbeWindow.make(size: CGSize(width: 390, height: 700), rootView:
            ClaudeHistorySessionBody(tab: tab) { _, _ in }.defaultAppStorage(defaults))
        let revealed = await MobileFakeTerminal.waitUntil { tab.pendingReveal == nil }
        XCTAssertTrue(revealed, "列表列出那一组之后清掉定位请求")
        XCTAssertFalse(model.collapsedGroups.contains(shopID), "折着的那一组展开")

        model.collapsedGroups = [shopID]
        tab.reveal(directory: MobileAgentHistoryFixture.shop + "/internal/auth")
        let again = await MobileFakeTerminal.waitUntil { tab.pendingReveal == nil && !model.collapsedGroups.contains(shopID) }
        XCTAssertTrue(again, "终端在项目的子目录里：定位到项目那一组")
    }

    /// 「分组与显示」菜单写的是和 Mac 同一对偏好键：列表按它筛（只放枚举的原始值），改了就地重筛；
    /// 只有一种工具时「工具」分组退回默认、菜单里也不出。
    func testListPreferencesDriveTheListAndFallBackWithOneTool() async throws {
        let (defaults, suite) = privateDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set("codex,antigravity", forKey: DefaultsKey.agentHistoryShownTools)
        let ws = MobileWorkspace()
        let tab = ws.openHistory(MobileAgentHistoryFixture.tab(host: host(), source: MobileAgentHistoryFixture.source()))
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(tab.connection.history)
        defer { MobileProbeWindow.closeAll() }
        _ = MobileProbeWindow.make(size: CGSize(width: 390, height: 700), rootView:
            ClaudeHistorySessionBody(tab: tab) { _, _ in }.defaultAppStorage(defaults))

        let filtered = await MobileFakeTerminal.waitUntil {
            model.shownTools == [.codex, .antigravity] && !model.hasMore && !model.visibleFiles.isEmpty
        }
        XCTAssertTrue(filtered, "挂上列表就按存的「显示」筛")
        XCTAssertEqual(Set(model.visibleFiles.map(\.tool)), [.codex, .antigravity])

        defaults.set("", forKey: DefaultsKey.agentHistoryShownTools)
        let all = await MobileFakeTerminal.waitUntil { model.shownTools == nil && model.visibleFiles.count == 7 }
        XCTAssertTrue(all, "「恢复默认」清空之后回到全部")

        XCTAssertEqual(AgentHistoryListPreferences.effectiveGrouping("tool", isMultiTool: true), .tool)
        XCTAssertEqual(AgentHistoryListPreferences.effectiveGrouping("tool", isMultiTool: false), .project)
        XCTAssertEqual(AgentHistoryListPreferences.effectiveGrouping("date", isMultiTool: false), .date)
        XCTAssertEqual(AgentHistoryListPreferences.effectiveGrouping(nil, isMultiTool: true), .project)
        XCTAssertFalse(AgentHistoryListPreferences.groupingChoices(isMultiTool: false).contains(.tool))
        XCTAssertEqual(AgentHistoryListPreferences.groupingChoices(isMultiTool: true), AgentHistoryGrouping.allCases)
    }

    /// 搜索：几种工具一起搜；有一种的记录没法在主机上搜时，结果照出、`searchExcludedTools` 点名它（结果上方那句说明）。
    func testSearchAcrossToolsNamesTheUnsearchableOne() async throws {
        let ws = MobileWorkspace()
        let tab = ws.openHistory(MobileAgentHistoryFixture.tab(host: host(), source: MobileAgentHistoryFixture.source()))
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(tab.connection.history)
        XCTAssertEqual(model.searchExcludedTools, [.antigravity])
        model.searchText = "订单"
        model.submitSearch()
        let finished = await MobileFakeTerminal.waitUntil { model.search?.phase == .finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(model.search?.sessions.map(\.metadata.title), ["登录接口偶发 500", "订单服务测试与慢查询", "给订单接口加分页"],
                       "按会话的新旧排，Claude Code 与 Codex 的混在一起")
        // 不拿中文字面量比文案（换了界面语言就红）：比结构化的字段，文案只核点到了那种工具。
        XCTAssertEqual(model.searchExcludedTools, [.antigravity])
        let note = AgentHistoryText.searchUnsupported(model.searchExcludedTools)
        XCTAssertTrue(note.contains(AgentHistoryTool.antigravity.displayName), note)
        XCTAssertFalse(note.contains(AgentHistoryTool.claude.displayName), note)
    }

    /// 「继续这个会话」按工具出命令、「＋新会话」先选工具，都在这台主机上开一个新的终端标签页跑；
    /// 「+」菜单开的标签不知道目录，「＋」里只有说明；只许 SFTP 的主机都开不了。
    func testResumeAndNewSessionOpenANewTerminalTab() async throws {
        let server = host()
        let ws = MobileWorkspace()
        let tab = ws.openHistory(MobileAgentHistoryFixture.tab(host: server, source: MobileAgentHistoryFixture.source()))
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(tab.connection.history)
        let codexFile = try XCTUnwrap(model.visibleFiles.first { $0.tool == .codex })
        let plan = try XCTUnwrap(model.resumeCommand(for: codexFile))
        XCTAssertEqual(plan.command, "cd -- '\(MobileAgentHistoryFixture.shop)' && codex resume x-tests", "Codex 的会话用 Codex 的命令")

        let store = MobileStore()
        try await tab.runInNewTerminal(plan.command, directory: plan.directory, store: store)
        XCTAssertEqual(store.openTarget?.kind, .terminal)
        XCTAssertEqual(store.openTarget?.command, plan.command)
        XCTAssertEqual(store.connecting?.allowDuplicate, true, "总是新开一个终端标签页")

        XCTAssertEqual(model.newSessionTools(directory: tab.directory), [.claude, .codex, .antigravity], "不止一种：先选工具")
        let directory = try XCTUnwrap(tab.directory)
        let newCommand = try XCTUnwrap(model.newSessionCommand(tool: .antigravity, directory: directory))
        let fresh = MobileStore()
        try await tab.runInNewTerminal(newCommand, directory: directory, store: fresh)
        XCTAssertEqual(fresh.openTarget?.command, "cd -- '\(MobileAgentHistoryFixture.shop)' && antigravity")

        let picked = ws.openHistory(MobileAgentHistoryFixture.tab(host: host("db-01"), source: MobileAgentHistoryFixture.source(),
                                                                  directory: nil))
        XCTAssertNil(picked.directory)
        XCTAssertEqual(model.newSessionTools(directory: picked.directory), [], "不知道目录：「＋」里只有说明")

        let sftp = host("files-only")
        sftp.sftpOnly = true
        let blocked = MobileAgentHistoryFixture.tab(host: sftp, source: MobileAgentHistoryFixture.source())
        XCTAssertFalse(blocked.canResume, "只许 SFTP：不出「＋」，「继续这个会话」灰掉")
        let untouched = MobileStore()
        try await blocked.runInNewTerminal(plan.command, directory: plan.directory, store: untouched)
        XCTAssertNil(untouched.openTarget)
    }

    /// 用例自己的设置存储：`.standard` 是宿主 App 的真实设置，不能写。
    private func privateDefaults() -> (UserDefaults, String) {
        let suite = "ClaudeHistoryTabTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
