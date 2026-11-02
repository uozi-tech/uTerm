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
}
