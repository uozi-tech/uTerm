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
}

/// 「继续这个会话」：在同一台主机上开新终端标签，执行 `cd -- '<目录>' && claude --resume <ID>`。
/// 命令经 `startTrackedRun` 打进去：连上、等行编辑器起来之后才打，用户看到的就是这一行命令。
@MainActor
enum ClaudeHistoryResume {
    /// 等新开的终端连上的上限。SSH 首连可能要确认主机密钥，所以给得宽。
    static let connectTimeout: Duration = .seconds(30)

    static func local(command: String, directory: String, registry: TerminalSessionRegistry) {
        guard let open = registry.openLocalShell, let paneID = open(directory) else { return }
        // 加进已有本机终端窗口的标签马上就在；新开窗口的要等窗口搭起来、会话登记上。
        if let pane = LocalShellWindowRouter.shared.allPanes.first(where: { $0.id == paneID }) {
            pane.session.startTrackedRun(command)
            return
        }
        Task {
            guard await registry.waitForSession(id: paneID, timeout: connectTimeout) != nil,
                  let session = registry.session(for: paneID) else { return }
            session.startTrackedRun(command)
        }
    }

    static func ssh(serverID: UUID, title: String, command: String, origin: UUID?, registry: TerminalSessionRegistry) {
        if let handler = ClaudeHistoryResumeRouter.shared.handler(for: origin), handler(serverID, title, command) {
            return
        }
        guard let open = registry.openTerminalWindow, let windowID = open(serverID) else { return }
        Task {
            guard let entry = await registry.waitForSession(inWindow: windowID, timeout: connectTimeout),
                  let session = registry.session(for: entry.id) else { return }
            session.startTrackedRun(command)
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
            pane.session.startTrackedRun(command)
            workspace.revealTerminal(paneID: pane.id)
            return true
        }
        let directory = ClaudeProjectPath.directory(fromOSC7: session.shadow.workingDirectory)
        self(value: ClaudeHistoryWindowID(host: .server(serverID), directory: directory, origin: origin))
    }

    /// 从本机终端标签打开。本机 shell 不发 OSC 7，目录取辅助程序问到的。
    @MainActor
    func openClaudeHistory(localPane pane: LocalShellPane) {
        self(value: ClaudeHistoryWindowID(host: .local, directory: pane.workingDirectory.flatMap(ClaudeProjectPath.normalized)))
    }
}

/// 窗口的连接状态：先建文件通道（SSH 主机走 SFTP、本机走辅助程序），建好之后交给共享的 `AgentHistoryModel`。
@MainActor
@Observable
final class ClaudeHistoryWindowModel {
    enum Phase {
        case connecting
        case failed(String)
        case ready(AgentHistoryModel)
    }

    let windowID: ClaudeHistoryWindowID
    private(set) var phase: Phase = .connecting
    private(set) var hostName: String
    @ObservationIgnored private var provider: (any SFTPProviding)?
    @ObservationIgnored private var isOpening = false

    init(windowID: ClaudeHistoryWindowID) {
        self.windowID = windowID
        hostName = windowID.host == .local ? String(localized: "本机") : ""
    }

    /// 界面画廊用：直接给一个已经接好假数据的模型。
    init(windowID: ClaudeHistoryWindowID, hostName: String, history: AgentHistoryModel) {
        self.windowID = windowID
        self.hostName = hostName
        phase = .ready(history)
    }

    var history: AgentHistoryModel? {
        if case .ready(let model) = phase { return model }
        return nil
    }

    func open(container: ModelContainer) async {
        guard !isOpening, history == nil else { return }
        isOpening = true
        defer { isOpening = false }
        phase = .connecting
        do {
            let provider: any SFTPProviding
            switch windowID.host {
            case .local:
                provider = RemoteMacFileProvider.localShellAgent()
            case .server(let id):
                var descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                guard let profile = try container.mainContext.fetch(descriptor).first else {
                    phase = .failed(String(localized: "找不到这台主机，它可能已被删除。"))
                    return
                }
                hostName = profile.name
                // 能开到这里说明终端已经连过这台主机、指纹早已确认；这里不弹确认，遇到新指纹直接失败。
                provider = try await SFTPSession.make(profile: profile, container: container, approver: { _ in false })
            }
            self.provider = provider
            let history = AgentHistoryModel(source: ClaudeHistorySource(provider: provider),
                                            preferredDirectory: windowID.directory)
            phase = .ready(history)
            await history.start()
        } catch {
            phase = .failed(FriendlyError.describe(error))
        }
    }

    func close() {
        let provider = self.provider
        self.provider = nil
        if let provider { Task { await provider.close() } }
    }
}

/// 「Claude 历史会话」窗口：左边会话列表，右边只读的对话内容。
struct ClaudeHistoryWindowView: View {
    let windowID: ClaudeHistoryWindowID?

    @Environment(\.modelContext) private var modelContext
    @Environment(TerminalSessionRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss
    @State private var model: ClaudeHistoryWindowModel?
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
        if let model {
            switch model.phase {
            case .connecting:
                RemoteMacProgressView(text: String(localized: "正在连接…"))
            case .failed(let message):
                RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法读取历史会话"),
                                   detail: message) {
                    UDButton(title: String(localized: "重试")) {
                        Task { await model.open(container: modelContext.container) }
                    }
                }
            case .ready(let history):
                AgentHistoryBrowser(history: history, onResume: { file in resume(file, history: history) })
            }
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
        await model.open(container: modelContext.container)
    }

    private func resume(_ file: AgentHistorySessionFile, history: AgentHistoryModel) {
        guard let windowID, let model, let plan = history.resumeCommand(for: file) else { return }
        switch windowID.host {
        case .local:
            ClaudeHistoryResume.local(command: plan.command, directory: plan.directory, registry: registry)
        case .server(let id):
            ClaudeHistoryResume.ssh(serverID: id, title: model.hostName, command: plan.command,
                                    origin: windowID.origin, registry: registry)
        }
    }
}
