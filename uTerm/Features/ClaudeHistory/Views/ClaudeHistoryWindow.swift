import AppKit
import Observation
import SwiftData
import SwiftUI
import UDesignKit
import UPaneGroups

/// 「Claude 历史会话」窗口的身份：哪台主机、打开时终端在哪个目录。同一台主机同一个目录再开带出已有的那个。
nonisolated struct ClaudeHistoryWindowID: Codable, Hashable, Sendable {
    nonisolated enum Host: Codable, Hashable, Sendable {
        /// 这台 Mac（经辅助程序读文件）。
        case local
        /// 一台已保存的 SSH 主机（`ServerProfile.id`）。
        case server(UUID)
        /// 一台配对过的 Mac（`RemoteMacDirectory.Mac.id`），经远控链路读它的文件，不走 SSH。
        case pairedMac(String)
    }

    let host: Host
    /// 打开时终端的当前目录，nil = 不知道（列全部项目）。
    var directory: String?
    /// 从哪个窗口打开的：「继续这个会话」把新标签开回那里（`ClaudeHistoryResumeRouter`）。
    var origin: UUID?

    nonisolated static func == (lhs: ClaudeHistoryWindowID, rhs: ClaudeHistoryWindowID) -> Bool {
        lhs.host == rhs.host && lhs.directory == rhs.directory
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(directory)
    }
}

/// 「继续这个会话」要开回原来的工作区 / 终端窗口：打开历史窗口时登记一个入口，弱引用那个窗口的模型。
/// 窗口关了入口就失效，这时退到新开一个终端窗口。
@MainActor
final class ClaudeHistoryResumeRouter {
    /// 在 `serverID` 上开一个新终端标签，连上后执行 `command`。返回 false = 这个窗口已经不在了。
    typealias Handler = @MainActor (_ serverID: UUID, _ title: String, _ command: String) -> Bool

    static let shared = ClaudeHistoryResumeRouter()
    private var handlers: [UUID: Handler] = [:]

    private init() {}

    func register(_ origin: UUID, handler: @escaping Handler) {
        handlers[origin] = handler
    }

    func unregister(_ origin: UUID) {
        handlers[origin] = nil
    }

    func handler(for origin: UUID?) -> Handler? {
        origin.flatMap { handlers[$0] }
    }

    // MARK: 配对的 Mac

    /// 在那台 Mac 上新开本机终端（开在 `directory`），接上之后打进 `command`。
    typealias RemoteHandler = @MainActor (_ directory: String, _ command: String) async throws -> Void

    /// 一台 Mac 一扇远程 Mac 窗口（`RemoteMacWindowID`），所以按 Mac 登记，不按打开历史的那一次。
    private var remoteHandlers: [String: RemoteHandler] = [:]
    /// 那扇窗口已经关了：先记下，窗口重新打开、连上之后由它取走（`takePendingRemote`）。
    private var pendingRemote: [String: (directory: String, command: String)] = [:]

    func registerRemote(_ macID: String, handler: @escaping RemoteHandler) {
        remoteHandlers[macID] = handler
    }

    func unregisterRemote(_ macID: String) {
        remoteHandlers[macID] = nil
    }

    func remoteHandler(for macID: String) -> RemoteHandler? {
        remoteHandlers[macID]
    }

    func queueRemote(_ macID: String, directory: String, command: String) {
        pendingRemote[macID] = (directory, command)
    }

    func takePendingRemote(_ macID: String) -> (directory: String, command: String)? {
        pendingRemote.removeValue(forKey: macID)
    }
}

/// 「继续这个会话」：在同一台主机上开新终端标签，执行 `cd -- '<目录>' && claude --resume <ID>`。
/// 命令经 `startTrackedRun` 打进去：连上、等行编辑器起来之后才打，用户看到的就是这一行命令。
/// 不包子 shell：退出 Claude Code 之后 shell 留在项目目录里（SSH 的新标签是从主目录起的）。
@MainActor
enum ClaudeHistoryResume {
    /// 等新开的终端连上的上限。SSH 首连可能要确认主机密钥，所以给得宽。
    static let connectTimeout: Duration = .seconds(30)

    static func local(command: String, directory: String, registry: TerminalSessionRegistry) {
        guard let open = registry.openLocalShell, let paneID = open(directory) else { return }
        // 加进已有本机终端窗口的标签马上就在；新开窗口的要等窗口搭起来、会话登记上。
        if let pane = LocalShellWindowRouter.shared.allPanes.first(where: { $0.id == paneID }) {
            pane.session.startTrackedRun(command, inSubshell: false)
            return
        }
        Task {
            guard await registry.waitForSession(id: paneID, timeout: connectTimeout) != nil,
                  let session = registry.session(for: paneID) else { return }
            session.startTrackedRun(command, inSubshell: false)
        }
    }

