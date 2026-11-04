import UPaneGroups
import UPaneTree
import XCTest
@testable import uTerm

/// 终端区改用 `UPaneGroups`（VSCode 编辑组模型）之后，`TabModel` 与
/// `TabModelTests` 一并删除 —— 分屏树本身的 open/close/move/reorder/collapse
/// 已由 uAppKit 的 `UPaneGroupsTests` 覆盖。这里只钉 **uTerm 侧的接线**：
/// 三个钩子（会话释放 / 克隆 / 分屏种子）与 policy 的取值。
@MainActor
final class TerminalGroupsTests: XCTestCase {

    // MARK: policy

    /// `keepAlive` 是本次改造里唯一还悬着的参数，必须是一处常量。
    /// **暂定 `.activeTabPerGroup`，待 Release 构建复测**（上一轮「隐藏终端在全速
    /// 重绘」的结论跑的是 Debug 构建）。复测若翻案，改
    /// `TerminalPaneAreaTuning.keepAlive` 一行即可，这条断言跟着改。
    func testKeepAlivePolicyIsPinnedToSingleConstant() {
        let ws = WorkspaceModel()
        XCTAssertEqual(ws.terminalGroups.policy.keepAlive, TerminalPaneAreaTuning.keepAlive)
        XCTAssertEqual(TerminalPaneAreaTuning.keepAlive, .activeTabPerGroup)
    }

    /// 终端区一向不限分屏组数（uTable 才有 3 组封顶）；最后一个组允许为空，
    /// 那就是「没有打开的终端标签」空态。
    func testSplitIsUncappedAndLastGroupMayBeEmpty() {
        let ws = WorkspaceModel()
        XCTAssertNil(ws.terminalGroups.policy.splitButtonMaxGroups)
        XCTAssertTrue(ws.terminalGroups.policy.collapsesEmptyGroups)
        XCTAssertTrue(ws.terminalGroups.policy.allowsLastGroupEmpty)

        let server = UUID()
        ws.openServer(profileID: server, title: "a")
        for _ in 0..<4 { ws.splitActiveGroup(direction: .horizontal) }
        XCTAssertEqual(ws.terminalGroups.groupCount, 5)
    }

    // MARK: 钩子

    /// `onTabRemoved` = 旧的 `pane.dispose()`：关标签就关会话。
    func testClosingTabDisposesItsSession() {
        let ws = WorkspaceModel()
        let tabID = ws.openServer(profileID: UUID(), title: "a")
        guard let at = ws.terminalGroups.locateTab(tabID),
              let pane = ws.terminalGroups.tab(tabID)?.payload else {
            XCTFail("tab should live in a group")
            return
        }
        ws.terminalGroups.closeTab(groupID: at.groupID, index: at.index)

        XCTAssertNil(ws.terminalGroups.tab(tabID))
        // `TerminalSession.dispose()` 解开终端视图的 delegate 并丢掉 backend；
        // connectionState 是异步 close 才改的，所以判据取前者。
        XCTAssertNil(pane.session.terminalView.terminalDelegate)
    }

    /// 关一个**文件**标签不能释放 buffer —— buffer 归 `FilePreviewModel` 所有，
    /// `PaneModel.dispose()` 自带 `fileBuffer == nil` 守卫。
    func testClosingFileTabKeepsBufferAlive() {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "a")
        let buffer = FileBuffer(remotePath: "/tmp/readme.md", kind: .markdown)
        guard let groupID = ws.terminalGroups.activeGroupID else {
            XCTFail("workspace should have a group")
            return
        }
        XCTAssertTrue(ws.dropFileBuffer(buffer, ontoGroup: groupID, zone: .center))
        guard let fileTab = ws.terminalGroups.allTabs.first(where: {
            $0.payload.fileBuffer?.id == buffer.id
        }), let at = ws.terminalGroups.locateTab(fileTab.id) else {
            XCTFail("file tab should exist")
            return
        }

        ws.terminalGroups.closeTab(groupID: at.groupID, index: at.index)

