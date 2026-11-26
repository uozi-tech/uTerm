import XCTest
@testable import uTerm

/// Mac 控制 Mac：远程 Mac 窗口把那台 Mac 的 Code 标签页（63 号消息）开成这扇窗口里的 Code 标签页，里面的会话不再各开终端标签；
/// 会话进出、标题、结束跟着那台 Mac；关掉只停镜像、重新接管之前不再开；「移到新标签页」的会话成了终端标签、放到前台；
/// 排在那台 Mac 上它的位置，推回 Mac 的顺序里没有它；老 Mac（不报 Code 标签页、不认文件请求）照旧散标签。
/// 不连真 Mac：列表与 Code 标签页直接交给 `RemoteMacClient`（`receiveSessions` / `receiveCodeTabs`），握手能力与 64 / 8 号
/// 消息由 `RemoteMacCodeTabHooks` 换成记下来的。
@MainActor
final class RemoteMacCodeTabWindowTests: XCTestCase {
    private var started: [UUID] = []
    private var performed: [RemoteCodeTabAction] = []
    private var ended: [UUID] = []
    private var reply: UUID?
    private var supportsActions = true

    private func macClient() -> RemoteMacClient {
        RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                        identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
    }

    private func makeModel(_ client: RemoteMacClient, supported: Bool = true) -> RemoteMacWindowModel {
        let hooks = RemoteMacCodeTabHooks(
            isSupported: { _ in supported },
            supportsActions: { [unowned self] _ in supportsActions },
            perform: { [unowned self] _, action in
                performed.append(action)
                guard let reply else { throw RemoteAttachError.rejected("做不成") }
                return reply
            },
            end: { [unowned self] _, session in ended.append(session) })
        let model = RemoteMacWindowModel(client: client, codeHooks: hooks) { [unowned self] in started.append($0.id) }
        addTeardownBlock { @MainActor in model.disposeAll() }
        return model
    }

    private func session(_ id: UUID, order: Int) -> RemoteSessionInfo {
        RemoteSessionInfo(id: id, serverID: RemoteConstants.localShellServerID, serverName: "本机", title: "zsh",
                          windowKind: "terminal", order: order)
    }

    private func run(_ id: UUID, title: String? = nil, ended: Date? = nil) -> RemoteCodeTabInfo.Run {
        RemoteCodeTabInfo.Run(session: id, tool: AgentHistoryTool.claude.rawValue, directory: "/Users/me/app",
                              startedAt: Date(timeIntervalSince1970: 1_800_000_000), sessionID: nil, path: nil,
                              title: title, endedAt: ended)
    }

    private func codeTab(_ id: UUID, runs: [RemoteCodeTabInfo.Run], slot: Int?, selected: UUID? = nil) -> RemoteCodeTabInfo {
        RemoteCodeTabInfo(id: id, serverID: RemoteConstants.localShellServerID, serverName: "本机", directory: "/Users/me/app",
                          slot: slot, runs: runs, selectedRun: selected, selectedRecord: nil)
    }