    /// 配对的 Mac：那台 Mac 的远程窗口开着就在它里面新开终端；关了就先打开它，连上之后再开（`takePendingRemote`）。
    static func pairedMac(macID: String, directory: String, command: String, openWindow: OpenWindowAction) async throws {
        if let handler = ClaudeHistoryResumeRouter.shared.remoteHandler(for: macID) {
            try await handler(directory, command)
            return
        }
        ClaudeHistoryResumeRouter.shared.queueRemote(macID, directory: directory, command: command)
        openWindow(value: RemoteMacWindowID(macID: macID))
    }

    static func ssh(serverID: UUID, title: String, command: String, origin: UUID?, registry: TerminalSessionRegistry) {
        if let handler = ClaudeHistoryResumeRouter.shared.handler(for: origin), handler(serverID, title, command) {
            return
        }
        guard let open = registry.openTerminalWindow, let windowID = open(serverID) else { return }
        Task {
            guard let entry = await registry.waitForSession(inWindow: windowID, timeout: connectTimeout),
                  let session = registry.session(for: entry.id) else { return }
            session.startTrackedRun(command, inSubshell: false)
        }
    }
}

extension OpenWindowAction {
    /// 从工作区 / 终端窗口里一个 SSH 终端标签打开。`workspace` 是那个窗口的模型，「继续这个会话」开回那里。
    @MainActor
    func openClaudeHistory(serverID: UUID, session: TerminalSession, workspace: WorkspaceModel) {
        let origin = UUID()
        ClaudeHistoryResumeRouter.shared.register(origin) { [weak workspace] serverID, title, command in
            guard let workspace else { return false }
            let tabID = workspace.openServer(profileID: serverID, title: title)
            guard let pane = workspace.terminalGroups.tab(tabID)?.payload else { return false }
            pane.session.startTrackedRun(command, inSubshell: false)
            workspace.revealTerminal(paneID: pane.id)
            return true
        }
        let directory = ClaudeProjectPath.directory(fromOSC7: session.shadow.workingDirectory)
        self(value: ClaudeHistoryWindowID(host: .server(serverID), directory: directory, origin: origin))
    }

    /// 从远程 Mac 窗口里的终端标签打开：读那台 Mac 上的 `~/.claude`。远控协议里没有终端的当前目录，所以列全部项目。
    @MainActor
    func openClaudeHistory(pairedMac macID: String) {
        self(value: ClaudeHistoryWindowID(host: .pairedMac(macID), directory: nil))
    }

    /// 从本机终端标签打开。本机 shell 不发 OSC 7，目录取辅助程序问到的。
    @MainActor
    func openClaudeHistory(localPane pane: LocalShellPane) {
        self(value: ClaudeHistoryWindowID(host: .local, directory: pane.workingDirectory.flatMap(ClaudeProjectPath.normalized)))
    }
}

/// 窗口的连接：按窗口身份建文件通道（SSH 主机走 SFTP、本机走辅助程序、配对的 Mac 走远控链路），
/// 之后的状态都在共享的 `AgentHistoryConnection` 里。
@MainActor
@Observable
final class ClaudeHistoryWindowModel {
    let windowID: ClaudeHistoryWindowID
    private(set) var hostName: String
    private(set) var connection: AgentHistoryConnection?
    /// 向 `RemoteMacDirectory` 借的那台 Mac 的连接（关窗口时还回去）。
    @ObservationIgnored private var borrowedMac: (id: String, directory: RemoteMacDirectory)?

    init(windowID: ClaudeHistoryWindowID) {
        self.windowID = windowID
        hostName = windowID.host == .local ? String(localized: "本机") : ""
    }

    /// 界面画廊用：直接给一个已经接好假数据的模型。
    init(windowID: ClaudeHistoryWindowID, hostName: String, history: AgentHistoryModel) {
        self.windowID = windowID
        self.hostName = hostName
        connection = AgentHistoryConnection(history: history)
    }

    var history: AgentHistoryModel? { connection?.history }

    func open(container: ModelContainer, macs: RemoteMacDirectory) async {
        if connection == nil {
            connection = AgentHistoryConnection(preferredDirectory: windowID.directory,
                                                connect: makeConnect(container: container, macs: macs))
        }
        await connection?.open()
    }

