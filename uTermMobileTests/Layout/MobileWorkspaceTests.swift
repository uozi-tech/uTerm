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
