import XCTest
@testable import uTerm

/// 终端标签的标题 → 跨窗口注册表（CLI `terminals` 那一列 `title`）的接线。
///
/// 从前 `title` 恒等于服务器名，`TerminalSessionRegistry.update(id:title:)` 一个
/// 生产调用方都没有 —— 技能文档却写着 title 是「当前目录与提示符信息」，纯属虚构。
/// 现在 title = 标签打开时定下的名字（`PaneModel.tabTitle`），没有才回落服务器名。
/// shell 设的标题（`TerminalSession.shellTitle`）只上标签，不进注册表。
@MainActor
final class WorkspaceTerminalTitleTests: XCTestCase {

    private func makeWorkspace(
        _ registry: TerminalSessionRegistry
    ) -> WorkspaceModel {
        let workspace = WorkspaceModel()
        workspace.attachSessionRegistry(
            registry, windowID: UUID(), windowKind: TerminalWindowKind.workspace)
        return workspace
    }

    /// 登记时就取标签的名字。
    func testRegistrationUsesTabTitle() {
        let registry = TerminalSessionRegistry()
        let workspace = makeWorkspace(registry)
        let tabID = workspace.openServer(profileID: UUID(), title: "生产 web")
        let pane = workspace.terminalGroups.allTabs.first { $0.id == tabID }!.payload

        workspace.sessionRegistrar?.register(
            paneID: pane.id, serverID: pane.serverProfileID,
            serverName: "prod-1", session: pane.session)

        XCTAssertEqual(registry.snapshots().first?.title, "生产 web")
        // serverName 仍是主机名，两者各司其职。
        XCTAssertEqual(registry.snapshots().first?.serverName, "prod-1")
    }

    /// 登记发生在窗格进标签树**之前**（窗口视图的 `.task` 与窗格建连谁先跑
    /// SwiftUI 不保证）时，`syncTerminalTitles()` 事后把真标题补上去。
    func testSyncTerminalTitlesPushesTitleChangeAfterRegistration() {
        let registry = TerminalSessionRegistry()
        let workspace = makeWorkspace(registry)
        let pane = PaneModel(serverProfileID: UUID(), tabTitle: "生产 web")
        pane.registrar = workspace.sessionRegistrar

        workspace.sessionRegistrar?.register(
            paneID: pane.id, serverID: pane.serverProfileID,
            serverName: "prod-1", session: pane.session)
        XCTAssertEqual(registry.snapshots().first?.title, "prod-1")

        workspace.terminalGroups.openTab({
            TerminalTab(payload: pane)
        })
        workspace.syncTerminalTitles()

        XCTAssertEqual(registry.snapshots().first?.title, "生产 web")
    }

    /// 切前台标签也顺手同步一次（`TerminalRegistryBinding` 的 `onChange` 走这条）。
    func testSyncFocusedTerminalSessionAlsoSyncsTitles() {
        let registry = TerminalSessionRegistry()
        let workspace = makeWorkspace(registry)
        let pane = PaneModel(serverProfileID: UUID(), tabTitle: "生产 web")
        pane.registrar = workspace.sessionRegistrar
        workspace.sessionRegistrar?.register(
            paneID: pane.id, serverID: pane.serverProfileID,
            serverName: "prod-1", session: pane.session)
        workspace.terminalGroups.openTab({ TerminalTab(payload: pane) })

        workspace.syncFocusedTerminalSession()

        XCTAssertEqual(registry.snapshots().first?.title, "生产 web")
    }

    /// 没有标签名时回落服务器名，不会被同步成空。
    func testTabWithoutTitleKeepsServerName() {
        let registry = TerminalSessionRegistry()
        let workspace = makeWorkspace(registry)
        let pane = PaneModel(serverProfileID: UUID())
        pane.registrar = workspace.sessionRegistrar
        workspace.sessionRegistrar?.register(
            paneID: pane.id, serverID: pane.serverProfileID,
            serverName: "prod-1", session: pane.session)
        workspace.terminalGroups.openTab({ TerminalTab(payload: pane) })

        workspace.syncTerminalTitles()

        XCTAssertEqual(registry.snapshots().first?.title, "prod-1")
    }
}
