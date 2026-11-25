import Network
import XCTest
@testable import uTermMobile

/// 接管 Mac 时把 Mac 的 Code 标签页镜像成手机上的 Code 标签页（63 号消息）：里面跑着的会话放进它，不再各开终端标签页；
/// 会话进出、结束、对上的记录跟着 Mac；接管时点的是它就切过去选中；关手机上的只断开、不再自动开；「结束会话」请 Mac 结束；
/// Mac 上挪出来的会话成了普通终端标签页；老 Mac 照旧散标签。
/// 不连真 Mac：Mac 发来的列表与 Code 标签页直接交给 `RemoteMacClient`（`receiveSessions` / `receiveCodeTabs`）。
@MainActor
final class CodeTabMirrorTests: XCTestCase {

    private func macClient() -> RemoteMacClient {
        RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                        identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
    }

    private func session(_ id: UUID, order: Int) -> RemoteSessionInfo {
        RemoteSessionInfo(id: id, serverID: RemoteConstants.localShellServerID, serverName: "本机", title: "zsh",
                          windowKind: "terminal", order: order)
    }

    private func run(_ id: UUID, tool: String = AgentHistoryTool.claude.rawValue, title: String? = nil,
                     path: String? = nil, sessionID: String? = nil, ended: Date? = nil) -> RemoteCodeTabInfo.Run {
        RemoteCodeTabInfo.Run(session: id, tool: tool, directory: "/Users/me/app",
                              startedAt: Date(timeIntervalSince1970: 1_800_000_000), sessionID: sessionID, path: path,
                              title: title, endedAt: ended)
    }

    private func codeTab(_ id: UUID = UUID(), runs: [RemoteCodeTabInfo.Run], slot: Int? = nil,
                         selected: UUID? = nil) -> RemoteCodeTabInfo {
        RemoteCodeTabInfo(id: id, serverID: RemoteConstants.localShellServerID, serverName: "本机", directory: "/Users/me/app",
                          slot: slot, runs: runs, selectedRun: selected, selectedRecord: nil)
    }

