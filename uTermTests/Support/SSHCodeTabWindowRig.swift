import Foundation
import UPaneGroups
@testable import uTerm

/// 一个 SSH 主机的工作区 / 终端窗口（真的 `WorkspaceModel`，同窗口视图那样接到注册表上），不连真主机：终端标签页与
/// Code 标签页里的会话都接假后端（`MockBackend`），连上后照 `PaneModel.connect` 那样登记（没走真连接就没有主机名可登记）。
/// 远控 63 / 64 号消息、Mac 上结束会话（8 号）的测试用。
@MainActor
final class SSHCodeTabWindowRig {
    let workspace = WorkspaceModel()
    let windowID = UUID()
    let host: UUID
    let hostName: String
    private(set) var backends: [UUID: MockBackend] = [:]

    init(registry: TerminalSessionRegistry, host: UUID = UUID(), hostName: String = "prod-web",
         kind: String = TerminalWindowKind.terminal) {
        self.host = host
        self.hostName = hostName
        workspace.connectCodeRun = { [weak self] pane in self?.connect(pane) }
        workspace.attachSessionRegistry(registry, windowID: windowID, windowKind: kind)
    }

    /// 一个连着这台主机的终端标签页，等它登记。返回会话 id（`PaneModel.id`）。
    func openTerminal() async -> UUID? {
        let tabID = workspace.openServer(profileID: host, title: hostName)
        guard let pane = workspace.terminalGroups.tab(tabID)?.payload else { return nil }
        connect(pane)
        return await waitUntil { self.isRegistered(pane.id) } ? pane.id : nil
    }

    /// 这台主机的 Code 标签页（开好、接上假的记录列表）。返回报给设备的 id（`PaneModel.id`）与模型。
    func openCodeTab(directory: String, sessions: [AgentHistoryFakeSource.Session] = []) async
        -> (id: UUID, code: CodeTabModel)? {
        let tabID = workspace.openCodeTab(serverID: host, hostName: hostName, directory: directory)
        guard let tab = workspace.terminalGroups.tab(tabID), let code = tab.payload.codeTab else { return nil }
        code.install(await Self.connection(directory: directory, sessions: sessions))
        return (tab.payload.id, code)
    }

    /// 本窗口里还没有 Code 标签页、请求中途开出来的那个：接上假的记录列表（窗口视图显示它时才去连，测试里替它接）。
    func installHistoryWhenOpened(directory: String) async -> CodeTabModel? {
        let opened = await waitUntil { self.workspace.codeTabID(of: self.host) != nil }
        guard opened, let code = workspace.terminalGroups.allTabs.first(where: { $0.payload.codeTab != nil })?.payload.codeTab
        else { return nil }
        code.install(await Self.connection(directory: directory, sessions: []))
        return code
    }

    /// Code 标签页里的会话（或终端标签页）连上了、登记了。
    func waitForRegistration(_ id: UUID) async -> Bool { await waitUntil { self.isRegistered(id) } }

    func dispose() { workspace.dispose() }

    private func isRegistered(_ id: UUID) -> Bool {
        workspace.sessionRegistrar?.registry.entries.contains { $0.id == id } == true
    }

    private func connect(_ pane: PaneModel) {
        let backend = MockBackend()
        backends[pane.id] = backend
        let name = hostName
        Task {
            await pane.session.connect(using: backend)
            pane.registrar?.register(paneID: pane.id, serverID: pane.serverProfileID, serverName: name, session: pane.session)
        }
    }

    static func connection(directory: String, sessions: [AgentHistoryFakeSource.Session]) async -> AgentHistoryConnection {
        let history = AgentHistoryModel(source: AgentHistoryFakeSource(tool: .claude, sessions: sessions),
                                        preferredDirectory: directory, followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(10)) }
        return AgentHistoryConnection(history: history)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
