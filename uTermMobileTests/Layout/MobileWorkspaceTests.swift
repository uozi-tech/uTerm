import Network
import XCTest
@testable import uTermMobile

/// `MobileWorkspace` 的标签 / 分屏规则：只动模型，不挂视图、不建连接。
@MainActor
final class MobileWorkspaceTests: XCTestCase {

    private func termTab() -> MWorkTab {
        let (tab, _) = MobileFakeTerminal.tab(host: ServerProfile(), .idle)
        return .terminal(tab)
    }

    private func filesTab() -> MWorkTab { .files(FileTab(host: ServerProfile())) }

    private func macClient() -> RemoteMacClient {
        RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                        identity: RemoteIdentityStore(storage: RemoteMemoryStorage()))
    }

    // MARK: - 接管 Mac

    /// 远控标签跟 Mac 上那枚标签同名；老版本 Mac 不发这个名字时照旧用终端流里的标题。
    func testRemoteTabTitleFollowsTheMacTab() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let id = UUID()
        let opened = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [id], focus: id)).opened
        let term = try XCTUnwrap(opened.first)
        let tab = MWorkTab.terminal(term)
        term.controller.title = "终端流里的标题"
        XCTAssertEqual(tab.title, "终端流里的标题")

        var info = RemoteSessionInfo(id: id, serverID: RemoteConstants.localShellServerID, serverName: "本机",
                                     title: "zsh 2", windowKind: "terminal")
        client.receiveSessions([info])
        XCTAssertEqual(tab.title, "终端流里的标题", "老版本 Mac 只有注册表里的名字，不拿它盖掉")

        info.tabTitle = "vim main.swift"
        client.receiveSessions([info])
        XCTAssertEqual(tab.title, "vim main.swift")

        info.tabTitle = "zsh 2"
        client.receiveSessions([info])
        XCTAssertEqual(tab.title, "zsh 2", "Mac 上程序清掉标题后，手机也回到原名")
    }

    func testTakeOverOpensEveryTerminalAndFrontsTheFocusedOne() {
        let ws = MobileWorkspace()
        let client = macClient()
        let ids = [UUID(), UUID(), UUID()]

        let changes = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: ids, focus: ids[1]))
        let opened = changes.opened

        XCTAssertEqual(opened.compactMap(\.remote?.sessionID), ids, "Mac 上的每个终端一个标签，顺序不变")
        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertEqual(ws.panes[0].tabIDs, opened.map(\.id))
        XCTAssertEqual(ws.activeTab?.terminal?.remote?.sessionID, ids[1])
        XCTAssertEqual(ws.remoteTabIDs(of: client), Set(opened.map(\.id)))
        XCTAssertTrue(ws.remoteTabIDs(of: macClient()).isEmpty, "别的 Mac 的标签不算")
    }

    func testTakeOverAgainKeepsLiveTabsAndReplacesEndedOnes() {
        let ws = MobileWorkspace()
        let client = macClient()
        let live = UUID(), ended = UUID(), added = UUID()
        let first = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [live, ended], focus: live)).opened
        first[1].controller.close()

        let second = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [live, ended, added], focus: added))

        XCTAssertEqual(second.opened.compactMap(\.remote?.sessionID), [ended, added], "活着的不重开")
        XCTAssertEqual(second.removed.map(\.id), [first[1].id], "接入已结束的换成新标签")
        XCTAssertEqual(ws.tabs.count, 3)
        XCTAssertNotNil(ws.tab(first[0].id), "活着的还是原来那个标签")
        XCTAssertEqual(ws.activeTab?.terminal?.remote?.sessionID, added)
    }

    func testFollowOpensNewTerminalsInBackground() {
        let ws = MobileWorkspace()
        let client = macClient()
        let first = UUID(), second = UUID(), added = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [first, second], focus: first))

        let changes = ws.follow(client, sessionIDs: [first, second, added])

        XCTAssertEqual(changes.opened.compactMap(\.remote?.sessionID), [added])
        XCTAssertEqual(ws.tabs.count, 3)
        XCTAssertEqual(ws.activeTab?.terminal?.remote?.sessionID, first, "新终端不抢前台")
        XCTAssertTrue(ws.follow(client, sessionIDs: [first, second, added]).opened.isEmpty, "同一份列表不重复开")
    }

    func testFollowDoesNotReopenTabClosedOnThePhone() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let kept = UUID(), closed = UUID()
        let opened = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [kept, closed], focus: kept)).opened
        ws.close(try XCTUnwrap(opened.last).id)

        XCTAssertTrue(ws.follow(client, sessionIDs: [kept, closed]).opened.isEmpty)
        XCTAssertEqual(ws.tabs.count, 1)
    }

    func testFollowClosesTabOfTerminalClosedOnTheMac() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let kept = UUID(), closed = UUID()
        let opened = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [kept, closed], focus: closed)).opened
        _ = ws.follow(client, sessionIDs: [kept, closed])

        let changes = ws.follow(client, sessionIDs: [kept])

        XCTAssertEqual(changes.removed.map(\.id), [try XCTUnwrap(opened.last).id])
        XCTAssertTrue(changes.opened.isEmpty)
        XCTAssertEqual(ws.terminalTabs.compactMap(\.remote?.sessionID), [kept])
        XCTAssertEqual(ws.activeTab?.terminal?.remote?.sessionID, kept, "前台被关时落到相邻标签")
    }

    /// 刚在 Mac 上开的本机 shell 可能排在列表更新之前：列表里还没有它不等于它关了。
    func testFollowKeepsTabOfTerminalNotYetListed() {
        let ws = MobileWorkspace()
        let client = macClient()
        let listed = UUID(), justOpened = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [listed, justOpened], focus: justOpened))

        XCTAssertTrue(ws.follow(client, sessionIDs: [listed]).removed.isEmpty, "还没进过列表，不关")
        XCTAssertTrue(ws.follow(client, sessionIDs: [listed, justOpened]).opened.isEmpty, "进列表也不重复开")
        XCTAssertEqual(ws.tabs.count, 2)

        XCTAssertEqual(ws.follow(client, sessionIDs: [listed]).removed.count, 1, "进过列表又没了才算关了")
        XCTAssertEqual(ws.tabs.count, 1)
    }

    func testFollowOpensTerminalThatCameBackAfterLeavingTheList() {
        let ws = MobileWorkspace()
        let client = macClient()
        let kept = UUID(), flaky = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [kept, flaky], focus: kept))
        _ = ws.follow(client, sessionIDs: [kept, flaky])
        _ = ws.follow(client, sessionIDs: [kept])

        let changes = ws.follow(client, sessionIDs: [kept, flaky])

        XCTAssertEqual(changes.opened.compactMap(\.remote?.sessionID), [flaky])
        XCTAssertEqual(ws.tabs.count, 2)
    }

    func testFollowContinuesAfterTheMacClosesEveryTerminal() {
        let ws = MobileWorkspace()
        let client = macClient()
        let only = UUID(), later = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [only], focus: only))
        _ = ws.follow(client, sessionIDs: [only])

        XCTAssertEqual(ws.follow(client, sessionIDs: []).removed.count, 1)
        XCTAssertTrue(ws.isEmpty)
        XCTAssertEqual(ws.followedClients.count, 1, "Mac 上全关了还在接管")

        let changes = ws.follow(client, sessionIDs: [later])

        XCTAssertEqual(changes.opened.compactMap(\.remote?.sessionID), [later])
        XCTAssertEqual(ws.activeTab?.terminal?.remote?.sessionID, later, "那一格没有前台标签，新标签就是前台")
    }

    func testStopFollowingEndsTheTakeover() {
        let ws = MobileWorkspace()
        let client = macClient()
        let only = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [only], focus: only))

        ws.stopFollowing(client)

        XCTAssertTrue(ws.followedClients.isEmpty)
        XCTAssertTrue(ws.follow(client, sessionIDs: [only, UUID()]).opened.isEmpty, "断开之后不再跟进")
        XCTAssertEqual(ws.tabs.count, 1, "标签由调用方关")
    }

    func testStoreTakeOverIncludesFocusMissingFromTheList() throws {
        let store = MobileStore()
        let focus = UUID()

        store.takeOver(macClient(), focus: focus)

        let takeover = try XCTUnwrap(store.remoteTakeover)
        XCTAssertEqual(takeover.sessionIDs, [focus], "刚开的本机 shell 可能还没出现在列表里")
        XCTAssertEqual(takeover.focus, focus)
        XCTAssertEqual(store.connecting?.remote?.sessionID, focus)
        XCTAssertTrue(store.showWorkspace)
    }

    func testCancellingTakeoverTearsDownEveryTabItOpened() throws {
        let store = MobileStore()
        store.takeOver(macClient(), focus: UUID())
        let req = try XCTUnwrap(store.connecting)
        let front = UUID(), other = UUID()
        req.tabID = front
        req.companionTabIDs = [other]

        store.cancelConnect()

        XCTAssertEqual(store.teardownTabIDs, [front, other])
        XCTAssertNil(store.connecting)
        XCTAssertNil(store.remoteTakeover)
    }

    // MARK: - 标签与分屏

    func testOpenAppendsToFocusedPaneAndActivates() {
        let ws = MobileWorkspace()
        let a = termTab(), b = filesTab()
        ws.open(a)
        ws.open(b)
        XCTAssertEqual(ws.panes.count, 1)
        XCTAssertEqual(ws.panes[0].tabIDs, [a.id, b.id])
        XCTAssertEqual(ws.activeTab?.id, b.id)
        XCTAssertEqual(ws.activeTab?.kind, .sftp)
        XCTAssertEqual(ws.terminalTabs.map(\.id), [a.id])
    }

    func testClosingFrontTabActivatesRightNeighbourThenLeft() {
        let ws = MobileWorkspace()
        let a = termTab(), b = termTab(), c = filesTab()
        [a, b, c].forEach { ws.open($0) }
        ws.activate(b.id)
        ws.close(b.id)
        XCTAssertEqual(ws.activeTab?.id, c.id, "右邻接上")
        ws.close(c.id)
        XCTAssertEqual(ws.activeTab?.id, a.id, "没有右邻就落到左邻")
        ws.close(a.id)
        XCTAssertTrue(ws.isEmpty)
        XCTAssertNil(ws.activeTab)
        XCTAssertEqual(ws.panes.count, 1, "最后一格不收起")
    }

    func testClosingBackgroundTabKeepsFront() {
        let ws = MobileWorkspace()
        let a = termTab(), b = termTab()
        ws.open(a); ws.open(b)
        ws.close(a.id)
        XCTAssertEqual(ws.activeTab?.id, b.id)
    }

    func testSplitMovesFrontTabWhenPaneHasSeveral() {
        let ws = MobileWorkspace()
        let a = termTab(), b = filesTab()
        ws.open(a); ws.open(b)
        ws.split()
        XCTAssertTrue(ws.isSplit)
        XCTAssertEqual(ws.panes[0].tabIDs, [a.id])
        XCTAssertEqual(ws.panes[1].tabIDs, [b.id])
        XCTAssertEqual(ws.focusedPaneID, ws.panes[1].id)
        XCTAssertTrue(ws.isFront(a.id), "另一格的前台也在屏上")
        XCTAssertTrue(ws.isActive(b.id))
        XCTAssertFalse(ws.isActive(a.id))
    }

    func testSplitWithSingleTabLeavesNewPaneEmptyForNewTab() {
        let ws = MobileWorkspace()
        let a = termTab()
        ws.open(a)
        ws.split()
        XCTAssertEqual(ws.panes[0].tabIDs, [a.id])
        XCTAssertEqual(ws.panes[1].tabIDs, [])
        XCTAssertNil(ws.activeTab, "聚焦的是空的新格")
        let b = filesTab()
        ws.open(b)
        XCTAssertEqual(ws.panes[1].tabIDs, [b.id], "新标签开在聚焦格")
    }

    func testSplitIsCappedAtTwoPanes() {
        let ws = MobileWorkspace()
        [termTab(), termTab(), termTab()].forEach { ws.open($0) }
        ws.split()
        ws.split()
        XCTAssertEqual(ws.panes.count, MobileWorkspace.maxPanes)
    }

    func testClosingLastTabOfAPaneCollapsesSplit() {
        let ws = MobileWorkspace()
        let a = termTab(), b = filesTab()
        ws.open(a); ws.open(b)
        ws.split()
        ws.close(b.id)
        XCTAssertFalse(ws.isSplit)
        XCTAssertEqual(ws.panes[0].tabIDs, [a.id])
        XCTAssertEqual(ws.activeTab?.id, a.id, "焦点回到剩下那一格")
    }

    func testUnsplitMergesAndKeepsFocusedFront() {
        let ws = MobileWorkspace()
        let a = termTab(), b = termTab(), c = filesTab()
        [a, b, c].forEach { ws.open($0) }
        ws.split()                     // c → 右格
        ws.activate(a.id)              // 焦点回左格，前台 a
        ws.unsplit()
        XCTAssertFalse(ws.isSplit)
        XCTAssertEqual(ws.panes[0].tabIDs, [a.id, b.id, c.id])
        XCTAssertEqual(ws.activeTab?.id, a.id)
    }

    func testMoveToOtherPaneSplitsAndCollapsesEmptiedSource() {
        let ws = MobileWorkspace()
        let a = termTab(), b = filesTab()
        ws.open(a); ws.open(b)
        ws.moveToOtherPane(b.id)
        XCTAssertTrue(ws.isSplit)
        XCTAssertEqual(ws.panes[1].tabIDs, [b.id])
        XCTAssertEqual(ws.activeTab?.id, b.id)
        ws.moveToOtherPane(a.id)       // 左格只剩 a，挪走后左格空了 → 收起
        XCTAssertFalse(ws.isSplit)
        XCTAssertEqual(ws.panes[0].tabIDs, [b.id, a.id])
        XCTAssertEqual(ws.activeTab?.id, a.id)
    }

    func testExistingMatchesHostAndKind() {
        let ws = MobileWorkspace()
        let host = ServerProfile()
        let (term, _) = MobileFakeTerminal.tab(host: host, .idle)
        ws.open(.terminal(term))
        XCTAssertEqual(ws.existing(host: host.persistentModelID, kind: .terminal)?.id, term.id)
        XCTAssertNil(ws.existing(host: host.persistentModelID, kind: .sftp), "同主机的文件标签是另一种")
    }

    // MARK: - 拖到边上分屏

    func testDockFromSinglePaneSplitsTowardEdge() {
        let ws = MobileWorkspace()
        let a = termTab(), b = filesTab()
        ws.open(a); ws.open(b)
        ws.dock(b.id, to: .top)
        XCTAssertTrue(ws.isSplit)
        XCTAssertEqual(ws.splitAxis, .vertical)
        XCTAssertEqual(ws.panes[0].tabIDs, [b.id], "停到顶上 = 第一格")
        XCTAssertEqual(ws.panes[1].tabIDs, [a.id])
        XCTAssertEqual(ws.activeTab?.id, b.id)
    }

    func testDockLoneTabReordersAndReorientsPanes() {
        let ws = MobileWorkspace()
        let a = termTab(), b = filesTab()
        ws.open(a); ws.open(b)
        ws.dock(b.id, to: .trailing)             // a | b
        ws.splitFraction = 0.3
        ws.dock(b.id, to: .leading)              // b | a，比例跟着换边
        XCTAssertEqual(ws.panes.map(\.tabIDs), [[b.id], [a.id]])
        XCTAssertEqual(ws.splitFraction, 0.7, accuracy: 0.0001)
        ws.dock(a.id, to: .bottom)               // b 上 a 下
        XCTAssertEqual(ws.splitAxis, .vertical)
        XCTAssertEqual(ws.panes.map(\.tabIDs), [[b.id], [a.id]])
    }

    func testDockFromCrowdedPaneWhenSplitJoinsOtherPane() {
        let ws = MobileWorkspace()
        let a = termTab(), b = termTab(), c = filesTab()
        [a, b, c].forEach { ws.open($0) }
        ws.dock(c.id, to: .trailing)             // [a b] | [c]
        ws.dock(a.id, to: .leading)              // a 进另一格，那一格换到左边
        XCTAssertEqual(ws.panes.map(\.tabIDs), [[c.id, a.id], [b.id]])
        XCTAssertEqual(ws.activeTab?.id, a.id)
    }

    func testCannotDockOnlyTab() {
        let ws = MobileWorkspace()
        let a = termTab()
        ws.open(a)
        XCTAssertFalse(ws.canDock(a.id))
        ws.dock(a.id, to: .leading)
        XCTAssertFalse(ws.isSplit)
    }

    func testCollapsingSplitForgetsAxis() {
        let ws = MobileWorkspace()
        let a = termTab(), b = filesTab()
        ws.open(a); ws.open(b)
        ws.dock(b.id, to: .bottom)
        ws.close(b.id)
        XCTAssertNil(ws.splitAxis)
    }

    // MARK: - 转屏

    private let iPhonePortrait = CGSize(width: 402, height: 874)
    private let iPhoneLandscape = CGSize(width: 874, height: 402)
    private let iPhoneKeyboardUp = CGSize(width: 402, height: 520)
    private let iPadPortrait = CGSize(width: 820, height: 1180)

    func testPreferenceSurvivesRotationRoundTrip() {
        // 竖屏选了上下 → 转横屏放不下上下，临时左右 → 转回竖屏恢复上下。
        XCTAssertEqual(MobileWorkspace.effectiveAxis(preferred: .vertical, size: iPhonePortrait), .vertical)
        XCTAssertEqual(MobileWorkspace.effectiveAxis(preferred: .vertical, size: iPhoneLandscape), .horizontal)
        // 横屏选了左右 → 竖屏太窄，临时上下。
        XCTAssertEqual(MobileWorkspace.effectiveAxis(preferred: .horizontal, size: iPhoneLandscape), .horizontal)
        XCTAssertEqual(MobileWorkspace.effectiveAxis(preferred: .horizontal, size: iPhonePortrait), .vertical)
        // 宽高都够的 iPad 两种偏好都照办。
        XCTAssertEqual(MobileWorkspace.effectiveAxis(preferred: .vertical, size: iPadPortrait), .vertical)
        XCTAssertEqual(MobileWorkspace.effectiveAxis(preferred: .horizontal, size: iPadPortrait), .horizontal)
    }

    func testKeyboardDoesNotFlipStackedLayout() {
        XCTAssertEqual(MobileWorkspace.effectiveAxis(preferred: .vertical, size: iPhoneKeyboardUp), .vertical)
        XCTAssertEqual(MobileWorkspace.effectiveAxis(preferred: nil, size: iPhoneKeyboardUp), .vertical)
    }

    func testDockableEdgesFollowWhatFits() {
        XCTAssertEqual(Set(MobileWorkspace.dockableEdges(size: iPhonePortrait)), [.top, .bottom])
        XCTAssertEqual(Set(MobileWorkspace.dockableEdges(size: iPhoneLandscape)), [.leading, .trailing])
        XCTAssertEqual(Set(MobileWorkspace.dockableEdges(size: iPadPortrait)), [.leading, .trailing, .top, .bottom])
    }

    func testSplitGeometryKeepsPaneOrderAcrossAxes() {
        let wide = WorkspaceSplitGeometry(size: iPhoneLandscape, paneCount: 2, preferredAxis: .horizontal, fraction: 0.4)
        let tall = WorkspaceSplitGeometry(size: iPhonePortrait, paneCount: 2, preferredAxis: .horizontal, fraction: 0.4)
        XCTAssertEqual(wide.axis, .horizontal)
        XCTAssertEqual(tall.axis, .vertical)
        XCTAssertLessThan(wide.rects[0].minX, wide.rects[1].minX, "第一格在左")
        XCTAssertLessThan(tall.rects[0].minY, tall.rects[1].minY, "转竖屏后第一格在上")
        XCTAssertEqual(tall.rects[0].height, (874 * 0.4).rounded(), accuracy: 0.5)
    }

    // MARK: - 投放区

    func testDropTargets() {
        let ws = MobileWorkspace()
        let a = termTab(), b = filesTab()
        ws.open(a); ws.open(b)
        let size = iPadPortrait
        let one = WorkspaceSplitGeometry(size: size, paneCount: 1, preferredAxis: nil, fraction: 0.5)
        let strip: CGFloat = 64
        XCTAssertEqual(one.target(at: CGPoint(x: 20, y: 600), tabID: b.id, in: ws, stripHeight: strip), .edge(.leading))
        XCTAssertEqual(one.target(at: CGPoint(x: 410, y: 1170), tabID: b.id, in: ws, stripHeight: strip), .edge(.bottom))
        XCTAssertNil(one.target(at: CGPoint(x: 410, y: 30), tabID: b.id, in: ws, stripHeight: strip),
                     "刚在标签条上拎起时不算顶边")
        XCTAssertNil(one.target(at: CGPoint(x: 410, y: 600), tabID: b.id, in: ws, stripHeight: strip),
                     "中间落回自己那一格：什么也不变")

        ws.dock(b.id, to: .trailing)             // a | b
        let two = WorkspaceSplitGeometry(size: size, paneCount: 2, preferredAxis: ws.splitAxis, fraction: 0.5)
        XCTAssertEqual(two.target(at: CGPoint(x: 200, y: 600), tabID: b.id, in: ws, stripHeight: strip),
                       .pane(ws.panes[0].id), "拖进另一格中间 = 并入")
        XCTAssertNil(two.target(at: CGPoint(x: 810, y: 600), tabID: b.id, in: ws, stripHeight: strip),
                     "已经独占右边，拖到右边没有变化")
        XCTAssertEqual(two.target(at: CGPoint(x: 10, y: 600), tabID: b.id, in: ws, stripHeight: strip), .edge(.leading))
    }
}
