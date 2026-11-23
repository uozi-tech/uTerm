import SwiftData
import XCTest
@testable import uTerm

/// 终端窗口的 Code 模式：列哪台主机、每台主机一份连接、继续 / 新开会话开回本窗口的终端区。
@MainActor
final class CodeModeTests: XCTestCase {
    private func server(_ name: String) -> ServerProfile {
        let profile = ServerProfile()
        profile.name = name
        profile.host = "\(name).example.com"
        return profile
    }

    private func fakeConnection() -> AgentHistoryConnection {
        AgentHistoryConnection(history: AgentHistoryModel(
            source: AgentHistoryFakeSource(tool: .claude, sessions: []), preferredDirectory: nil))
    }

    // MARK: 继续 / 新开

    func testRunOpensNewTabWithTrackedCommand() throws {
        let workspace = WorkspaceModel()
        let host = UUID()
        let pane = try XCTUnwrap(CodeModeRouting.run("cd -- '/srv/app' && claude --resume 1", serverID: host,
                                                     title: "prod-web-01", in: workspace))
        XCTAssertEqual(workspace.terminalGroups.allTabs.count, 1)
        XCTAssertEqual(workspace.terminalGroups.activeTab?.payload.id, pane.id, "新标签页在前台")
        XCTAssertEqual(pane.serverProfileID, host)
        XCTAssertEqual(pane.tabTitle, "prod-web-01")
        XCTAssertEqual(pane.session.trackedRun?.command, "cd -- '/srv/app' && claude --resume 1",
                       "连上、行编辑器起来之后打进去")
        XCTAssertEqual(pane.session.trackedRun?.inSubshell, false, "不包子 shell：退出之后留在项目目录里")
        workspace.dispose()
    }

    // MARK: 列哪台主机

    func testServerFollowsActiveTerminalTab() {
        let workspace = WorkspaceModel()
        XCTAssertNil(CodeModeRouting.serverID(in: workspace, lastServerID: UUID()), "一个终端标签页都没有")
        let first = UUID(), second = UUID()
        workspace.openServer(profileID: first, title: "a")
        workspace.openServer(profileID: second, title: "b")
        XCTAssertEqual(CodeModeRouting.serverID(in: workspace, lastServerID: first), second, "活动标签页那台")
        XCTAssertNil(CodeModeRouting.directory(in: workspace, serverID: second), "shell 没报过当前目录")
        workspace.dispose()
    }

    // MARK: 每台主机一份连接

    func testConnectionsAreKeptPerHostAndEvicted() throws {
        var made: [String] = []
        let code = CodeModeModel { server, _ in
            made.append(server.name)
            return self.fakeConnection()
        }
        let container = try ModelContainer(for: Schema(ModelRegistry.types),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let hosts = (0..<(CodeModeModel.keptHosts + 1)).map { server("h\($0)") }

        let first = code.connection(for: hosts[0], directory: nil, container: container)
        XCTAssertTrue(code.connection(for: hosts[0], directory: "/x", container: container) === first,
                      "换回原来那台：同一份连接，选中的会话还在")
        for host in hosts.dropFirst() { _ = code.connection(for: host, directory: nil, container: container) }

        XCTAssertEqual(made, hosts.map(\.name))
        XCTAssertNil(code.connections[hosts[0].id], "最久没用的那台放掉")
        XCTAssertEqual(code.connections.count, CodeModeModel.keptHosts)

        code.close()
        XCTAssertTrue(code.connections.isEmpty)
    }

    func testRevealIsPerHostAndRepeatable() {
        let code = CodeModeModel()
        let a = UUID(), b = UUID()
        code.requestReveal(serverID: a, directory: "/srv/app")
        let firstRequest = code.reveal(for: a)
        XCTAssertEqual(firstRequest?.directory, "/srv/app")
        XCTAssertNil(code.reveal(for: b), "只对那台主机的列表起作用")

        code.requestReveal(serverID: a, directory: "/srv/app")
        XCTAssertNotEqual(code.reveal(for: a), firstRequest, "同一个目录再要一次也要再滚过去")

        code.requestReveal(serverID: a, directory: nil)
        XCTAssertNil(code.reveal(for: a), "不知道目录就只切过去")
    }
}
