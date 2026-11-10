import Network
import SwiftUI
import XCTest
@testable import uTermMobile

/// 工作区标签拖动：标签条里（含上下容差）只排序、不分屏；拖出标签条进到格子区域才走分屏判定。
/// 排序在条里实时让位，离开标签条 / 取消退回原位，只有在条里松手才改顺序。
@MainActor
final class MobileTabDragTests: XCTestCase {

    /// 机型：iPhone、Duo 折叠（外屏）、Duo 展开（标签条进状态行，条更高）。
    private struct Device {
        let name: String
        let size: CGSize
        let stripHeight: CGFloat
    }

    private static let devices = [
        Device(name: "iphone", size: CGSize(width: 402, height: 780), stripHeight: 48),
        Device(name: "duo-folded", size: CGSize(width: 466, height: 640), stripHeight: 48),
        Device(name: "duo-unfolded", size: CGSize(width: 669, height: 910), stripHeight: 82),
    ]

    private func termTab() -> MWorkTab {
        let (tab, _) = MobileFakeTerminal.tab(host: ServerProfile(), .idle)
        return .terminal(tab)
    }

    /// 一格四个标签，第一个在前台。
    private func workspace(_ count: Int = 4) -> (MobileWorkspace, [UUID]) {
        let ws = MobileWorkspace()
        let tabs = (0..<count).map { _ in termTab() }
        for tab in tabs { ws.open(tab) }
        ws.activate(tabs[0].id)
        return (ws, tabs.map(\.id))
    }

    /// 标签条贴在 `frame` 里，标签从左到右每个 90pt 宽、间隔 4pt，第一个从 x = 48（返回按钮之后）起。
    private func strip(_ frame: CGRect, ids: [UUID]) -> MStripFrame {
        var chips: [UUID: CGRect] = [:]
        for (i, id) in ids.enumerated() {
            chips[id] = CGRect(x: frame.minX + 48 + CGFloat(i) * 94, y: frame.minY + 7, width: 90, height: 30)
        }
        return MStripFrame(frame: frame, chips: chips)
    }

    private func geometry(_ ws: MobileWorkspace, _ size: CGSize) -> WorkspaceSplitGeometry {
        WorkspaceSplitGeometry(size: size, paneCount: ws.panes.count, preferredAxis: ws.splitAxis,
                               fraction: ws.splitFraction)
    }

    // MARK: - 判定

    /// 标签条里横着拖到两头（正是「停到左 / 右边」的区域）也只排序。
    func testDraggingWithinTheStripNeverSplits() {
        for device in Self.devices {
            let (ws, ids) = workspace()
            let pane = ws.panes[0].id
            let strips = [pane: strip(CGRect(x: 0, y: 0, width: device.size.width, height: device.stripHeight), ids: ids)]
            let layout = geometry(ws, device.size)
            func action(_ x: CGFloat, _ y: CGFloat) -> MTabDragAction? {
                WorkspaceTabDragResolver.action(at: CGPoint(x: x, y: y), tabID: ids[1], strips: strips, split: layout,
                                                in: ws, stripHeight: device.stripHeight)
            }
            let middle = device.stripHeight / 2
            XCTAssertEqual(action(4, middle), .reorder(index: 0), "\(device.name)：拖到最左只是排到第一")
            XCTAssertEqual(action(device.size.width - 4, middle), .reorder(index: 3), "\(device.name)：拖到最右排到最后")
            XCTAssertEqual(action(device.size.width - 4, device.stripHeight + 18), .reorder(index: 3),
                           "\(device.name)：手指往下晃出条外一点仍算在条里")
            XCTAssertEqual(action(4, -10), .reorder(index: 0), "\(device.name)：往上晃进状态栏也算")
            // 离开标签条进到格子靠边处才分屏：宽屏（Duo 展开）停到左边，窄屏只能上下分、停到上边。
            let wide = device.size.width >= MobileWorkspace.sideBySideMinWidth
            XCTAssertEqual(action(4, device.stripHeight + 40), .split(.edge(wide ? .leading : .top)),
                           "\(device.name)：离开标签条进到格子靠边处才分屏")
            XCTAssertEqual(action(device.size.width / 2, device.stripHeight + 30), .split(.edge(.top)),
                           "\(device.name)：刚出容差就是格子顶边")
            XCTAssertEqual(action(device.size.width / 2, device.size.height - 4), .split(.edge(.bottom)))
            XCTAssertNil(action(device.size.width / 2, device.size.height / 2), "\(device.name)：格子中间就是它自己那一格")
        }
    }

