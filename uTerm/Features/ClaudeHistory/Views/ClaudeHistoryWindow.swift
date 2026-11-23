import AppKit
import Observation
import SwiftData
import SwiftUI
import UDesignKit
import UPaneGroups

/// 「历史会话」窗口的身份：哪台主机、打开时终端在哪个目录。同一台主机同一个目录再开带出已有的那个。
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
    /// 旧版从哪个窗口打开的（那时「继续这个会话」开回原窗口）。现在不再填，留着字段：系统恢复的旧窗口身份照样解得开。
    var origin: UUID?

    nonisolated static func == (lhs: ClaudeHistoryWindowID, rhs: ClaudeHistoryWindowID) -> Bool {
        lhs.host == rhs.host && lhs.directory == rhs.directory
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(directory)
    }
}

/// 配对的 Mac 的「继续这个会话」要开回那台 Mac 的远程窗口：窗口开着时登记一个入口。
@MainActor
final class ClaudeHistoryResumeRouter {
    static let shared = ClaudeHistoryResumeRouter()

    private init() {}

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

/// 「继续这个会话」「＋新会话」：在同一台主机上开新终端标签，执行数据源给的命令（如 `cd -- '<目录>' && claude --resume <ID>`）。
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

    /// SSH 主机：新开一个终端窗口跑（这个窗口只剩系统恢复的旧窗口会走到，SSH 终端区用 Code 标签页）。
    static func ssh(serverID: UUID, command: String, registry: TerminalSessionRegistry) {
        guard let open = registry.openTerminalWindow, let windowID = open(serverID) else { return }
        Task {
            guard let entry = await registry.waitForSession(inWindow: windowID, timeout: connectTimeout),
                  let session = registry.session(for: entry.id) else { return }
            session.startTrackedRun(command, inSubshell: false)
        }
    }
}

extension OpenWindowAction {
    /// 从远程 Mac 窗口里的终端标签打开：读那台 Mac 上的 `~/.claude`。远控协议里没有终端的当前目录，所以列全部项目。
    /// （SSH 终端区与本机终端窗口用自己的 Code 标签页，不再开这个窗口。）
    @MainActor
    func openClaudeHistory(pairedMac macID: String) {
        self(value: ClaudeHistoryWindowID(host: .pairedMac(macID), directory: nil))
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
    /// 那台 SSH 主机标成了只许 SFTP（不能跑命令，搜不了）。
    @ObservationIgnored private var sftpOnly = false
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
            // 列表按项目分组、一直列全部项目（打开时终端所在的那一组由列表定位过去）；几种编码工具的记录都读。
            connection = AgentHistoryConnection(preferredDirectory: windowID.directory,
                                                allowsCommands: { [weak self] in self?.sftpOnly != true },
                                                tools: AgentHistoryTool.allCases, followsCurrentProject: false,
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
                self?.sftpOnly = profile.sftpOnly
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

/// 「历史会话」窗口：左边会话列表（可分组），右边只读的对话内容。
/// 配对的 Mac 的窗口从标签页右键打开它；SSH 终端区与本机终端窗口用 Code 标签页（同一套列表与对话组件）。
/// 本机与 SSH 主机这两种身份留着：系统恢复的旧窗口、窗口的「继续这个会话」仍然走得通。
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
        }
    }

    private var title: String {
        guard let name = model?.hostName, !name.isEmpty else { return String(localized: "历史会话") }
        return String(localized: "历史会话 · \(name)")
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
                AgentHistoryBrowser(history: history,
                                    onResume: { file in
                                        guard let plan = history.resumeCommand(for: file) else { return }
                                        run(plan.command, directory: plan.directory)
                                    },
                                    newSession: AgentHistoryNewSession(directory: windowID?.directory) { _, command, directory in
                                        run(command, directory: directory)
                                    },
                                    reveal: windowID?.directory.map { AgentHistoryReveal(directory: $0, generation: 0) })
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

    /// 在那台主机上新开终端跑 `command`（继续一个会话，或者新开一个）。
    private func run(_ command: String, directory: String) {
        guard let windowID, model != nil else { return }
        switch windowID.host {
        case .local:
            ClaudeHistoryResume.local(command: command, directory: directory, registry: registry)
        case .server(let id):
            ClaudeHistoryResume.ssh(serverID: id, command: command, registry: registry)
        case .pairedMac(let macID):
            let openWindow = openWindow
            Task {
                do {
                    try await ClaudeHistoryResume.pairedMac(macID: macID, directory: directory,
                                                            command: command, openWindow: openWindow)
                } catch {
                    resumeError = error.localizedDescription
                }
            }
        }
    }
}
