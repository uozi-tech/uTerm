import SwiftData
import SwiftUI
import UDesignKit
import UPaneGroups

/// 终端窗口「Code」模式的状态：活动终端标签页所在主机的历史会话。每台主机一份连接，换主机再换回来时选中的会话、
/// 折起来的组都还在；最近用过的几台留着，更早的放掉（SFTP 会话还给连接池）。
@MainActor
@Observable
final class CodeModeModel {
    /// 留几台主机的连接。
    nonisolated static let keptHosts = 3
    /// Code 模式的列表默认宽度（独立历史窗口是 300）。
    nonisolated static let defaultSidebarWidth = 280.0

    private(set) var connections: [UUID: AgentHistoryConnection] = [:]
    /// 拖过的列表宽度，换主机时不变。
    var sidebarWidth = CodeModeModel.defaultSidebarWidth
    /// 终端标签页右键「历史会话…」要定位的主机与目录。
    private(set) var revealTarget: (serverID: UUID, request: AgentHistoryReveal)?
    @ObservationIgnored private var recent: [UUID] = []
    @ObservationIgnored private var revealGeneration = 0
    /// 测试、画廊换成假的连接。
    @ObservationIgnored private let makeConnection: (@MainActor (ServerProfile, String?) -> AgentHistoryConnection)?

    init(makeConnection: (@MainActor (ServerProfile, String?) -> AgentHistoryConnection)? = nil) {
        self.makeConnection = makeConnection
    }

    /// 这台主机的连接：有就用原来的，没有就建一个（还没开，见 `AgentHistoryConnection.open`）。
    func connection(for server: ServerProfile, directory: String?, container: ModelContainer) -> AgentHistoryConnection {
        touch(server.id)
        if let existing = connections[server.id] { return existing }
        let sftpOnly = server.sftpOnly
        let connection = makeConnection?(server, directory) ?? AgentHistoryConnection(
            preferredDirectory: directory, allowsCommands: { !sftpOnly }, tools: AgentHistoryTool.allCases,
            followsCurrentProject: false, connect: AgentHistoryAccess.server(server, container: container))
        connections[server.id] = connection
        evict()
        return connection
    }

    /// 画廊用：直接放一份接好假数据的连接。
    func install(_ connection: AgentHistoryConnection, for serverID: UUID) {
        connections[serverID] = connection
        touch(serverID)
    }

    /// 要列表定位到这个目录（展开那一组、滚过去）。不知道目录就只切过去。
    func requestReveal(serverID: UUID, directory: String?) {
        guard let directory else {
            revealTarget = nil
            return
        }
        revealGeneration += 1
        revealTarget = (serverID, AgentHistoryReveal(directory: directory, generation: revealGeneration))
    }

    func reveal(for serverID: UUID) -> AgentHistoryReveal? {
        revealTarget.flatMap { $0.serverID == serverID ? $0.request : nil }
    }

    /// 窗口关了：全部放掉。
    func close() {
        for connection in connections.values { connection.close() }
        connections = [:]
        recent = []
    }

    private func touch(_ id: UUID) {
        recent.removeAll { $0 == id }
        recent.append(id)
    }

    private func evict() {
        while recent.count > Self.keptHosts {
            let oldest = recent.removeFirst()
            connections.removeValue(forKey: oldest)?.close()
        }
    }
}

/// 「继续这个会话」「＋新会话」在本窗口的终端区开新标签页跑命令。
@MainActor
enum CodeModeRouting {
    /// 在 `serverID` 上开一个新终端标签页（活动组里，设为前台），连上、行编辑器起来之后打进 `command`。
    /// 不包子 shell：退出编码工具之后 shell 留在项目目录里。
    @discardableResult
    static func run(_ command: String, serverID: UUID, title: String, in workspace: WorkspaceModel) -> PaneModel? {
        let tabID = workspace.openServer(profileID: serverID, title: title)
        guard let pane = workspace.terminalGroups.tab(tabID)?.payload else { return nil }
        pane.session.startTrackedRun(command, inSubshell: false)
        return pane
    }

    /// Code 模式列哪台主机：活动终端标签页那台；前台是文件标签时取最近一次活动的那台（还有标签开着的话），
    /// 再不行取第一个终端标签页那台。一个终端标签页都没有为 nil。
    static func serverID(in workspace: WorkspaceModel, lastServerID: UUID?) -> UUID? {
        let terminals = workspace.terminalGroups.allTabs.map(\.payload).filter { $0.fileBuffer == nil }
        guard let first = terminals.first else { return nil }
        if let focused = workspace.focusedTerminalServerID { return focused }
        if let lastServerID, terminals.contains(where: { $0.serverProfileID == lastServerID }) { return lastServerID }
        return first.serverProfileID
    }

    /// 那台主机上终端的当前目录：活动标签页是它就取活动的，否则取它的第一个终端标签页。shell 没报过（没有 OSC 7）为 nil。
    static func directory(in workspace: WorkspaceModel, serverID: UUID) -> String? {
        let terminals = workspace.terminalGroups.allTabs.map(\.payload)
            .filter { $0.fileBuffer == nil && $0.serverProfileID == serverID }
        let active = workspace.terminalGroups.activeTab?.payload
        let pane = active.flatMap { pane in terminals.contains { $0 === pane } ? pane : nil } ?? terminals.first
        return pane.flatMap { ClaudeProjectPath.directory(fromOSC7: $0.session.shadow.workingDirectory) }
    }
}

/// Code 模式的内容：左边一直在的历史会话列表（可分组），右边选中会话的只读对话。列的是活动终端标签页所在的主机。
struct CodeModeView: View {
    let code: CodeModeModel
    /// 要列的主机；窗口里一个终端标签页都没有为 nil。
    let server: ServerProfile?
    /// 那台主机上终端的当前目录（「＋」新会话默认开在这里）。
    let directory: String?
    /// 在本窗口的终端区开新标签页跑这条命令，并切回「终端」模式。
    let run: (_ server: ServerProfile, _ command: String) -> Void
    let onNewTerminal: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if let server {
            hostContent(server)
                // 换了主机就是另一份列表：各自的选中、滚动位置互不干扰。
                .id(server.id)
                .task(id: server.id) {
                    let connection = code.connection(for: server, directory: directory, container: modelContext.container)
                    await connection.open()
                }
        } else {
            RemoteMacStateView(systemImage: "terminal", title: String(localized: "没有终端标签页"),
                               detail: String(localized: "Code 模式列出当前终端标签页所在主机上的编码会话。先新建一个终端标签页。")) {
                UDButton(title: String(localized: "新建终端标签页"), systemImage: "plus", action: onNewTerminal)
            }
        }
    }

    @ViewBuilder private func hostContent(_ server: ServerProfile) -> some View {
        if let connection = code.connections[server.id] {
            switch connection.phase {
            case .connecting:
                RemoteMacProgressView(text: String(localized: "正在连接…"))
            case .failed(let message):
                RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法读取历史会话"),
                                   detail: message) {
                    UDButton(title: String(localized: "重试")) { Task { await connection.open() } }
                }
            case .ready(let history):
                AgentHistoryBrowser(
                    history: history,
                    onResume: { file in
                        guard let plan = history.resumeCommand(for: file) else { return }
                        run(server, plan.command)
                    },
                    newSession: AgentHistoryNewSession(directory: directory) { _, command, _ in run(server, command) },
                    reveal: code.reveal(for: server.id),
                    sidebarWidth: Binding(get: { code.sidebarWidth }, set: { code.sidebarWidth = $0 }))
            }
        } else {
            RemoteMacProgressView(text: String(localized: "正在连接…"))
        }
    }
}