    private func makeConnect(container: ModelContainer, macs: RemoteMacDirectory) -> AgentHistoryAccess.Connect {
        switch windowID.host {
        case .local:
            return { _ in RemoteMacFileProvider.localShellAgent() }
        case .server(let id):
            return AgentHistoryAccess.server(id: id, container: container) { [weak self] profile in
                self?.hostName = profile.name
            }
        case .pairedMac(let macID):
            return { [weak self] gate in
                if !macs.isActivated { macs.activate() }
                guard let mac = macs.mac(id: macID) else {
                    throw AgentHistoryAccess.Failure(message: String(localized: "找不到这台 Mac"))
                }
                let client = macs.acquireClient(for: mac)
                if let self {
                    if self.borrowedMac == nil { self.borrowedMac = (macID, macs) } else { macs.releaseClient(macID: macID) }
                    self.hostName = client.macName
                }
                return try await AgentHistoryAccess.pairedMac(client)(gate)
            }
        }
    }

    func close() {
        connection?.close()
        if let borrowedMac { borrowedMac.directory.releaseClient(macID: borrowedMac.id) }
        borrowedMac = nil
    }
}

/// 「Claude 历史会话」窗口：左边会话列表，右边只读的对话内容。
struct ClaudeHistoryWindowView: View {
    let windowID: ClaudeHistoryWindowID?

    @Environment(\.modelContext) private var modelContext
    @Environment(TerminalSessionRegistry.self) private var registry
    @Environment(RemoteMacDirectory.self) private var macs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var model: ClaudeHistoryWindowModel?
    @State private var resumeError: String?
    private let isCatalog: Bool

    init(windowID: ClaudeHistoryWindowID?, catalogModel: ClaudeHistoryWindowModel? = nil) {
        self.windowID = windowID
        isCatalog = catalogModel != nil
        _model = State(initialValue: catalogModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .udCard()
                .padding(.horizontal, UD.Layout.cardInset)
                .padding(.bottom, UD.Layout.cardInset)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.pageBg)
        .background(WorkspaceWindowChrome(serverName: "", background: WS.canvasNSColor))
        .background(WindowTitleBinding(title: title))
        .frame(minWidth: 820, minHeight: 480)
        .disablesInitialAutoFocus()
        .task { await start() }
        .alert("无法继续这个会话", isPresented: Binding(get: { resumeError != nil }, set: { if !$0 { resumeError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resumeError ?? "")
        }
        .onDisappear {
            guard !isCatalog else { return }
            model?.close()
            if let origin = windowID?.origin { ClaudeHistoryResumeRouter.shared.unregister(origin) }
        }
    }

    private var title: String {
        guard let name = model?.hostName, !name.isEmpty else { return String(localized: "Claude 历史会话") }
        return String(localized: "Claude 历史会话 · \(name)")
    }

    private var titleBar: some View {
        Text(title)
            .font(UD.mono(13))
            .windowTitleForeground()
            .allowsHitTesting(false)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(WindowDragHandle(fill: WS.canvasNSColor))
    }

    @ViewBuilder private var content: some View {
        if let model, let connection = model.connection {
            switch connection.phase {
            case .connecting:
                RemoteMacProgressView(text: String(localized: "正在连接…"))
            case .failed(let message):
                RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法读取历史会话"),
                                   detail: message) {
                    UDButton(title: String(localized: "重试")) {
                        Task { await model.open(container: modelContext.container, macs: macs) }
                    }
                }
            case .ready(let history):
                AgentHistoryBrowser(history: history, onResume: { file in resume(file, history: history) })
            }
        } else if model != nil {
            RemoteMacProgressView(text: String(localized: "正在连接…"))
        } else {
            Color.clear
        }
    }

    private func start() async {
        guard let windowID else {
            dismiss()
            return
        }
        guard model == nil else { return }
        let model = ClaudeHistoryWindowModel(windowID: windowID)
        self.model = model
        await model.open(container: modelContext.container, macs: macs)
    }

    private func resume(_ file: AgentHistorySessionFile, history: AgentHistoryModel) {
        guard let windowID, let model, let plan = history.resumeCommand(for: file) else { return }
        switch windowID.host {
        case .local:
            ClaudeHistoryResume.local(command: plan.command, directory: plan.directory, registry: registry)
        case .server(let id):
            ClaudeHistoryResume.ssh(serverID: id, title: model.hostName, command: plan.command,
                                    origin: windowID.origin, registry: registry)
        case .pairedMac(let macID):
            let openWindow = openWindow
            Task {
                do {
                    try await ClaudeHistoryResume.pairedMac(macID: macID, directory: plan.directory,
                                                            command: plan.command, openWindow: openWindow)
                } catch {
                    resumeError = error.localizedDescription
                }
            }
        }
    }
}