    func testInsertionIndexFollowsTheFingerAmongTheOtherTabs() {
        let (ws, ids) = workspace()
        let pane = ws.panes[0].id
        let strips = [pane: strip(CGRect(x: 0, y: 0, width: 402, height: 48), ids: ids)]
        let layout = geometry(ws, CGSize(width: 402, height: 780))
        // 拖第一个（x 48–138）：别的三个中线在 187、281、375。
        let expected: [(CGFloat, Int)] = [(60, 0), (186, 0), (188, 1), (280, 1), (300, 2), (380, 3)]
        for (x, index) in expected {
            XCTAssertEqual(WorkspaceTabDragResolver.action(at: CGPoint(x: x, y: 24), tabID: ids[0], strips: strips,
                                                           split: layout, in: ws, stripHeight: 48),
                           .reorder(index: index), "x = \(x)")
        }
    }

    /// 分屏时拖到另一格的标签条上：并进那一格、放到手指处；拖进那一格的正文：照旧并入。
    func testOtherPanesStripInsertsAtTheFinger() throws {
        let (ws, ids) = workspace()
        ws.moveToOtherPane(ids[3])   // 第二格只有 ids[3]
        ws.dock(ids[3], to: .bottom)
        let size = CGSize(width: 402, height: 780)
        let layout = geometry(ws, size)
        XCTAssertEqual(layout.axis, .vertical)
        let second = layout.rects[1]
        let strips = [ws.panes[0].id: strip(CGRect(x: 0, y: 0, width: 402, height: 48), ids: ws.panes[0].tabIDs),
                      ws.panes[1].id: strip(CGRect(x: 0, y: second.minY, width: 402, height: 48), ids: ws.panes[1].tabIDs)]
        func action(_ point: CGPoint) -> MTabDragAction? {
            WorkspaceTabDragResolver.action(at: point, tabID: ids[0], strips: strips, split: layout, in: ws,
                                            stripHeight: 48)
        }
        XCTAssertEqual(action(CGPoint(x: 60, y: second.minY + 24)), .insert(paneID: ws.panes[1].id, index: 0))
        XCTAssertEqual(action(CGPoint(x: 300, y: second.minY + 24)), .insert(paneID: ws.panes[1].id, index: 1))
        XCTAssertEqual(action(CGPoint(x: 200, y: second.midY)), .split(.pane(ws.panes[1].id)))
    }

    // MARK: - 实时让位与松手

    private let move: Animation? = nil

    func testReorderInStripMovesLiveAndCommitsOnDrop() {
        let (ws, ids) = workspace()
        let drag = WorkspaceTabDragTracker()
        drag.begin(ids[3])
        XCTAssertFalse(drag.isPlaceholder(ids[3]), "长按出菜单也会走到拎起：没进工作区前不留空位")

        drag.update(.reorder(index: 1), in: ws, move: move)
        XCTAssertEqual(ws.panes[0].tabIDs, [ids[0], ids[3], ids[1], ids[2]], "别的标签实时让位")
        XCTAssertTrue(drag.isPlaceholder(ids[3]))
        XCTAssertNil(drag.splitTarget, "排序不画分屏高亮")

        drag.drop(.reorder(index: 0), in: ws, move: move, land: nil)
        XCTAssertEqual(ws.panes[0].tabIDs, [ids[3], ids[0], ids[1], ids[2]])
        XCTAssertEqual(ws.activeTab?.id, ids[0], "正看着的标签不变")
        XCTAssertEqual(ws.panes.count, 1, "没分屏")
        XCTAssertFalse(drag.isPlaceholder(ids[3]))
    }

    func testLeavingTheStripPutsTheTabBackBeforeSplitting() {
        let (ws, ids) = workspace()
        let drag = WorkspaceTabDragTracker()
        drag.begin(ids[1])
        drag.update(.reorder(index: 3), in: ws, move: move)
        XCTAssertEqual(ws.panes[0].tabIDs, [ids[0], ids[2], ids[3], ids[1]])

        drag.update(.split(.edge(.trailing)), in: ws, move: move)
        XCTAssertEqual(ws.panes[0].tabIDs, ids, "离开标签条：先退回原位")
        XCTAssertEqual(drag.splitTarget, .edge(.trailing))

        drag.drop(.split(.edge(.trailing)), in: ws, move: move, land: nil)
        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertEqual(ws.panes[0].tabIDs, [ids[0], ids[2], ids[3]], "原格里的顺序没被这次拖动打乱")
        XCTAssertEqual(ws.panes[1].tabIDs, [ids[1]])
    }

