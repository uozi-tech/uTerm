import UPaneGroups
import UPaneTree
import XCTest
@testable import uTerm

/// 一台主机只开一个 Code 标签页（整个 App；这台 Mac 的所有本机终端窗口算一台，同 iOS 的 `MobileWorkspace.existingHistory`）：
/// 再开就切到已有的那个（在别的窗口里的连窗口带到前台），要了目录的同新开时一样记成「新会话」的目录、列表定位过去，
/// 右边正跑着的会话不动。这条规则之前存下的布局里一台主机有几个的照原样接回、一个不关，之后再开切到第一个。
///
/// 不起真 shell / 真 SSH：本机的 shell 不启动，SSH 的窗格不连。
@MainActor
final class CodeTabSingleTests: XCTestCase {
    private static let shop = "/Users/me/shop"
    private static let blog = "/Users/me/blog"
    private let registry = TerminalSessionRegistry()

    private func localModel(windowID: UUID = UUID()) -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { _ in })
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: windowID,
                                              windowKind: TerminalWindowKind.terminal))
        return model
    }

    private func workspace(windowID: UUID = UUID(), kind: String = TerminalWindowKind.terminal) -> WorkspaceModel {
        let workspace = WorkspaceModel()
        workspace.attachSessionRegistry(registry, windowID: windowID, windowKind: kind)
        return workspace
    }

    private func codeTabs(_ model: LocalShellWindowModel) -> [UUID] {
        model.groups.allTabs.filter { $0.payload.codeTab != nil }.map(\.id)
    }

    private func codeTabs(_ workspace: WorkspaceModel, host: UUID? = nil) -> [UUID] {
        workspace.terminalGroups.allTabs
            .filter { $0.payload.codeTab != nil && (host == nil || $0.payload.serverProfileID == host) }
            .map(\.id)
    }

    // MARK: 本机终端窗口

    func testLocalSecondOpenFocusesTheExistingCodeTabAndTakesTheDirectory() throws {
        let model = localModel()
        model.addTab(directory: Self.shop)
        let codeID = model.openCodeTab(in: model.groups.activeGroupID)
        let code = try XCTUnwrap(model.groups.tab(codeID)?.payload.codeTab)
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: Self.shop))
        XCTAssertEqual(code.detail, .terminal(run.id))

        // 从另一个 shell（在别的目录）再按一次 Code。
        model.addTab(directory: Self.blog)
        XCTAssertNotEqual(model.active?.id, codeID)
        XCTAssertEqual(model.openCodeTab(in: model.groups.activeGroupID), codeID, "已经有了：切过去，不再开")
        XCTAssertEqual(codeTabs(model), [codeID])
        XCTAssertEqual(model.active?.id, codeID)
        XCTAssertEqual(code.newSessionDirectory, Self.blog, "要的目录同新开时一样记成「新会话」的目录")
        XCTAssertEqual(code.reveal?.directory, Self.blog, "列表定位到那个目录")
        XCTAssertEqual(code.detail, .terminal(run.id), "右边正跑着的会话不动")
        XCTAssertEqual(code.runs.map(\.id), [run.id])

        // 直接带目录开（命令面板、「在这里打开 Code」）同理；不带目录只是切过去。
        XCTAssertEqual(model.openCodeTab(directory: Self.shop), codeID)
        XCTAssertEqual(code.newSessionDirectory, Self.shop)
        let reveal = code.reveal
        XCTAssertEqual(model.openCodeTab(directory: nil), codeID)
        XCTAssertEqual(code.newSessionDirectory, Self.shop, "不知道目录就不动")
        XCTAssertEqual(code.reveal, reveal)

        // 前台就是这个 Code 标签页时再按：只是停在这里，不拿它自己记着的目录再定位一次列表。
        XCTAssertEqual(model.openCodeTab(in: model.groups.activeGroupID), codeID)
        XCTAssertEqual(code.reveal, reveal)
        XCTAssertEqual(codeTabs(model), [codeID])
        model.disposeAll()
    }

    func testLocalOpenFromAnotherGroupFocusesTheCodeTabWhereItIs() throws {
        let model = localModel()
        let left = model.addTab(directory: Self.shop)
        let codeID = model.openCodeTab(directory: Self.shop)
        let codeGroup = try XCTUnwrap(model.groups.locateTab(codeID)?.groupID)
        model.splitActiveGroup(direction: .horizontal)
        let otherGroup = try XCTUnwrap(model.groups.activeGroupID)
        XCTAssertNotEqual(otherGroup, codeGroup)

        XCTAssertEqual(model.openCodeTab(in: otherGroup), codeID, "标签条上的 Code 按钮在哪个组按都切到那一个")
        XCTAssertEqual(codeTabs(model), [codeID])
        XCTAssertEqual(model.groups.activeGroupID, codeGroup)
        XCTAssertEqual(model.active?.id, codeID)

        // 右键「历史会话…」同一条规则。
        let shell = try XCTUnwrap(model.groups.tab(left)?.payload)
        model.groups.activateTab(groupID: codeGroup, index: 0)
        model.showCodeTab(for: shell)
        XCTAssertEqual(codeTabs(model), [codeID])
        XCTAssertEqual(model.active?.id, codeID)
        model.disposeAll()
    }

    func testLocalCodeTabIsNotClonedWhenDraggedToItsOwnGroupEdge() throws {
        let model = localModel()
        model.addTab()
        let codeID = model.openCodeTab(directory: Self.shop)
        let group = try XCTUnwrap(model.groups.locateTab(codeID)?.groupID)
        model.groups.moveTab(codeID, toGroup: group, zone: .trailing)
        let codeGroup = try XCTUnwrap(model.groups.locateTab(codeID)?.groupID)
        XCTAssertEqual(model.groups.groups[codeGroup]?.tabs.count, 1, "先挪成单独一组")

        // 组里唯一的标签拖到本组边缘本来要克隆一份：Code 标签页不克隆。
        model.groups.moveTab(codeID, toGroup: codeGroup, zone: .trailing)
        XCTAssertEqual(codeTabs(model), [codeID])
        XCTAssertEqual(model.groups.groups.count, 2)
        model.disposeAll()
    }

    func testAnotherLocalWindowFocusesTheCodeTabInTheFirstWindow() throws {
        let firstWindow = UUID()
        let first = localModel(windowID: firstWindow)
        first.addTab(directory: Self.shop)
        let codeID = first.openCodeTab(directory: Self.shop)
        let code = try XCTUnwrap(first.groups.tab(codeID)?.payload.codeTab)
        first.addTab()

        let second = localModel()
        second.addTab(directory: Self.blog)
        XCTAssertEqual(second.openCodeTab(in: second.groups.activeGroupID), codeID, "本机算一台：切到另一个窗口里的那个")
        XCTAssertTrue(codeTabs(second).isEmpty, "这个窗口不另开")
        XCTAssertEqual(first.active?.id, codeID, "那个窗口里切过去")
        XCTAssertEqual(code.newSessionDirectory, Self.blog)
        XCTAssertEqual(code.reveal?.directory, Self.blog)

        // SSH 主机的 Code 标签页不算本机的。
        let ssh = workspace()
        let sshCodeID = ssh.openCodeTab(serverID: UUID(), hostName: "prod-web-01", directory: nil)
        XCTAssertNotEqual(sshCodeID, codeID)
        XCTAssertEqual(codeTabs(ssh).count, 1)

        // 那个窗口关了：这里自己开。
        first.disposeAll()
        registry.forgetWindow(firstWindow)
        let reopened = second.openCodeTab(in: second.groups.activeGroupID)
        XCTAssertEqual(codeTabs(second), [reopened])
        XCTAssertNotEqual(reopened, codeID)
        second.disposeAll()
        ssh.dispose()
    }

    // MARK: SSH

    func testWorkspaceOpensOneCodeTabPerHost() throws {
        let workspace = workspace()
        let web = UUID(), db = UUID()
        let names = [web: "prod-web-01", db: "prod-db-01"]
        let webTerminal = workspace.openServer(profileID: web, title: "prod-web-01")
        let webCode = workspace.openCodeTab(fallbackServerID: web) { names[$0] ?? "" }
        let code = try XCTUnwrap(workspace.terminalGroups.tab(webCode)?.payload.codeTab)
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: "/srv/shop"))

        workspace.openServer(profileID: db, title: "prod-db-01")
        let dbCode = workspace.openCodeTab(fallbackServerID: web) { names[$0] ?? "" }
        XCTAssertNotEqual(dbCode, webCode, "另一台主机：另开一个")
        XCTAssertEqual(workspace.terminalGroups.tab(dbCode)?.payload.serverProfileID, db)

        let group = try XCTUnwrap(workspace.terminalGroups.locateTab(webTerminal))
        workspace.terminalGroups.activateTab(groupID: group.groupID, index: group.index)
        XCTAssertEqual(workspace.openCodeTab(fallbackServerID: web) { names[$0] ?? "" }, webCode, "同一台：切过去")
        XCTAssertEqual(workspace.openCodeTab(serverID: web, hostName: "prod-web-01", directory: "/srv/blog"), webCode)
        XCTAssertEqual(codeTabs(workspace, host: web), [webCode])
        XCTAssertEqual(codeTabs(workspace).count, 2)
        XCTAssertEqual(workspace.terminalGroups.activeTab?.id, webCode)
        XCTAssertEqual(code.newSessionDirectory, "/srv/blog")
        XCTAssertEqual(code.reveal?.directory, "/srv/blog")
        XCTAssertEqual(code.runs.map(\.id), [run.id], "右边正跑着的会话不动")

        // 右键「历史会话…」、拖到本组边缘同一条规则。
        let webPane = try XCTUnwrap(workspace.terminalGroups.tab(webTerminal)?.payload)
        workspace.showCodeTab(for: webPane, hostName: "prod-web-01")
        XCTAssertEqual(codeTabs(workspace, host: web), [webCode])
        let codeGroup = try XCTUnwrap(workspace.terminalGroups.locateTab(webCode)?.groupID)
        workspace.terminalGroups.moveTab(webCode, toGroup: codeGroup, zone: .trailing)
        let alone = try XCTUnwrap(workspace.terminalGroups.locateTab(webCode)?.groupID)
        workspace.terminalGroups.moveTab(webCode, toGroup: alone, zone: .trailing)
        XCTAssertEqual(codeTabs(workspace, host: web), [webCode], "不克隆")
        workspace.dispose()
    }

    func testCodeTabForAHostInAnotherWindowIsFocusedThere() throws {
        let web = UUID(), db = UUID()
        let first = workspace(kind: TerminalWindowKind.workspace)
        first.openServer(profileID: web, title: "prod-web-01")
        let webCode = first.openCodeTab(serverID: web, hostName: "prod-web-01", directory: "/srv/shop")
        let code = try XCTUnwrap(first.terminalGroups.tab(webCode)?.payload.codeTab)
        first.openServer(profileID: web, title: "prod-web-01")

        let second = workspace()
        second.openServer(profileID: web, title: "prod-web-01")
        XCTAssertEqual(second.openCodeTab(serverID: web, hostName: "prod-web-01", directory: "/srv/blog"), webCode,
                       "整个 App 一台主机一个：切到别的窗口里的那个")
        XCTAssertTrue(codeTabs(second).isEmpty)
        XCTAssertEqual(first.terminalGroups.activeTab?.id, webCode)
        XCTAssertEqual(code.newSessionDirectory, "/srv/blog")

        second.openServer(profileID: db, title: "prod-db-01")
        let dbCode = second.openCodeTab(serverID: db, hostName: "prod-db-01", directory: nil)
        XCTAssertEqual(codeTabs(second, host: db), [dbCode], "别的主机在这个窗口开")

        // 那个窗口关了：这里自己开。
        first.dispose()
        let reopened = second.openCodeTab(serverID: web, hostName: "prod-web-01", directory: nil)
        XCTAssertNotEqual(reopened, webCode)
        XCTAssertEqual(codeTabs(second, host: web), [reopened])
        second.dispose()
    }

    // MARK: 这条规则之前存下的布局

    func testLegacyLocalLayoutWithTwoCodeTabsComesBackWhole() throws {
        let shell = UUID(), runA = UUID(), runB = UUID(), codeA = UUID(), codeB = UUID()
        func record(_ id: UUID, run: UUID, directory: String) -> CodeTabRecord {
            CodeTabRecord(id: id, directory: directory,
                          runs: [CodeRunRecord(session: run, tool: .claude, sessionID: nil, directory: directory,
                                               startedAt: Date())])
        }
        let layout = HeldSessionLayout(
            revision: 1,
            tree: UPaneGroupsSnapshot(root: .leaf(groupIndex: 0),
                                      groups: [.init(tabs: [shell, codeA, codeB], activeIndex: 0)], activeGroupIndex: 0),
            codeTabs: [record(codeA, run: runA, directory: Self.shop), record(codeB, run: runB, directory: Self.blog)])
        let model = localModel()
        model.adopt([(shell, 1), (runA, 2), (runB, 3)], layout: layout)
        XCTAssertEqual(codeTabs(model), [codeA, codeB], "两个都接回，不合并、不关")
        let a = try XCTUnwrap(model.groups.tab(codeA)?.payload.codeTab)
        let b = try XCTUnwrap(model.groups.tab(codeB)?.payload.codeTab)
        XCTAssertEqual(a.runs.map(\.id), [runA])
        XCTAssertEqual(b.runs.map(\.id), [runB])

        XCTAssertEqual(model.openCodeTab(in: model.groups.activeGroupID), codeA, "再开：切到第一个")
        XCTAssertEqual(model.openCodeTab(directory: Self.blog), codeA)
        XCTAssertEqual(codeTabs(model), [codeA, codeB])
        XCTAssertEqual(b.runs.map(\.id), [runB], "第二个里的会话照旧跑着")
        XCTAssertFalse(try XCTUnwrap(model.pane(runB)).isDisposed)
        XCTAssertEqual(b.newSessionDirectory, Self.blog)

        let other = localModel()
        other.addTab()
        XCTAssertEqual(other.openCodeTab(in: other.groups.activeGroupID), codeA, "别的本机终端窗口也切到第一个")
        XCTAssertTrue(codeTabs(other).isEmpty)
        other.disposeAll()
        model.disposeAll()
    }

    func testLegacySSHLayoutWithTwoCodeTabsForOneHostComesBackWhole() throws {
        let host = UUID(), terminal = UUID(), runA = UUID(), runB = UUID(), codeA = UUID(), codeB = UUID()
        func record(_ id: UUID, run: UUID) -> CodeTabRecord {
            CodeTabRecord(id: id, host: host, hostName: "prod-web-01", directory: "/srv/shop",
                          runs: [CodeRunRecord(session: run, tool: .codex, sessionID: nil, directory: "/srv/shop",
                                               startedAt: Date())])
        }
        let layout = HeldSessionLayout(
            revision: 1,
            tree: UPaneGroupsSnapshot(root: .leaf(groupIndex: 0),
                                      groups: [.init(tabs: [terminal, codeA, codeB], activeIndex: 0)], activeGroupIndex: 0),
            codeTabs: [record(codeA, run: runA), record(codeB, run: runB)])
        let sessions = [terminal, runA, runB].enumerated().map { index, id in
            SSHSessionRestorer.Session(id: id, serverID: host, title: "prod-web-01", order: Double(index), layout: layout)
        }
        let workspace = workspace()
        workspace.adoptHeldSessions(sessions, knownServerIDs: [host])
        let restored = codeTabs(workspace, host: host)
        XCTAssertEqual(restored.count, 2, "两个都接回，不合并、不关")
        XCTAssertEqual(Set(workspace.terminalPanes.map(\.id)), [terminal, runA, runB], "一个会话都不丢")

        XCTAssertEqual(workspace.openCodeTab(serverID: host, hostName: "prod-web-01", directory: nil), restored.first,
                       "再开：切到第一个")
        XCTAssertEqual(codeTabs(workspace, host: host), restored)
        XCTAssertEqual(Set(workspace.terminalPanes.map(\.id)), [terminal, runA, runB])
        workspace.dispose()
    }
}