        XCTAssertNil(ws.terminalGroups.allTabs.first { $0.payload.fileBuffer?.id == buffer.id })
        XCTAssertFalse(buffer.isDirty, "buffer 本身不该被这次关闭动过")
    }

    /// `cloneTab` 的文件分支：克隆的是**同一个** buffer 的引用，不是新建一份
    /// （对齐旧的 `insertPane(copying:)`）。
    func testCloningFileTabSharesTheSameBuffer() {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "a")
        let buffer = FileBuffer(remotePath: "/tmp/readme.md", kind: .markdown)
        guard let groupID = ws.terminalGroups.activeGroupID else {
            XCTFail("workspace should have a group")
            return
        }
        // 把终端标签关掉，让文件标签成为该组里唯一的标签。
        XCTAssertTrue(ws.dropFileBuffer(buffer, ontoGroup: groupID, zone: .center))
        ws.terminalGroups.closeTab(groupID: groupID, index: 0)
        guard let only = ws.terminalGroups.groups[groupID]?.tabs.first else {
            XCTFail("file tab should be the only tab left")
            return
        }

        ws.terminalGroups.moveTab(only.id, toGroup: groupID, zone: .trailing)

        let fileTabs = ws.terminalGroups.allTabs.filter { $0.payload.fileBuffer != nil }
        XCTAssertEqual(fileTabs.count, 2)
        XCTAssertTrue(fileTabs.allSatisfy { $0.payload.fileBuffer === buffer })
    }

    /// `makeTabForNewGroup`：没有活动标签（区域空掉）时回落到本窗口绑定的服务器。
    /// 没绑定过就返回 nil —— 开一个空组，而不是造一个指向随机 UUID 的死终端。
    func testSplitOnEmptyAreaUsesBoundServerAndOpensEmptyGroupWithout() {
        let bare = WorkspaceModel()
        bare.splitActiveGroup(direction: .horizontal)
        XCTAssertEqual(bare.terminalGroups.groupCount, 2)
        XCTAssertTrue(bare.terminalGroups.isEmpty, "没有绑定服务器时开空组，不造死终端")

        let bound = WorkspaceModel()
        let server = UUID()
        bound.bindDefaultServer(id: server, title: "prod")
        bound.splitActiveGroup(direction: .horizontal)
        XCTAssertEqual(bound.terminalGroups.allTabs.count, 1)
        XCTAssertEqual(bound.terminalGroups.activeTab?.payload.serverProfileID, server)
        XCTAssertEqual(bound.terminalGroups.activeTab?.payload.tabTitle, "prod")
    }

    // MARK: ⌘W

    /// 空组在终端区其实**几乎开不出来**：`makeTabForNewGroup` 只要拿得到服务器就
    /// 会往新组里塞一条会话，而组丢掉最后一个标签就塌缩。唯一的口子是「既没有活动
    /// 标签、也没绑定服务器」——这条钉的就是那个口子：⌘W 要能把空组收掉，否则唯一
    /// 的出路是拖个标签进来再关。
    func testCloseActiveTabCollapsesEmptySplitGroup() {
        let ws = WorkspaceModel()
        ws.splitActiveGroup(direction: .horizontal)
        XCTAssertEqual(ws.terminalGroups.groupCount, 2)
        XCTAssertNil(ws.terminalGroups.activeTab)
        guard case .closeTerminalActiveTab = ws.closeIntent(focusedRegion: .terminal) else {
            XCTFail("空的分屏组应当是 ⌘W 的目标")
            return
        }

        XCTAssertTrue(ws.closeActiveTerminalTab())
        XCTAssertEqual(ws.terminalGroups.groupCount, 1)
    }

    /// 树里只剩一个空组时，⌘W 在终端区没东西可关，回落到关窗口。
    func testCloseIntentFallsBackToWindowWhenAreaHasOnlyOneEmptyGroup() {
        let ws = WorkspaceModel()
        XCTAssertEqual(ws.closeIntent(focusedRegion: .terminal), .closeWindow)
    }

    /// 分屏出来的新组里应当是一条**新会话**，不是空组（终端没有「空组占位」这种
    /// 有意义的状态，那只会多一次点击）。
    func testSplitWithActiveTabNeverLeavesAnEmptyGroup() {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "a")
        ws.splitActiveGroup(direction: .horizontal)
        XCTAssertEqual(ws.terminalGroups.groupCount, 2)
        XCTAssertNotNil(ws.terminalGroups.activeTab)
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 2)
    }
}