    /// 那台 Mac 推来一轮：先 Code 标签页、再会话列表（同真 Mac 的先后）。
    private func mac(_ client: RemoteMacClient, sessions: [UUID], codeTabs: [RemoteCodeTabInfo]?) {
        if let codeTabs { client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: codeTabs)) }
        client.receiveSessions(sessions.enumerated().map { session($1, order: $0) })
    }

    private func follow(_ model: RemoteMacWindowModel, _ client: RemoteMacClient) {
        model.follow(client.listedSessionIDs, order: client.sessions.macTabOrder)
    }

    /// 终端标签接着的会话（不含 Code 标签页）。
    private func loose(_ model: RemoteMacWindowModel) -> [UUID] {
        model.panes.filter { $0.codeTab == nil }.map(\.id)
    }

    private func code(_ model: RemoteMacWindowModel) throws -> CodeTabModel {
        try XCTUnwrap(model.codePane?.codeTab)
    }

    // MARK: - 接管

    func testTakeoverMirrorsTheCodeTabInsteadOfOpeningTerminalTabsForItsRuns() throws {
        let client = macClient()
        let (shell, inCode, macTab) = (UUID(), UUID(), UUID())
        mac(client, sessions: [shell, inCode], codeTabs: [codeTab(macTab, runs: [run(inCode, title: "修登录页")], slot: 1)])
        let model = makeModel(client)
        model.takeOver()

        XCTAssertEqual(loose(model), [shell], "Code 标签页里的会话不另开终端标签")
        let code = try code(model)
        XCTAssertEqual(code.remote?.macTabID, macTab)
        XCTAssertEqual(code.remote?.opensForMirror, true)
        XCTAssertEqual(code.runs.map(\.id), [inCode])
        XCTAssertEqual(code.runs.first?.isMirrored, true)
        XCTAssertEqual(code.title(of: try XCTUnwrap(code.runs.first)), "修登录页", "标题用那台 Mac 侧栏上的")
        XCTAssertEqual(Set(started), [shell, inCode], "两个终端都开始接入，各接一次")
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(model.active?.id, shell, "Code 标签页开在后台")
        XCTAssertEqual(model.groups.allTabs.map(\.id), [shell, try XCTUnwrap(model.codePane?.id)], "排在 Mac 上它的位置（shell 之后）")
        XCTAssertEqual(model.layout, [[shell, macTab]], "顺序里 Code 标签页是 Mac 上它的 id")

        // 同一份再推一次：什么都不动。
        started = []
        follow(model, client)
        XCTAssertTrue(started.isEmpty)
        XCTAssertEqual(code.runs.map(\.id), [inCode])
    }

    func testCodeTabTakesItsSlotBeforeTheSessionsAfterIt() throws {
        let client = macClient()
        let (a, b, macTab) = (UUID(), UUID(), UUID())
        mac(client, sessions: [a, b], codeTabs: [codeTab(macTab, runs: [], slot: 0)])
        let model = makeModel(client)
        model.takeOver()
        let codeID = try XCTUnwrap(model.codePane?.id)
        XCTAssertEqual(model.groups.allTabs.map(\.id), [codeID, a, b], "slot 0：排在最前")
        XCTAssertEqual(model.active?.id, a, "前台还是第一个终端")

        // Mac 上把 Code 标签页挪到 a 之后。
        mac(client, sessions: [a, b], codeTabs: [codeTab(macTab, runs: [], slot: 1)])
        follow(model, client)
        XCTAssertEqual(model.groups.allTabs.map(\.id), [a, codeID, b])
    }

    func testFollowAddsUpdatesAndRemovesRuns() throws {
        let client = macClient()
        let (shell, a, b, macTab) = (UUID(), UUID(), UUID(), UUID())
        mac(client, sessions: [shell, a], codeTabs: [codeTab(macTab, runs: [run(a)], slot: 1)])
        let model = makeModel(client)
        model.takeOver()
        let code = try code(model)

        // 新会话：Code 标签页里先报了、列表还没到——等列表到了再加，不开终端标签。
        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: [codeTab(macTab, runs: [run(a), run(b)], slot: 1)]))
        follow(model, client)
        XCTAssertEqual(code.runs.map(\.id), [a])
        mac(client, sessions: [shell, a, b], codeTabs: nil)
        follow(model, client)
        XCTAssertEqual(code.runs.map(\.id), [a, b])
        XCTAssertEqual(loose(model), [shell])

        // 改名、结束：照 Mac 改。
        let endedAt = Date(timeIntervalSince1970: 1_800_000_500)
        mac(client, sessions: [shell, a, b],
            codeTabs: [codeTab(macTab, runs: [run(a, title: "新名字", ended: endedAt), run(b)], slot: 1)])
        follow(model, client)
        let first = try XCTUnwrap(code.runs.first { $0.id == a })
        XCTAssertEqual(code.title(of: first), "新名字")
        XCTAssertEqual(first.endedAt, endedAt)
        XCTAssertEqual(code.runningCount, 1)

        // Mac 上关掉 b：拿掉，不开终端标签。
        mac(client, sessions: [shell, a], codeTabs: [codeTab(macTab, runs: [run(a, ended: endedAt)], slot: 1)])
        follow(model, client)
        XCTAssertEqual(code.runs.map(\.id), [a])
        XCTAssertEqual(loose(model), [shell])

        // Mac 上的 Code 标签页没了：镜像才开出来的跟着关。
        mac(client, sessions: [shell], codeTabs: [])
        follow(model, client)
        XCTAssertNil(model.codePane)
        XCTAssertEqual(loose(model), [shell])
    }

    /// Mac 上「移到新标签页」（或者这边请它挪）：会话离开 Code 标签页、成了终端标签，开出来时放到前台。
    func testRunMovedToATabBecomesATerminalTabInFront() async throws {
        let client = macClient()
        let (shell, a, macTab) = (UUID(), UUID(), UUID())
        mac(client, sessions: [shell, a], codeTabs: [codeTab(macTab, runs: [run(a)], slot: 1)])
        let model = makeModel(client)
        model.takeOver()
        let code = try code(model)

        reply = a
        model.moveCodeRunToTab(a)
        await code.remote?.lastAction?.value
        XCTAssertEqual(performed.map(\.knownAction), [.moveToTab])
        XCTAssertEqual(performed.first?.session, a)
        XCTAssertEqual(performed.first?.tab, macTab)
        XCTAssertEqual(code.runs.map(\.id), [a], "Mac 推来新的 Code 标签页之前不动")

        started = []
        mac(client, sessions: [shell, a], codeTabs: [codeTab(macTab, runs: [], slot: 1)])
        follow(model, client)
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertEqual(loose(model), [shell, a])
        XCTAssertEqual(started, [a], "开成终端标签、重新接入")
        XCTAssertEqual(model.active?.id, a, "放到前台")
    }

    /// 用户关掉镜像着的 Code 标签页：只断开（不请 Mac 结束会话），重新接管之前不再自动开，里面的会话也不另开终端标签。
    func testUserClosingTheCodeTabStopsMirroringUntilTheNextTakeover() throws {
        let client = macClient()
        let (shell, a, macTab) = (UUID(), UUID(), UUID())
        mac(client, sessions: [shell, a], codeTabs: [codeTab(macTab, runs: [run(a)], slot: 1)])
        let model = makeModel(client)
        model.takeOver()
        XCTAssertTrue(model.close(try XCTUnwrap(model.codePane?.id)))
        XCTAssertTrue(ended.isEmpty, "Mac 上的会话照常跑")
        XCTAssertTrue(performed.isEmpty)

        mac(client, sessions: [shell, a], codeTabs: [codeTab(macTab, runs: [run(a, title: "变了")], slot: 1)])
        follow(model, client)
        XCTAssertNil(model.codePane, "不再自动开")
        XCTAssertEqual(loose(model), [shell], "里面的会话也不开成终端标签")

        // 重新接管：又开出来。
        model.disposeAll()
        model.takeOver()
        XCTAssertNotNil(model.codePane)
        XCTAssertEqual(try code(model).runs.map(\.id), [a])
    }

    /// 标签菜单「历史会话…」/ Code 按钮：用户自己开的 Code 标签页。那台 Mac 有了 Code 标签页就接上它；Mac 上那个没了，
    /// 这个留着、只停镜像。
    func testUserOpenedCodeTabBindsToTheMacsAndStaysWhenItGoes() throws {
        let client = macClient()
        let (shell, a, macTab) = (UUID(), UUID(), UUID())
        mac(client, sessions: [shell], codeTabs: [])
        let model = makeModel(client)
        model.takeOver()
        XCTAssertNil(model.codePane)
        XCTAssertTrue(model.offersCodeTab)

        let id = model.openCodeTab()
        XCTAssertEqual(model.active?.id, id, "用户开的放到前台")
        XCTAssertNil(try code(model).remote?.macTabID, "那台 Mac 上还没有 Code 标签页")
        XCTAssertEqual(model.layout, [[shell]], "没在镜像的 Code 标签页不在 Mac 的顺序里")
        XCTAssertEqual(model.openCodeTab(), id, "已经开着就切过去")

        mac(client, sessions: [shell, a], codeTabs: [codeTab(macTab, runs: [run(a)], slot: 0)])
        follow(model, client)
        let code = try code(model)
        XCTAssertEqual(model.codePane?.id, id, "接上用户开的那个，不另开")
        XCTAssertEqual(code.remote?.macTabID, macTab)
        XCTAssertEqual(code.remote?.opensForMirror, false)
        XCTAssertEqual(code.runs.map(\.id), [a])
        XCTAssertEqual(loose(model), [shell])
        XCTAssertEqual(model.groups.allTabs.map(\.id), [id, shell], "排到 Mac 上它的位置")

        mac(client, sessions: [shell], codeTabs: [])
        follow(model, client)
        XCTAssertEqual(model.codePane?.id, id, "用户自己开的留着")
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertNil(code.remote?.macTabID)
    }

    /// 用户在这扇窗口里拖过标签：请那台 Mac 照着排的顺序里只有会话，没有 Code 标签页（Mac 不认它的 id）。
    func testOrderPushedToTheMacLeavesOutTheCodeTab() throws {
        let client = macClient()
        let (a, b, macTab) = (UUID(), UUID(), UUID())
        mac(client, sessions: [a, b], codeTabs: [codeTab(macTab, runs: [], slot: 1)])
        let model = makeModel(client)
        model.takeOver()
        let codeID = try XCTUnwrap(model.codePane?.id)
        let before = model.layout
        XCTAssertEqual(before, [[a, macTab, b]])

        model.groups.reorderTab(b, before: a)
        model.groups.reorderTab(codeID, before: b)
        XCTAssertEqual(model.layout, [[macTab, b, a]])
        XCTAssertEqual(model.macOrderPushes(from: before), [[b, a]])
    }

    /// 那台 Mac 不报 Code 标签页、或者不认文件请求：照旧，每个会话一个终端标签，没有 Code 标签页可开。
    func testMacWithoutCodeTabSupportKeepsLooseTabs() {
        let client = macClient()
        let (shell, inCode, macTab) = (UUID(), UUID(), UUID())
        mac(client, sessions: [shell, inCode], codeTabs: [codeTab(macTab, runs: [run(inCode)], slot: 1)])
        let model = makeModel(client, supported: false)
        model.takeOver()
        XCTAssertNil(model.codePane)
        XCTAssertEqual(loose(model), [shell, inCode])
        XCTAssertFalse(model.offersCodeTab)
        XCTAssertEqual(model.layout, [[shell, inCode]])
    }

    /// 「结束会话」请那台 Mac 结束（8 号消息），Mac 推来新的 Code 标签页之后才拿掉。
    func testEndingARunAsksTheMacToCloseIt() throws {
        let client = macClient()
        let (a, macTab) = (UUID(), UUID())
        mac(client, sessions: [a], codeTabs: [codeTab(macTab, runs: [run(a)], slot: 0)])
        let model = makeModel(client)
        model.takeOver()
        let code = try code(model)
        code.endSession(a)
        XCTAssertEqual(ended, [a])
        XCTAssertEqual(code.runs.map(\.id), [a])
        mac(client, sessions: [], codeTabs: [codeTab(macTab, runs: [], slot: 0)])
        follow(model, client)
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertEqual(loose(model), [], "结束了的不开成终端标签")
    }
}
