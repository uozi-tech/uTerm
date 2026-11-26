import SwiftData
import XCTest
@testable import uTermMobile

/// 接管 Mac 时，Mac 上 SSH 主机的 Code 标签页（63 号消息里 `serverID` 是那台主机的 `ServerProfile.id`）镜像成手机上那台主机的
/// Code 标签页：手机上有这台主机（经 iCloud 同步）、不是仅 SFTP 时接上已经开着的那个（里面直连起的会话照旧），没有就在后台开一个、
/// 露出来之前不连；手机上没有这台主机就照旧散成终端标签页。本机的与 SSH 主机的同时镜像、排进 Mac 的标签顺序；关掉的重新接管之前
/// 不再开；Mac 认得 `code-tab-hosts` 才把「继续」「＋」等请 Mac 做（带上主机）。远控终端长按「历史会话」开的是它所在那台主机的。
/// 不连真 Mac、不连真主机：Mac 推来的直接交给 `RemoteMacClient`，记录的连接不打开。
@MainActor
final class CodeTabHostMirrorTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try MobileFixtures.emptyContainer()
    }

    override func tearDown() async throws {
        container = nil
    }

    /// 手机上已保存的一台 SSH 主机（同步过来的，id 和 Mac 上的一样）。
    private func savedHost(_ name: String = "prod", sftpOnly: Bool = false) throws -> ServerProfile {
        let host = ServerProfile()
        host.name = name
        // 连不上的地址：用例里真去连（「历史会话」开出来就连）也马上失败，不出网。
        host.host = "127.0.0.1"
        host.port = 1
        host.username = "deploy"
        host.sftpOnly = sftpOnly
        container.mainContext.insert(host)
        try container.mainContext.save()
        return host
    }

    private func workspace(knowing hosts: [ServerProfile]) -> MobileWorkspace {
        let ws = MobileWorkspace()
        ws.savedHost = { id in hosts.first { $0.id == id } }
        return ws
    }

    private func macClient(_ name: String = "测试 Mac") -> RemoteMacClient {
        RemoteMacClient(macName: name, endpoint: .hostPort(host: "127.0.0.1", port: 1),
                        identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
    }

    private let local = RemoteConstants.localShellServerID

    private func session(_ id: UUID, server: UUID, order: Int) -> RemoteSessionInfo {
        RemoteSessionInfo(id: id, serverID: server, serverName: server == local ? "本机" : "prod", title: "zsh",
                          windowKind: "terminal", order: order)
    }

    private func run(_ id: UUID, ended: Date? = nil) -> RemoteCodeTabInfo.Run {
        RemoteCodeTabInfo.Run(session: id, tool: AgentHistoryTool.claude.rawValue, directory: "/srv/app",
                              startedAt: Date(timeIntervalSince1970: 1_800_000_000), sessionID: nil, path: nil,
                              title: nil, endedAt: ended)
    }

    private func codeTab(_ id: UUID = UUID(), server: UUID, runs: [RemoteCodeTabInfo.Run],
                         slot: Int? = nil) -> RemoteCodeTabInfo {
        RemoteCodeTabInfo(id: id, serverID: server, serverName: server == local ? "本机" : "prod", directory: "/srv/app",
                          slot: slot, runs: runs, selectedRun: nil, selectedRecord: nil)
    }

    /// Mac 推来一轮：先 Code 标签页、再会话列表（同真 Mac 的先后）。`sessions` 是 (会话, 主机)，按 Mac 上的顺序。
    private func mac(_ client: RemoteMacClient, sessions: [(UUID, UUID)], codeTabs: [RemoteCodeTabInfo]) {
        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: codeTabs))
        client.receiveSessions(sessions.enumerated().map { session($1.0, server: $1.1, order: $0) })
    }

    @discardableResult
    private func takeOver(_ ws: MobileWorkspace, _ client: RemoteMacClient, focus: UUID) -> RemoteTabChanges {
        ws.takeOver(MRemoteTakeover(client: client, sessionIDs: client.sessions.map(\.id), focus: focus,
                                    order: client.sessions.macTabOrder))
    }

    @discardableResult
    private func follow(_ ws: MobileWorkspace, _ client: RemoteMacClient) -> RemoteTabChanges {
        ws.follow(client, sessionIDs: client.listedSessionIDs, order: client.sessions.macTabOrder)
    }

    private func loose(_ ws: MobileWorkspace) -> [UUID] {
        ws.terminalTabs.compactMap { $0.remote?.sessionID }
    }

    private func hostCode(_ ws: MobileWorkspace, _ host: ServerProfile) throws -> ClaudeHistoryTab {
        try XCTUnwrap(ws.existingHistory(host: host.persistentModelID))
    }

    // MARK: - 开出来

    /// 手机上有这台主机、还没开它的 Code 标签页：在后台开一个（不抢前台、不连主机），Mac 上那里面的会话放进它，不另开终端标签页。
    func testSSHCodeTabOpensTheHostsCodeTabInTheBackgroundWithoutConnecting() throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let client = macClient()
        let (shell, inCode) = (UUID(), UUID())
        let macTab = UUID()
        mac(client, sessions: [(shell, local), (inCode, host.id)],
            codeTabs: [codeTab(macTab, server: host.id, runs: [run(inCode)], slot: 1)])

        let changes = takeOver(ws, client, focus: shell)
        XCTAssertEqual(loose(ws), [shell], "Code 标签页里的会话不另开终端标签页")
        let code = try hostCode(ws, host)
        XCTAssertNil(code.remoteMac, "记录经手机自己的 SSH 读，不读 Mac 本机的")
        XCTAssertTrue(code.host === host)
        XCTAssertTrue(code.mirrorClient === client)
        XCTAssertEqual(code.mirroredMacTabID, macTab)
        XCTAssertTrue(code.opensForMirror)
        XCTAssertTrue(code.startsWhenShown, "接管时不连那台主机，露出来再连")
        XCTAssertNil(code.connection.history)
        XCTAssertEqual(code.runs.runs.map(\.id), [inCode])
        XCTAssertEqual(code.runs.runs.first?.isMirrored, true)
        XCTAssertEqual(code.runs.runs.first?.terminal.remote?.sessionID, inCode, "终端接着 Mac 上那个会话")
        XCTAssertEqual(Set(changes.opened.compactMap { $0.remote?.sessionID }), [shell, inCode])
        XCTAssertEqual(ws.activeTab?.terminal?.remote?.sessionID, shell, "开在后台")
        XCTAssertEqual(ws.panes[0].tabIDs.last, code.id, "排在 Mac 上它的位置（shell 之后）")
        XCTAssertEqual(ws.remoteTerminal(MRemoteSource(client: client, sessionID: inCode))?.tabID, code.id)
        XCTAssertTrue(ws.remoteTabIDs(of: client).contains(code.id))

        let again = follow(ws, client)
        XCTAssertTrue(again.opened.isEmpty)
        XCTAssertTrue(again.removed.isEmpty)
        XCTAssertNil(ws.mirroredCodeTab(of: client), "没有本机的 Code 标签页")
    }

    /// 已经开着这台主机的 Code 标签页、里面有直连起的会话：接上它（不另开），两种会话在同一个列表里；Mac 上那个没了只停镜像，
    /// 直连起的照旧。
    func testSSHCodeTabMergesIntoTheOpenDirectCodeTabAndKeepsItsLocalRuns() throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let mine = ws.openHistory(MobileFakeClaudeHistory.tab(host: host, tree: MobileClaudeFixture.standard()))
        let localRun = mine.runs.startNew(tool: .codex, directory: "/srv/app", terminal: TermTab(host: host))
        let client = macClient()
        let (shell, inCode) = (UUID(), UUID())
        mac(client, sessions: [(shell, local), (inCode, host.id)], codeTabs: [codeTab(server: host.id, runs: [run(inCode)])])

        takeOver(ws, client, focus: shell)
        XCTAssertTrue(try hostCode(ws, host) === mine)
        XCTAssertEqual(ws.tabs.compactMap(\.history).count, 1)
        XCTAssertFalse(mine.opensForMirror)
        XCTAssertEqual(mine.runs.runs.map(\.id), [localRun.id, inCode])
        XCTAssertEqual(mine.runs.runs.map(\.isMirrored), [false, true])
        XCTAssertEqual(mine.localRunTerminals.map(\.id), [localRun.terminal.id], "关前确认只问直连起的")
        XCTAssertEqual(loose(ws), [shell])

        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: []))
        follow(ws, client)
        XCTAssertTrue(ws.existingHistory(host: host.persistentModelID) === mine, "用户自己开的留着")
        XCTAssertEqual(mine.runs.runs.map(\.id), [localRun.id], "直连起的照旧，镜像的拿掉")
        XCTAssertNil(mine.mirroredMacTabID)
        XCTAssertNil(mine.mirrorClient)
        XCTAssertEqual(Set(loose(ws)), [shell, inCode], "不再归 Code 标签页的会话开成终端标签页")
    }

    /// 镜像开出来的、后来在这边起了会话：Mac 上那个没了也不关（会把直连的会话一起关掉），只停镜像。
    func testMirrorOpenedHostTabWithLocalRunsIsKeptWhenTheMacsGoes() throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let client = macClient()
        let (shell, inCode) = (UUID(), UUID())
        mac(client, sessions: [(shell, local), (inCode, host.id)], codeTabs: [codeTab(server: host.id, runs: [run(inCode)])])
        takeOver(ws, client, focus: shell)
        let code = try hostCode(ws, host)
        XCTAssertTrue(code.closesWithMirror)
        code.runs.startNew(tool: .claude, directory: "/srv/app", terminal: TermTab(host: host))
        XCTAssertFalse(code.closesWithMirror)

        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: []))
        let changes = follow(ws, client)
        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertTrue(ws.existingHistory(host: host.persistentModelID) === code)
        XCTAssertNil(code.mirroredMacTabID)
    }

    /// 镜像开出来、里面只有镜像的会话：Mac 上那个没了跟着关。
    func testMirrorOpenedHostTabClosesWhenTheMacsGoes() throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let client = macClient()
        let (shell, inCode) = (UUID(), UUID())
        mac(client, sessions: [(shell, local), (inCode, host.id)], codeTabs: [codeTab(server: host.id, runs: [run(inCode)])])
        takeOver(ws, client, focus: shell)
        let code = try hostCode(ws, host)

        client.receiveCodeTabs(RemoteCodeTabsUpdate(tabs: []))
        let changes = follow(ws, client)
        XCTAssertNil(ws.existingHistory(host: host.persistentModelID))
        XCTAssertEqual(changes.removed.compactMap(\.history).map(\.id), [code.id])
    }

    /// 露出来才连：第一次露出来（`startIfDeferred`）连一次，之后不再重来。
    func testDeferredHostTabStartsOnceWhenShown() throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let client = macClient()
        let (shell, inCode) = (UUID(), UUID())
        mac(client, sessions: [(shell, local), (inCode, host.id)], codeTabs: [codeTab(server: host.id, runs: [run(inCode)])])
        takeOver(ws, client, focus: shell)
        let code = try hostCode(ws, host)
        XCTAssertTrue(code.startsWhenShown)
        code.startIfDeferred()
        XCTAssertFalse(code.startsWhenShown)
        code.close()
    }

    // MARK: - 镜像不了

    /// 手机上没有这台主机（没同步过来）、或者它仅 SFTP：不镜像，里面的会话照旧开成终端标签页（同一个会话不会接两次）。
    func testWithoutAUsableHostOnThePhoneRunsStayLooseTabs() throws {
        let sftp = try savedHost("files", sftpOnly: true)
        let unknown = UUID()
        let ws = workspace(knowing: [sftp])
        let client = macClient()
        let (shell, a, b) = (UUID(), UUID(), UUID())
        mac(client, sessions: [(shell, local), (a, unknown), (b, sftp.id)],
            codeTabs: [codeTab(server: unknown, runs: [run(a)]), codeTab(server: sftp.id, runs: [run(b)])])

        takeOver(ws, client, focus: shell)
        XCTAssertEqual(loose(ws), [shell, a, b])
        XCTAssertTrue(ws.tabs.compactMap(\.history).isEmpty)
        XCTAssertTrue(follow(ws, client).opened.isEmpty)
    }

    /// 两台 Mac 上有同一台主机的 Code 标签页：先接上的那台镜像，另一台的会话照旧是终端标签页（各在各的连接上）。
    func testSecondMacWithTheSameHostKeepsLooseTabs() throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let (first, second) = (macClient("一"), macClient("二"))
        let (a, b) = (UUID(), UUID())
        mac(first, sessions: [(a, host.id)], codeTabs: [codeTab(server: host.id, runs: [run(a)])])
        mac(second, sessions: [(b, host.id)], codeTabs: [codeTab(server: host.id, runs: [run(b)])])
        takeOver(ws, first, focus: a)
        takeOver(ws, second, focus: b)

        let code = try hostCode(ws, host)
        XCTAssertTrue(code.mirrorClient === first)
        XCTAssertEqual(code.runs.runs.map(\.id), [a])
        XCTAssertEqual(loose(ws), [b])
        XCTAssertFalse(ws.remoteTabIDs(of: second).contains(code.id))
    }

    // MARK: - 本机的和 SSH 主机的一起

    /// 本机的与 SSH 主机的 Code 标签页同时镜像：两边的会话都不另开终端标签页，两个 Code 标签页按 Mac 报的位置排进标签顺序。
    func testLocalAndHostCodeTabsMirrorTogetherInTheMacsOrder() throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let client = macClient()
        let (shell, other, inLocal, inHost) = (UUID(), UUID(), UUID(), UUID())
        let (localTab, hostTab) = (UUID(), UUID())
        mac(client, sessions: [(shell, local), (other, host.id), (inLocal, local), (inHost, host.id)],
            codeTabs: [codeTab(localTab, server: local, runs: [run(inLocal)], slot: 0),
                       codeTab(hostTab, server: host.id, runs: [run(inHost)], slot: 1)])

        takeOver(ws, client, focus: shell)
        XCTAssertEqual(loose(ws), [shell, other])
        let localCode = try XCTUnwrap(ws.existingHistory(remoteMac: client))
        let hostCode = try hostCode(ws, host)
        XCTAssertEqual(localCode.runs.runs.map(\.id), [inLocal])
        XCTAssertEqual(hostCode.runs.runs.map(\.id), [inHost])
        let shellTab = try XCTUnwrap(ws.existing(remote: MRemoteSource(client: client, sessionID: shell)))
        let otherTab = try XCTUnwrap(ws.existing(remote: MRemoteSource(client: client, sessionID: other)))
        XCTAssertEqual(ws.panes[0].tabIDs, [localCode.id, shellTab.id, hostCode.id, otherTab.id])
        XCTAssertEqual(ws.remoteTabIDs(of: client), [localCode.id, shellTab.id, hostCode.id, otherTab.id])

        // Mac 上 SSH 主机的那个挪到最后：手机上跟着排。
        mac(client, sessions: [(shell, local), (other, host.id), (inLocal, local), (inHost, host.id)],
            codeTabs: [codeTab(localTab, server: local, runs: [run(inLocal)], slot: 0),
                       codeTab(hostTab, server: host.id, runs: [run(inHost)], slot: 2)])
        follow(ws, client)
        XCTAssertEqual(ws.panes[0].tabIDs, [localCode.id, shellTab.id, otherTab.id, hostCode.id])

        // Mac 上把 SSH 主机的会话挪出 Code 标签页：只影响那一个，本机的照旧。
        mac(client, sessions: [(shell, local), (other, host.id), (inLocal, local), (inHost, host.id)],
            codeTabs: [codeTab(localTab, server: local, runs: [run(inLocal)], slot: 0),
                       codeTab(hostTab, server: host.id, runs: [], slot: 2)])
        let moved = follow(ws, client)
        XCTAssertEqual(moved.opened.compactMap { $0.remote?.sessionID }, [inHost])
        XCTAssertTrue(hostCode.runs.runs.isEmpty)
        XCTAssertEqual(localCode.runs.runs.map(\.id), [inLocal])
    }

    /// 用户关掉手机上 SSH 主机的那个：只断开镜像，重新接管之前不再开、里面的会话也不另开终端标签页；本机的不受影响。
    func testClosingTheHostTabDetachesUntilTheNextTakeover() throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let client = macClient()
        let (shell, inLocal, inHost) = (UUID(), UUID(), UUID())
        let hostTab = UUID()
        let sessions = [(shell, local), (inLocal, local), (inHost, host.id)]
        let tabs = [codeTab(server: local, runs: [run(inLocal)]), codeTab(hostTab, server: host.id, runs: [run(inHost)])]
        mac(client, sessions: sessions, codeTabs: tabs)
        takeOver(ws, client, focus: shell)
        let code = try hostCode(ws, host)
        var ended: [UUID] = []
        code.endOnMac = { ended.append($0) }
        let term = try XCTUnwrap(code.mirroredTerminal(session: inHost))

        // 同工作区屏的 closeTab。
        let removed = try XCTUnwrap(ws.close(code.id))
        removed.shutdown()
        ws.noteClosedByUser(removed)
        ws.stopFollowingIfLastTab(removed)
        XCTAssertTrue(ended.isEmpty, "关标签页不结束 Mac 上的会话")
        XCTAssertEqual(term.controller.state, .disconnected)
        XCTAssertEqual(ws.followedClients.count, 1)

        mac(client, sessions: sessions, codeTabs: tabs)
        let after = follow(ws, client)
        XCTAssertNil(ws.existingHistory(host: host.persistentModelID), "关过的不再自动开")
        XCTAssertTrue(after.opened.isEmpty, "里面的会话也不另开终端标签页")
        XCTAssertEqual(loose(ws), [shell])
        XCTAssertNotNil(ws.mirroredCodeTab(of: client), "本机的照旧")

        takeOver(ws, client, focus: shell)
        XCTAssertEqual(try hostCode(ws, host).runs.runs.map(\.id), [inHost], "重新接管：又开出来")
    }

    /// 断开整台 Mac：镜像开出来、只有镜像会话的一起收掉；用户自己开的留下、只停镜像。
    func testEndingTheTakeoverClosesMirrorOpenedHostTabsAndDetachesTheUsers() throws {
        let (mineHost, autoHost) = (try savedHost("mine"), try savedHost("auto"))
        let ws = workspace(knowing: [mineHost, autoHost])
        let mine = ws.openHistory(MobileFakeClaudeHistory.tab(host: mineHost, tree: MobileClaudeFixture.standard()))
        let client = macClient()
        let (a, b) = (UUID(), UUID())
        mac(client, sessions: [(a, mineHost.id), (b, autoHost.id)],
            codeTabs: [codeTab(server: mineHost.id, runs: [run(a)]), codeTab(server: autoHost.id, runs: [run(b)])])
        takeOver(ws, client, focus: a)
        let auto = try hostCode(ws, autoHost)
        XCTAssertEqual(mine.runs.runs.map(\.id), [a])

        let torn = ws.endTakeover(of: client)
        XCTAssertEqual(torn, [auto.id])
        XCTAssertNil(mine.mirroredMacTabID)
        XCTAssertTrue(mine.runs.runs.isEmpty)
    }

    // MARK: - 操作

    private final class MacActions {
        var sent: [RemoteCodeTabAction] = []
        var reply: @MainActor (RemoteCodeTabAction) async throws -> UUID = { _ in UUID() }
    }

    @discardableResult
    private func macActions(_ code: ClaudeHistoryTab, hosts: Bool) -> MacActions {
        let actions = MacActions()
        code.macSupportsCodeTabActions = { true }
        code.macSupportsCodeTabHosts = { hosts }
        code.macCodeTabAction = { action in
            actions.sent.append(action)
            return try await actions.reply(action)
        }
        return actions
    }

    private func record(_ sessionID: String) -> AgentHistorySessionFile {
        let project = AgentHistoryProject(id: "-srv-app", path: "/home/deploy/.claude/projects/-srv-app",
                                          modifiedAt: nil, directory: "/srv/app", tool: .claude)
        return AgentHistorySessionFile(sessionID: sessionID, project: project,
                                       path: "/home/deploy/.claude/projects/-srv-app/\(sessionID).jsonl", size: 1,
                                       modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Mac 认得 `code-tab-hosts`：「继续」「＋」「重新开始」「移到新标签页」请 Mac 做，带上这台主机与 Mac 上那个 Code 标签页；
    /// 「结束会话」请 Mac 结束（消息 8）。
    func testActionsGoToTheMacWithTheHostWhenItDeclaresCodeTabHosts() async throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let client = macClient()
        let (ended, running) = (UUID(), UUID())
        let macTab = UUID()
        mac(client, sessions: [(ended, host.id), (running, host.id)],
            codeTabs: [codeTab(macTab, server: host.id,
                               runs: [run(ended, ended: Date(timeIntervalSince1970: 1_800_000_600)), run(running)])])
        takeOver(ws, client, focus: running)
        let code = try hostCode(ws, host)
        let actions = macActions(code, hosts: true)
        actions.reply = { $0.session ?? UUID() }
        var endedOnMac: [UUID] = []
        code.endOnMac = { endedOnMac.append($0) }
        XCTAssertTrue(code.runsOnMacCodeTab)

        try await code.resumeOnMac(record("s-1"), directory: "/srv/app")
        try await code.startOnMac(tool: .codex, directory: "/srv/other")
        try await code.restartOnMac(ended)
        try await code.moveMirroredRunToTab(running, in: ws)
        XCTAssertEqual(actions.sent.map(\.knownAction), [.resume, .start, .restart, .moveToTab])
        XCTAssertTrue(actions.sent.allSatisfy { $0.server == host.id }, "带上主机：Mac 不会当成它本机的做")
        XCTAssertTrue(actions.sent.allSatisfy { $0.tab == macTab })

        let runs = CodeTabRuns(tab: code, onMoveToTab: { _ in })
        XCTAssertTrue(runs.canRestart(try XCTUnwrap(code.runs.run(id: ended))))
        XCTAssertTrue(runs.canMoveToTab(try XCTUnwrap(code.runs.run(id: running))))

        code.endRun(running)
        XCTAssertEqual(endedOnMac, [running], "结束镜像的会话请 Mac 结束")
        XCTAssertNotNil(code.runs.run(id: running), "等 Mac 推来新的再拿掉")
    }

    /// Mac 不认得 `code-tab-hosts`（只认本机的 Code 标签页）：一个也不发，「继续」「＋」照旧经手机自己的 SSH 在这里起，
    /// 镜像的会话不出「重新开始」「移到新标签页」；「结束会话」照旧请 Mac 结束。
    func testWithoutCodeTabHostsActionsRunInPlaceAndMirroredRestartMoveAreHidden() async throws {
        let host = try savedHost()
        let ws = workspace(knowing: [host])
        let client = macClient()
        let (ended, running) = (UUID(), UUID())
        mac(client, sessions: [(ended, host.id), (running, host.id)],
            codeTabs: [codeTab(server: host.id,
                               runs: [run(ended, ended: Date(timeIntervalSince1970: 1_800_000_600)), run(running)])])
        takeOver(ws, client, focus: running)
        let code = try hostCode(ws, host)
        let actions = macActions(code, hosts: false)
        var endedOnMac: [UUID] = []
        code.endOnMac = { endedOnMac.append($0) }

        XCTAssertFalse(code.runsOnMacCodeTab)
        XCTAssertTrue(code.runsInPlace, "直连这台主机在这里起")
        XCTAssertTrue(code.canResume)
        try await code.resumeOnMac(record("s-1"), directory: "/srv/app")
        try await code.startOnMac(tool: .claude, directory: "/srv/app")
        try await code.restartOnMac(ended)
        try await code.moveMirroredRunToTab(running, in: ws)
        XCTAssertTrue(actions.sent.isEmpty)

        let runs = CodeTabRuns(tab: code, onMoveToTab: { _ in })
        XCTAssertFalse(runs.canRestart(try XCTUnwrap(code.runs.run(id: ended))))
        XCTAssertFalse(runs.canMoveToTab(try XCTUnwrap(code.runs.run(id: running))))

        code.endRun(running)
        XCTAssertEqual(endedOnMac, [running])
    }

    /// 本机的 Code 标签页请 Mac 做事时不带主机（之前的 Mac 也照旧认）。
    func testLocalCodeTabActionsCarryNoServer() async throws {
        let ws = workspace(knowing: [])
        let client = macClient()
        let a = UUID()
        mac(client, sessions: [(a, local)], codeTabs: [codeTab(server: local, runs: [run(a)])])
        takeOver(ws, client, focus: a)
        let code = try XCTUnwrap(ws.existingHistory(remoteMac: client))
        let actions = macActions(code, hosts: false)
        XCTAssertTrue(code.runsOnMacCodeTab, "本机的不要 code-tab-hosts")
        try await code.startOnMac(tool: .claude, directory: "/Users/me/app")
        XCTAssertEqual(actions.sent.count, 1)
        XCTAssertNil(actions.sent.first?.server)
    }

    // MARK: - 远控终端的「历史会话」（实测报的问题）

    /// 远控终端在 Mac 的 SSH 主机上：「历史会话」开手机上那台主机的 Code 标签页（经手机自己的 SSH），不再读 Mac 本机的记录；
    /// 手机上没有这台主机就不出这一项。在 Mac 本机上的照旧读那台 Mac 的。
    func testRemoteSSHTerminalHistoryOpensThatHostNotTheMac() throws {
        let host = try savedHost()
        let client = macClient()
        let (onHost, onUnknown, onMac) = (UUID(), UUID(), UUID())
        client.receiveSessions([session(onHost, server: host.id, order: 0), session(onUnknown, server: UUID(), order: 1),
                                session(onMac, server: local, order: 2)])
        func term(_ id: UUID) -> TermTab {
            TermTab(host: client.tabHost(for: id), remote: MRemoteSource(client: client, sessionID: id))
        }

        let ws = workspace(knowing: [host])
        XCTAssertTrue(ws.offersCode(for: term(onHost)))
        let opened = try XCTUnwrap(ws.showCode(for: term(onHost), container: container))
        XCTAssertNil(opened.remoteMac, "不是读 Mac 本机的记录")
        XCTAssertTrue(opened.host === host)
        XCTAssertTrue(ws.showCode(for: term(onHost), container: container) === opened, "同一台主机一个")
        opened.close()

        XCTAssertFalse(ws.offersCode(for: term(onUnknown)), "手机上没有这台主机：不出")
        XCTAssertNil(ws.showCode(for: term(onUnknown), container: container))
        XCTAssertEqual(ws.tabs.compactMap(\.history).count, 1, "没开 Mac 本机的")

        // Mac 本机上的：照 `offersClaudeHistory`（要那台 Mac 能读文件；这台没连上，不能）。
        let macTerm = term(onMac)
        XCTAssertEqual(ws.offersCode(for: macTerm), macTerm.offersClaudeHistory)
        XCTAssertFalse(ws.offersCode(for: macTerm))
    }
}
