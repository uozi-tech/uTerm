import XCTest
@testable import uTerm

/// 注册表里的 title 给 CLI 和手机列表用，必须是稳定的名字；shell 设的标题只上标签。
@MainActor
final class RegistryTitleIsolationTests: XCTestCase {

    func testShellTitleDoesNotReachRegistryThroughSync() async {
        let registry = TerminalSessionRegistry()
        let workspace = WorkspaceModel()
        workspace.attachSessionRegistry(registry, windowID: UUID(), windowKind: TerminalWindowKind.workspace)
        let tabID = workspace.openServer(profileID: UUID(), title: "生产 web")
        let pane = workspace.terminalGroups.allTabs.first { $0.id == tabID }!.payload
        workspace.sessionRegistrar?.register(paneID: pane.id, serverID: pane.serverProfileID,
                                             serverName: "prod-1", session: pane.session)

        pane.session.terminalView.feed(text: "\u{1b}]0;vim secrets.env\u{07}")
        XCTAssertEqual(pane.session.shellTitle, "vim secrets.env")
        workspace.syncTerminalTitles()
        workspace.syncFocusedTerminalSession()

        XCTAssertEqual(registry.snapshots().first?.title, "生产 web")
        XCTAssertEqual(registry.snapshots().first?.serverName, "prod-1")
    }
}