    func testCancellingPutsTheTabBack() {
        let (ws, ids) = workspace()
        let drag = WorkspaceTabDragTracker()
        drag.begin(ids[0])
        drag.update(.reorder(index: 2), in: ws, move: move)
        drag.cancel(in: ws, move: move, land: nil)
        XCTAssertEqual(ws.panes[0].tabIDs, ids)
        XCTAssertFalse(drag.isPlaceholder(ids[0]))
        XCTAssertNil(drag.tabID)

        // 在不会有任何变化的地方松手（它自己那一格中间）：也退回。
        drag.begin(ids[0])
        drag.update(.reorder(index: 2), in: ws, move: move)
        drag.drop(nil, in: ws, move: move, land: nil)
        XCTAssertEqual(ws.panes[0].tabIDs, ids)
    }

    func testDropOnAnotherPanesStripInsertsThere() {
        let (ws, ids) = workspace()
        ws.moveToOtherPane(ids[3])
        ws.focus(pane: ws.panes[0].id)
        let target = ws.panes[1].id
        let drag = WorkspaceTabDragTracker()
        drag.begin(ids[1])
        drag.update(.insert(paneID: target, index: 0), in: ws, move: move)
        XCTAssertEqual(drag.splitTarget, .pane(target), "另一格的标签条：亮那一格")
        drag.drop(.insert(paneID: target, index: 0), in: ws, move: move, land: nil)
        XCTAssertEqual(ws.panes[1].tabIDs, [ids[1], ids[3]])
        XCTAssertEqual(ws.panes[0].tabIDs, [ids[0], ids[2]])
        XCTAssertEqual(ws.focusedPaneID, target)
    }

    // MARK: - 手动排序与 Mac 推来的顺序

    private func macClient() -> RemoteMacClient {
        RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                        identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
    }

    private func remoteSessions(_ ws: MobileWorkspace) -> [UUID?] {
        ws.tabs(in: ws.panes[0]).map { $0.terminal?.remote?.sessionID }
    }

    /// 手机上亲手排过这台 Mac 的标签：之后 Mac 推来的顺序不再覆盖，重新接管才恢复跟随。
    func testHandArrangedRemoteTabsAreNotOverriddenUntilTakenOverAgain() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let a = UUID(), b = UUID(), c = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [a, b, c], focus: a, order: [a, b, c]))
        let tabC = try XCTUnwrap(ws.existing(remote: MRemoteSource(client: client, sessionID: c))?.id)

        let drag = WorkspaceTabDragTracker()
        drag.begin(tabC)
        drag.update(.reorder(index: 0), in: ws, move: move)
        drag.drop(.reorder(index: 0), in: ws, move: move, land: nil)
        XCTAssertEqual(remoteSessions(ws), [c, a, b])
        XCTAssertTrue(ws.isArrangedByHand(client))

        _ = ws.follow(client, sessionIDs: [b, a, c], order: [b, a, c])
        XCTAssertEqual(remoteSessions(ws), [c, a, b], "Mac 上重排不再覆盖手机上的排法")
        let d = UUID()
        _ = ws.follow(client, sessionIDs: [b, a, c, d], order: [b, a, c, d])
        XCTAssertEqual(remoteSessions(ws), [c, a, b, d], "新开的照常接上，排在末尾")

        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [b, a, c, d], focus: a, order: [b, a, c, d]))
        XCTAssertFalse(ws.isArrangedByHand(client))
        XCTAssertEqual(remoteSessions(ws), [b, a, c, d], "重新接管：回到 Mac 上的顺序")
    }

    /// 拖了却放回原位、或只拖了别的标签：不算亲手排过。
    func testDroppingBackInPlaceDoesNotStopFollowingTheMac() throws {
        let ws = MobileWorkspace()
        let client = macClient()
        let a = UUID(), b = UUID()
        _ = ws.takeOver(MRemoteTakeover(client: client, sessionIDs: [a, b], focus: a, order: [a, b]))
        let tabA = try XCTUnwrap(ws.existing(remote: MRemoteSource(client: client, sessionID: a))?.id)
        let drag = WorkspaceTabDragTracker()
        drag.begin(tabA)
        drag.update(.reorder(index: 1), in: ws, move: move)
        drag.drop(.reorder(index: 0), in: ws, move: move, land: nil)
        XCTAssertFalse(ws.isArrangedByHand(client))

        let direct = termTab()
        ws.open(direct)
        drag.begin(direct.id)
        drag.drop(.reorder(index: 0), in: ws, move: move, land: nil)
        XCTAssertFalse(ws.isArrangedByHand(client), "直连标签挪位置只是换了格子，这台 Mac 的标签相对顺序没变")
        _ = ws.follow(client, sessionIDs: [b, a], order: [b, a])
        XCTAssertEqual(ws.tabs(in: ws.panes[0]).map { $0.terminal?.remote?.sessionID }, [nil, b, a])
    }
}
