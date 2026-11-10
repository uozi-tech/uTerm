import Network
import XCTest
@testable import uTermMobile

/// 接管 Mac 后，手机上这台 Mac 的标签跟着 Mac 上的标签顺序排（会话列表里的 `order`）。
/// 只在这些标签原来占的位置之间换，不切走正看着的标签；老版本 Mac 不发顺序时不动。
@MainActor
final class MobileRemoteTabOrderTests: XCTestCase {

    private func macClient(_ name: String = "测试 Mac") -> RemoteMacClient {
        RemoteMacClient(macName: name, endpoint: .hostPort(host: "127.0.0.1", port: 1),
                        identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
    }

    private func info(_ id: UUID, order: Int?) -> RemoteSessionInfo {
        RemoteSessionInfo(id: id, serverID: RemoteConstants.localShellServerID, serverName: "本机", title: "zsh",
                          windowKind: "terminal", order: order)
    }

    /// 某一格里标签接着的 Mac 会话（不是远控标签记 nil）。
    private func sessions(_ ws: MobileWorkspace, pane: Int = 0) -> [UUID?] {
        ws.tabs(in: ws.panes[pane]).map { $0.terminal?.remote?.sessionID }
    }

    private func tabID(_ ws: MobileWorkspace, client: RemoteMacClient, session: UUID) throws -> UUID {
        try XCTUnwrap(ws.existing(remote: MRemoteSource(client: client, sessionID: session))?.id)
    }

    func testMacReorderMovesOnlyItsTabsAndKeepsTheFrontTab() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let a = UUID(), b = UUID(), c = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [a, b], focus: a))
        let (direct, _) = MobileFakeTerminal.tab(host: ServerProfile(), .idle)
        ws.open(.terminal(direct))
        _ = ws.follow(client, sessionIDs: [a, b, c], order: [a, b, c])
        XCTAssertEqual(sessions(ws), [a, b, nil, c], "新开的排在末尾")
        let front = try tabID(ws, client: client, session: b)
        ws.activate(front)

        _ = ws.follow(client, sessionIDs: [c, b, a], order: [c, b, a])
        XCTAssertEqual(sessions(ws), [c, b, nil, a], "直连标签原地不动，这台 Mac 的在自己的格子里换")
        XCTAssertEqual(ws.activeTab?.id, front, "正看着的标签不被切走")
    }

    func testSplitPanesEachArrangeTheirOwnTabs() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let a = UUID(), b = UUID(), c = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [a, b, c], focus: a))
        _ = ws.follow(client, sessionIDs: [a, b, c], order: [a, b, c])
        ws.moveToOtherPane(try tabID(ws, client: client, session: b))
        let focused = ws.focusedPaneID
        let fronts = ws.panes.map(\.activeID)

        _ = ws.follow(client, sessionIDs: [c, b, a], order: [c, b, a])
        XCTAssertEqual(sessions(ws, pane: 0), [c, a])
        XCTAssertEqual(sessions(ws, pane: 1), [b], "挪到另一格的留在那一格")
        XCTAssertEqual(ws.focusedPaneID, focused)
        XCTAssertEqual(ws.panes.map(\.activeID), fronts)
    }

    func testAnotherMacsTabsStayPut() {
        let ws = MobileWorkspace()
        let one = macClient("一号"), two = macClient("二号")
        let a = UUID(), b = UUID(), x = UUID(), y = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: one, sessionIDs: [a, b], focus: a))
        _ = ws.takeOver(MRemoteTakeover(client: two, sessionIDs: [x, y], focus: x))
        _ = ws.follow(one, sessionIDs: [b, a], order: [b, a])
        _ = ws.follow(two, sessionIDs: [y, x], order: nil)
        XCTAssertEqual(sessions(ws), [b, a, x, y], "二号是老版本 Mac：不排")
    }

    /// 老版本 Mac：列表里没有排位，手机保持现状（列表顺序变了也不跟）。
    func testOldMacLeavesTheOrderAlone() {
        let ws = MobileWorkspace()
        let client = macClient()
        let a = UUID(), b = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [a, b], focus: a))
        client.receiveSessions([info(b, order: nil), info(a, order: nil)])
        _ = ws.follow(client, sessionIDs: client.listedSessionIDs, order: client.sessions.macTabOrder)
        XCTAssertEqual(sessions(ws), [a, b])
    }

    /// 再接管一次：已有的标签不重开，也按 Mac 上的顺序排好。
    func testTakeOverAgainArrangesByTheMacOrder() {
        let ws = MobileWorkspace()
        let client = macClient()
        let a = UUID(), b = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [a, b], focus: a))
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [b, a], focus: a, order: [b, a]))
        XCTAssertEqual(sessions(ws), [b, a])
        XCTAssertEqual(ws.activeTab?.terminal?.remote?.sessionID, a)
    }

    func testStoreTakeOverCarriesTheMacOrder() throws {
        let store = MobileStore()
        let client = macClient()
        let a = UUID(), b = UUID()
        client.receiveSessions([info(b, order: 0), info(a, order: 1)])
        store.takeOver(client, focus: a)
        XCTAssertEqual(try XCTUnwrap(store.remoteTakeover).order, [b, a])

        let old = macClient()
        old.receiveSessions([info(b, order: nil)])
        store.cancelConnect()
        store.takeOver(old, focus: b)
        XCTAssertNil(try XCTUnwrap(store.remoteTakeover).order)
    }
}