    /// Mac 推来一轮：先 Code 标签页、再会话列表（同真 Mac 的先后）。
    private func mac(_ client: RemoteMacClient, sessions: [UUID], codeTabs: [RemoteCodeTabInfo]?) {
        if let codeTabs { client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: codeTabs)) }
        client.receiveSessions(sessions.enumerated().map { session($1, order: $0) })
    }

    private func follow(_ ws: MobileWorkspace, _ client: RemoteMacClient) -> RemoteTabChanges {
        ws.follow(client, sessionIDs: client.listedSessionIDs, order: client.sessions.macTabOrder)
    }

    private func code(_ ws: MobileWorkspace, _ client: RemoteMacClient) throws -> ClaudeHistoryTab {
        try XCTUnwrap(ws.existingHistory(remoteMac: client))
    }

    /// 手机上这台 Mac 的远控终端标签页接着的会话。
    private func loose(_ ws: MobileWorkspace) -> [UUID] {
        ws.terminalTabs.compactMap { $0.remote?.sessionID }
    }

    // MARK: - 纯逻辑

    func testPlanAddsOnlyListedRunsRemovesGoneAndKeepsKnownRecords() {
        let (a, b, c, gone) = (UUID(), UUID(), UUID(), UUID())
        let info = codeTab(runs: [run(a, title: "新名字", ended: Date(timeIntervalSince1970: 5)),
                                  run(b), run(c), run(UUID(), tool: "future-tool")])
        let plan = RemoteCodeRunMirror.plan(
            mirrored: [.init(session: a, path: "/p/a.jsonl", sessionID: "a", title: "旧名字", endedAt: nil),
                       .init(session: gone, path: nil, sessionID: nil, title: nil, endedAt: nil)],
            info: info, listed: [a, b])
        XCTAssertEqual(plan.added.map(\.session), [b], "c 还没列出来：等列表到了再加；认不出的工具不镜像")
        XCTAssertEqual(plan.removed, [gone])
        XCTAssertEqual(plan.updated.map(\.session), [a])
        XCTAssertEqual(plan.updated.first?.path, "/p/a.jsonl", "Mac 刚重启报 nil 时不丢已知的记录")
        XCTAssertEqual(plan.updated.first?.title, "新名字")
        XCTAssertNotNil(plan.updated.first?.endedAt)

        let empty = RemoteCodeRunMirror.plan(mirrored: [.init(session: a, path: nil, sessionID: nil, title: nil, endedAt: nil)],
                                             info: nil, listed: [a])
        XCTAssertEqual(empty.removed, [a], "Mac 上没了：全部拿掉")
    }

    // MARK: - 接管

    func testTakeoverMirrorsCodeTabInsteadOfOpeningTerminalTabsForItsRuns() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let (shell, inCode) = (UUID(), UUID())
        mac(client, sessions: [shell, inCode], codeTabs: [codeTab(runs: [run(inCode, title: "修登录页")], slot: 1)])
        XCTAssertEqual(client.codeRunSessionIDs, [inCode])

        let changes = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [shell, inCode], focus: shell,
                                                  order: client.sessions.macTabOrder))
        XCTAssertEqual(loose(ws), [shell], "Code 标签页里的会话不另开终端标签页")
        let code = try code(ws, client)
        XCTAssertTrue(code.opensForMirror)
        XCTAssertEqual(code.runs.runs.map(\.id), [inCode])
        XCTAssertEqual(code.runs.runs.first?.isMirrored, true)
        XCTAssertEqual(code.title(of: try XCTUnwrap(code.runs.runs.first)), "修登录页", "标题用 Mac 侧栏上的")
        XCTAssertEqual(code.runs.runs.first?.terminal.remote?.sessionID, inCode, "接着 Mac 上那个会话")
        XCTAssertEqual(Set(changes.opened.compactMap { $0.remote?.sessionID }), [shell, inCode], "两个终端都交给工作区屏去连")
        XCTAssertEqual(ws.activeTab?.terminal?.remote?.sessionID, shell, "Code 标签页开在后台")
        XCTAssertEqual(ws.panes[0].tabIDs.count, 2)
        XCTAssertEqual(ws.panes[0].tabIDs.last, code.id, "排在 Mac 上它的位置（shell 之后）")
        XCTAssertNil(ws.existing(remote: MRemoteSource(client: client, sessionID: inCode)))
        XCTAssertEqual(ws.remoteTerminal(MRemoteSource(client: client, sessionID: inCode))?.tabID, code.id)

        // 同一份再推一次：什么都不动。
        let again = follow(ws, client)
        XCTAssertTrue(again.opened.isEmpty)
        XCTAssertTrue(again.removed.isEmpty)
    }

    /// 接管时点的就是 Code 标签页里的会话（Mac 面板上点那一行）：切到 Code 标签页、详情换成它，不抢别的。
    func testTakeoverFocusedOnARunShowsTheCodeTabWithThatRun() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let (shell, a, b) = (UUID(), UUID(), UUID())
        mac(client, sessions: [shell, a, b], codeTabs: [codeTab(runs: [run(a), run(b)], slot: 0, selected: a)])
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [shell, a, b], focus: b,
                                        order: client.sessions.macTabOrder))
        let code = try code(ws, client)
        XCTAssertEqual(ws.activeTab?.id, code.id)
        XCTAssertEqual(code.runs.focusedID, b, "点的是 b：不照 Mac 那边看着的 a")
        XCTAssertEqual(code.runs.focused?.showsTerminal, true)
        XCTAssertEqual(ws.panes[0].tabIDs.first, code.id, "slot 0：排在 shell 前面")
    }

    /// 第一次开出来照 Mac 那边看着的那个选；之后的选中只在手机上。
    func testFirstMaterializationAdoptsTheMacsSelection() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let (shell, a, b) = (UUID(), UUID(), UUID())
        mac(client, sessions: [shell, a, b], codeTabs: [codeTab(runs: [run(a), run(b)], selected: b)])
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [shell, a, b], focus: shell))
        let code = try code(ws, client)
        XCTAssertEqual(code.runs.focusedID, b)

        code.runs.focus(a)
        mac(client, sessions: [shell, a, b], codeTabs: [codeTab(code.mirroredMacTabID!, runs: [run(a), run(b)], selected: b)])
        _ = follow(ws, client)
        XCTAssertEqual(code.runs.focusedID, a, "手机上换过的不被 Mac 的选中拉回去")
    }

    // MARK: - 跟着 Mac

    func testRunsFollowTheMacInAndOutAndEnd() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let (shell, a, b) = (UUID(), UUID(), UUID())
        let macTab = UUID()
        mac(client, sessions: [shell, a], codeTabs: [codeTab(macTab, runs: [run(a)])])
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [shell, a], focus: shell))
        let code = try code(ws, client)

        // Mac 上新起一个：Code 标签页先报（列表还没列它）→ 还接不上，不加；列表到了再加。
        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: [codeTab(macTab, runs: [run(a), run(b)])]))
        XCTAssertTrue(follow(ws, client).opened.isEmpty)
        XCTAssertEqual(code.runs.runs.map(\.id), [a])
        client.receiveSessions([session(shell, order: 0), session(a, order: 1), session(b, order: 2)])
        let added = follow(ws, client)
        XCTAssertEqual(added.opened.compactMap { $0.remote?.sessionID }, [b])
        XCTAssertEqual(code.runs.runs.map(\.id), [a, b])
        XCTAssertEqual(loose(ws), [shell], "新会话不另开终端标签页")

        // a 在 Mac 上结束（留着画面）、对上了记录：照 Mac 的改。
        let endedAt = Date(timeIntervalSince1970: 1_800_000_600)
        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: [codeTab(macTab, runs: [
            run(a, title: "修登录页", path: "/p/a.jsonl", sessionID: "sa", ended: endedAt), run(b)])]))
        _ = follow(ws, client)
        let mirroredA = try XCTUnwrap(code.runs.run(id: a))
        XCTAssertEqual(mirroredA.endedAt, endedAt)
        XCTAssertFalse(mirroredA.isRunning)
        XCTAssertEqual(mirroredA.sessionPath, "/p/a.jsonl")
        XCTAssertEqual(mirroredA.sessionID, "sa")
        XCTAssertEqual(code.title(of: mirroredA), "修登录页")

        // b 在 Mac 上「移到新标签页」：不再归 Code 标签页，手机上拿掉镜像、开成普通的终端标签页。
        let bTerm = try XCTUnwrap(code.mirroredTerminal(session: b))
        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: [codeTab(macTab, runs: [run(a)])]))
        let moved = follow(ws, client)
        XCTAssertNil(code.runs.run(id: b))
        XCTAssertEqual(bTerm.controller.state, .disconnected, "镜像的那一路断开了")
        XCTAssertEqual(moved.opened.compactMap { $0.remote?.sessionID }, [b])
        XCTAssertEqual(Set(loose(ws)), [shell, b])

        // a 跑完收回记录（Mac 上从 Code 标签页里拿掉、会话也没了）：手机上跟着拿掉，不开成终端标签页。
        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: [codeTab(macTab, runs: [])]))
        client.receiveSessions([session(shell, order: 0), session(b, order: 1)])
        let finished = follow(ws, client)
        XCTAssertTrue(finished.opened.isEmpty)
        XCTAssertTrue(code.runs.runs.isEmpty)
        XCTAssertNotNil(ws.existingHistory(remoteMac: client), "Code 标签页还在 Mac 上：留着")

        // Mac 上关掉了 Code 标签页：镜像开出来的跟着关。
        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: []))
        let closed = follow(ws, client)
        XCTAssertNil(ws.existingHistory(remoteMac: client))
        XCTAssertEqual(closed.removed.compactMap(\.history).map(\.id), [code.id])
    }

    /// 用户自己开过这台 Mac 的 Code 标签页：接管时接上它（不再开一个）；Mac 上那个没了也不关它，只停镜像。
    func testUserOpenedCodeTabIsReusedAndKeptWhenTheMacsGoes() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let mine = ws.openHistory(ClaudeHistoryTab(pairedMac: client))
        let (shell, a) = (UUID(), UUID())
        mac(client, sessions: [shell, a], codeTabs: [codeTab(runs: [run(a)])])
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [shell, a], focus: shell))
        XCTAssertTrue(try code(ws, client) === mine)
        XCTAssertEqual(ws.tabs.compactMap(\.history).count, 1)
        XCTAssertFalse(mine.opensForMirror)
        XCTAssertEqual(mine.runs.runs.map(\.id), [a])

        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: []))
        _ = follow(ws, client)
        XCTAssertTrue(ws.existingHistory(remoteMac: client) === mine, "用户自己开的留着")
        XCTAssertTrue(mine.runs.runs.isEmpty)
        XCTAssertNil(mine.mirroredMacTabID)
    }

    // MARK: - 操作

    /// 「结束会话」请 Mac 结束（消息 8），手机上等 Mac 推来新的 Code 标签页再拿掉；关掉手机上的 Code 标签页只断开镜像，
    /// 不发 8，之后也不再自动开出来、里面的会话也不另开终端标签页，直到重新接管。
    func testEndingAsksTheMacButClosingTheTabOnlyDetaches() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let (shell, a, b) = (UUID(), UUID(), UUID())
        let macTab = UUID()
        mac(client, sessions: [shell, a, b], codeTabs: [codeTab(macTab, runs: [run(a), run(b)])])
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [shell, a, b], focus: shell))
        let code = try code(ws, client)
        var ended: [UUID] = []
        code.endOnMac = { ended.append($0) }

        code.endRun(a)
        XCTAssertEqual(ended, [a])
        XCTAssertNotNil(code.runs.run(id: a), "等 Mac 推来新的再拿掉")
        XCTAssertNil(code.moveRunToTab(b, in: ws), "镜像的会话挪不走")

        // 手机上关掉（同工作区屏的 closeTab）。
        let terms = code.runTerminals
        let removed = try XCTUnwrap(ws.close(code.id))
        removed.shutdown()
        ws.noteClosedByUser(removed)
        ws.stopFollowingIfLastTab(removed)
        XCTAssertEqual(ended, [a], "关标签页不结束 Mac 上的会话")
        XCTAssertTrue(terms.allSatisfy { $0.controller.state == .disconnected })
        XCTAssertEqual(ws.followedClients.count, 1, "还有 shell 标签：照旧跟进")

        mac(client, sessions: [shell, a, b], codeTabs: [codeTab(macTab, runs: [run(a), run(b)])])
        let after = follow(ws, client)
        XCTAssertNil(ws.existingHistory(remoteMac: client), "关过的不再自动开")
        XCTAssertTrue(after.opened.isEmpty, "里面的会话也不另开终端标签页")
        XCTAssertEqual(loose(ws), [shell])

        // 重新接管：又开出来。
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [shell, a, b], focus: shell))
        XCTAssertEqual(try self.code(ws, client).runs.runs.map(\.id), [a, b])
    }

    // MARK: - 老 Mac

    /// 老 Mac 不发 Code 标签页：每个会话照旧开成终端标签页，没有 Code 标签页。
    func testOldMacKeepsEveryRunAsATerminalTab() {
        let ws = MobileWorkspace()
        let client = macClient()
        let (shell, a) = (UUID(), UUID())
        mac(client, sessions: [shell, a], codeTabs: nil)
        XCTAssertNil(client.codeTabs)
        XCTAssertTrue(client.codeRunSessionIDs.isEmpty)
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [shell, a], focus: shell))
        _ = follow(ws, client)
        XCTAssertEqual(loose(ws), [shell, a])
        XCTAssertNil(ws.existingHistory(remoteMac: client))
    }
}
