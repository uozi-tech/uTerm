import AppKit
import SwiftUI
import UDesignKit
import UPaneGroups

/// 一台远程 Mac 的窗口：连上（第一次时在那台 Mac 上核对数字配对），整台接管它的终端，每个一个标签；
/// 标签条上的显示器按钮打开它的屏幕窗口（`RemoteDesktopWindow`）。关标签、关窗口只断开接入，那台 Mac 上的终端照常运行。
struct RemoteMacWindowView: View {
    let windowID: RemoteMacWindowID?

    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(\.dismiss) private var dismiss
    @State private var model: RemoteMacWindowModel?
    @State private var missing = false

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
        .background(WorkspaceCloseShortcutInstaller { window in
            // 前台是 Code 标签页、右边显示着它里面的会话：只结束那个会话（`CodeTabModel.closeShortcut`）。
            if TerminalCloseGuard.endDisplayedSession(of: model?.active?.codeTab, window: window,
                                                      session: { ($0 as? RemoteTerminalPane)?.session }) {
                return
            }
            guard let model, model.panes.count > 1, let active = model.active else {
                window.performClose(nil)
                return
            }
            model.close(active.id)
        })
        .frame(minWidth: 560, minHeight: 360)
        .task { await start() }
        .onDisappear {
            model?.disposeAll()
            if model != nil, let windowID {
                directory.releaseClient(macID: windowID.macID)
                ClaudeHistoryResumeRouter.shared.unregisterRemote(windowID.macID)
            }
        }
    }

    private var title: String { model?.client.macName ?? String(localized: "远程 Mac") }

    private var titleBar: some View {
        Text(title)
            .font(UD.mono(13, weight: .semibold))
            .windowTitleForeground()
            .allowsHitTesting(false)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(WindowDragHandle(fill: WS.canvasNSColor))
    }

    @ViewBuilder private var content: some View {
        if missing {
            RemoteMacStateView(systemImage: "questionmark.circle", title: String(localized: "找不到这台 Mac"),
                               detail: String(localized: "它可能已被忘记。在「我的 Mac」里重新配对。"))
        } else if let model {
            RemoteMacSessionView(model: model, macID: windowID?.macID ?? "")
        } else {
            Color.clear
        }
    }

    private func start() async {
        // 系统恢复的窗口值可能是空的：不恢复，关掉。
        guard let windowID else {
            dismiss()
            return
        }
        guard model == nil else { return }
        if !directory.isActivated { directory.activate() }
        guard let mac = directory.mac(id: windowID.macID) else {
            missing = true
            return
        }
        let model = RemoteMacWindowModel(client: directory.acquireClient(for: mac))
        self.model = model
        // Claude 历史会话里的「继续这个会话」：在这扇窗口里新开终端。
        ClaudeHistoryResumeRouter.shared.registerRemote(windowID.macID) { [weak model] directory, command in
            guard let model else { return }   // 窗口关的时候已经注销，这里只是兜底
            try await model.resumeAgentSession(directory: directory, command: command)
        }
        await model.client.connectInteractively()
    }
}

/// 窗口内容：按连接状态显示连接中 / 核对配对数字 / 失败，连上后是终端标签区。
private struct RemoteMacSessionView: View {
    let model: RemoteMacWindowModel
    let macID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let client = model.client
        Group {
            switch client.state {
            case .idle where model.panes.isEmpty, .connecting where model.panes.isEmpty,
                 .failed where model.panes.isEmpty && client.isAutoRetrying:
                RemoteMacProgressView(text: client.connectProgress?.title ?? "", detail: client.connectProgress?.detail)
            case .awaitingApproval(let code):
                RemoteMacPairingCodeView(macName: client.macName, code: code)
            case .failed(let message) where model.panes.isEmpty:
                RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法连接"),
                                   detail: [message, client.failureContext].compactMap { $0 }.joined(separator: "\n")) {
                    HStack(spacing: 8) {
                        UDButton(title: String(localized: "重试")) { Task { await client.connectInteractively() } }
                        UDButton(title: String(localized: "网络诊断"), style: .secondary) {
                            openWindow(value: RemoteDiagnosticsWindowID(macID: macID))
                        }
                    }
                }
            default:
                // 提示条占自己的一行、把标签区往下推：原先叠在标签区顶上，和标签条、右侧按钮压在一起。
                VStack(spacing: 0) {
                    connectionNotice
                    RemoteMacTerminalArea(model: model, macID: macID)
                }
            }
        }
        .onChange(of: client.state, initial: true) { _, state in
            guard state == .connected else { return }
            model.takeOver()
            // 窗口是为「继续这个会话」打开的：连上之后开那个终端。
            if let pending = ClaudeHistoryResumeRouter.shared.takePendingRemote(macID) {
                Task {
                    try? await model.resumeAgentSession(directory: pending.directory, command: pending.command)
                }
            }
        }
        .onChange(of: client.listedSessionIDs) { _, ids in model.follow(ids, order: client.sessions.macTabOrder) }
        // 那台 Mac 的 Code 标签页变了（会话进出、结束、对上记录、改名）：同一份会话列表也要再对一次。
        .onChange(of: client.codeTabs) { _, _ in
            model.follow(client.listedSessionIDs, order: client.sessions.macTabOrder)
        }
        // 用户拖过标签就马上让那台 Mac 跟着排（`UPaneGroups` 没有拖动排序的回调，只能看布局变没变）。
        .onChange(of: model.layout) { _, _ in model.layoutChanged() }
    }

    /// 连着的过程中断了：标签留着（各自在后台重连），顶上一行说一声。
    @ViewBuilder private var connectionNotice: some View {
        switch model.client.state {
        case .connecting:
            noticeBar { SettingsInlineNote(tone: .neutral, text: String(localized: "连接断开，正在重新连接…")) }
        case .failed(let message):
            noticeBar {
                HStack(spacing: 8) {
                    SettingsInlineNote(tone: .warning, text: message)
                    UDButton(title: String(localized: "重试"), style: .secondary) { Task { await model.client.connectInteractively() } }
                        .padding(.trailing, 10)
                }
            }
        default:
            EmptyView()
        }
    }

    private func noticeBar(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }
}

/// 终端标签区：拖放分屏、按下即激活都在组件里，与本机终端窗口一致。不显示分屏按钮：远程终端没法「复制」一个。
private struct RemoteMacTerminalArea: View {
    let model: RemoteMacWindowModel
    let macID: String

    @Environment(\.openWindow) private var openWindow

    @Environment(\.colorScheme) private var colorScheme
    @State private var openError: String?
    /// 正在问那台 Mac 最近的工作区（问完再决定弹不弹目录选择）。
    @State private var preparingShell = false
    @State private var workspaceChoices: RemoteLocalWorkspaces?

    var body: some View {
        let background = SwiftUI.Color(
            nsColor: TerminalColorScheme.resolve(dark: colorScheme == .dark).backgroundColor)
        Group {
            if model.panes.isEmpty, model.isPreparingFirstShell {
                RemoteMacProgressView(text: String(localized: "正在打开终端…"))
            } else if model.panes.isEmpty {
                RemoteMacStateView(systemImage: "terminal", title: String(localized: "这台 Mac 上没有打开的终端"),
                                   detail: String(localized: "新建一个，那台 Mac 上也会弹出对应的终端窗口。")) {
                    HStack(spacing: 8) {
                        UDButton(title: preparingShell ? String(localized: "正在打开…") : String(localized: "新建终端")) { openNewShell() }
                            .disabled(!canOpenShell)
                            .macWorkspaceDialog(emptyStateChoices) { open(in: $0) }
                        if model.client.supportsDesktop {
                            UDButton(title: String(localized: "查看屏幕"), style: .secondary) { openDesktop() }
                                .disabled(model.client.state != .connected)
                        }
                        if model.client.supportsFiles {
                            UDButton(title: String(localized: "浏览文件"), style: .secondary) { openFiles() }
                                .disabled(model.client.state != .connected)
                        }
                    }
                }
            } else {
                UPaneGroupArea(
                    model: model.groups,
                    dragType: .utermTabID,
                    stripHeight: WorkspacePaneHeaderLayout.height,
                    showsSplitButton: false,
                    showsActiveGroupRing: false,
                    splitButtonDirection: .automatic,
                    splitButtonIcon: .system("rectangle.split.2x1"),
                    descriptor: { tab in descriptor(for: tab.payload) },
                    content: { tab, _ in
                        if let code = tab.payload.codeTab {
                            codeTab(code, background: background)
                        } else {
                            RemoteTerminalPaneView(pane: tab.payload, background: background)
                        }
                    },
                    emptyGroup: { _ in background },
                    onRequestClose: { tab in model.close(tab.id) },
                    stripAccessory: { _ in
                        HStack(spacing: 2) {
                            if model.client.supportsFiles { filesButton }
                            if model.client.supportsDesktop { desktopButton }
                            newShellButton
                            if model.offersCodeTab { CodeTabButton { model.openCodeTab() } }
                        }
                    },
                    tabMenu: { tab in
                        TerminalTabContextMenu(
                            title: tab.payload.title(in: model.client.sessions),
                            onOpenClaudeHistory: historyAction(for: tab.payload),
                            onClose: { model.close(tab.id) })
                    })
                    .uPaneGroupStyle(.card)
                    .uPaneGroupWells()
            }
        }
        .alert("无法新建终端", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
    }

    /// 终端标签右键「历史会话…」：那台 Mac 的 Code 标签页能镜像就打开这扇窗口里的 Code 标签页，否则打开独立的历史会话窗口。
    /// 历史会话经文件通道读那台 Mac 的 `~/.claude`：老版本 Mac 不认文件请求（收到会断开整条连接），不给入口。
    private func historyAction(for pane: RemoteTerminalPane) -> (() -> Void)? {
        guard pane.codeTab == nil else { return nil }
        if model.offersCodeTab { return { model.openCodeTab() } }
        guard model.client.supportsFiles else { return nil }
        return { openWindow.openClaudeHistory(pairedMac: macID) }
    }

    /// Code 标签页：读那台 Mac 上的记录（经远控链路的文件通道），右边的终端接着它上面那个会话。
    private func codeTab(_ code: CodeTabModel, background: SwiftUI.Color) -> some View {
        CodeTabView(
            code: code,
            makeConnection: { model.makeCodeConnection(for: code) },
            terminal: { terminal, _ in
                guard let pane = terminal as? RemoteTerminalPane else { return AnyView(EmptyView()) }
                return AnyView(RemoteTerminalPaneView(pane: pane, background: background))
            },
            onMoveToTab: model.supportsCodeTabActions ? { runID in model.moveCodeRunToTab(runID) } : nil,
            onEndRun: { runID in
                TerminalCloseGuard.requestEndSession(runID, in: code) { ($0 as? RemoteTerminalPane)?.session }
            })
        .alert(code.remote?.failure?.title ?? "",
               isPresented: Binding(get: { code.remote?.failure != nil }, set: { if !$0 { code.remote?.failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(code.remote?.failure?.message ?? "")
        }
    }

    private func descriptor(for pane: RemoteTerminalPane) -> UPaneTabDescriptor {
        if let code = pane.codeTab {
            let running = code.runningCount
            // 同本机终端窗口的 Code 标签：不放图标，绿点一直在。
            return UPaneTabDescriptor(
                title: TerminalArea.codeTabBaseTitle,
                leadingDot: UD.success,
                help: running > 0
                    ? String(localized: "\(running) 个会话正在运行", comment: "Code 标签页收起的侧栏上：在跑的会话个数")
                    : TerminalArea.codeTabBaseTitle)
        }
        let session = pane.session
        // 镜像不自己解析程序状态（那台 Mac 答查询、推状态），读连接上记着的。
        let status = model.client.programStatus(for: pane.id)
        return UPaneTabDescriptor(
            title: pane.title(in: model.client.sessions),
            icon: .none,
            leadingDot: status?.tabDot ?? (session.connectionState == .connected ? UD.success : UD.text4),
            help: status?.tabHelp ?? pane.title(in: model.client.sessions))
    }

    private var canOpenShell: Bool {
        model.client.supportsLocalShell && model.client.state == .connected && !preparingShell
    }

    /// 目录选择挂在触发它的按钮上；空态与标签条的「+」不会同时在，按当前显示的那个分给它。
    private var emptyStateChoices: Binding<RemoteLocalWorkspaces?> {
        Binding(get: { model.panes.isEmpty ? workspaceChoices : nil }, set: { workspaceChoices = $0 })
    }

    private var stripChoices: Binding<RemoteLocalWorkspaces?> {
        Binding(get: { model.panes.isEmpty ? nil : workspaceChoices }, set: { workspaceChoices = $0 })
    }

    /// 同手机：那台 Mac 有最近的工作区就先问开在哪，没有就直接开在主目录。
    /// （接管时那台 Mac 一个终端都没有而自动开的第一个，照旧直接开在主目录，不问。）
    private func openNewShell() {
        guard !preparingShell else { return }
        preparingShell = true
        Task {
            let plan = await model.client.newShellPlan()
            preparingShell = false
            switch plan {
            case .ask(let workspaces): workspaceChoices = workspaces
            case .openDirectly: open(in: nil)
            }
        }
    }

    private func open(in directory: String?) {
        Task {
            do { try await model.openNewShell(directory: directory) } catch { openError = error.localizedDescription }
        }
    }

    private func openDesktop() {
        openWindow(value: RemoteDesktopWindowID(macID: macID))
    }

    private func openFiles() {
        openWindow(value: RemoteMacFilesWindowID(macID: macID))
    }

    private var filesButton: some View {
        Button { openFiles() } label: {
            Image(systemName: "folder")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .iconButtonHover(cornerRadius: 6)
        .disabled(model.client.state != .connected)
        .help(String(localized: "在新窗口里浏览这台 Mac 的文件"))
        .accessibilityLabel(Text("浏览文件"))
    }

    private var desktopButton: some View {
        Button { openDesktop() } label: {
            Image(systemName: "display")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .iconButtonHover(cornerRadius: 6)
        .disabled(model.client.state != .connected)
        .help(String(localized: "在新窗口里查看这台 Mac 的屏幕"))
        .accessibilityLabel(Text("查看屏幕"))
    }

    private var newShellButton: some View {
        Button { openNewShell() } label: {
            Image(systemName: "plus")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .iconButtonHover(cornerRadius: 6)
        .disabled(!canOpenShell)
        .macWorkspaceDialog(stripChoices) { open(in: $0) }
        .help(model.client.supportsLocalShell ? String(localized: "在这台 Mac 上新建终端")
                                              : String(localized: "那台 Mac 上的 uTerm 版本太旧，不能新建终端"))
        .accessibilityLabel(Text("新建终端"))
    }
}

/// 一个远程终端标签的内容。
private struct RemoteTerminalPaneView: View {
    let pane: RemoteTerminalPane
    let background: SwiftUI.Color
    @Environment(\.activePaneGate) private var activePaneGate

    var body: some View {
        Group {
            switch pane.session.connectionState {
            case .idle, .connecting:
                RemoteMacProgressView(text: String(localized: "正在接入…"))
            case .connected:
                GhosttyHostView(session: pane.session, isActive: activePaneGate?.isActive ?? true)
                    .overlay(alignment: .topTrailing) { TerminalFindBarSlot(session: pane.session) }
            case .failed(let message):
                RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法接入这个终端"),
                                   detail: message) {
                    UDButton(title: String(localized: "重试")) { Task { await pane.start() } }
                }
            case .disconnected:
                RemoteMacStateView(systemImage: "checkmark.circle", title: String(localized: "终端已结束"), detail: "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }
}

/// 第一次连：本机显示 6 位数，在那台 Mac 弹出的输入框里输入。
struct RemoteMacPairingCodeView: View {
    let macName: String
    let code: String

    var body: some View {
        VStack(spacing: 14) {
            Text(RemotePairingCopy.controllerTitle(macName)).font(.system(size: 17, weight: .semibold)).foregroundStyle(UD.text)
            Text(RemotePairingCode.grouped(code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .foregroundStyle(UD.text)
                .textSelection(.enabled)
            Text(RemotePairingCopy.controllerDetail)
                .font(.system(size: 12.5)).foregroundStyle(UD.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            UDIndeterminateBar().frame(width: 140).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct RemoteMacProgressView: View {
    let text: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            UDIndeterminateBar().frame(width: 140)
            Text(text).font(UD.caption).foregroundStyle(UD.text3)
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(UD.text4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RemoteMacStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(UD.text3)
            Text(title).font(.headline).foregroundStyle(UD.text)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(UD.text3)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

extension RemoteMacStateView where Actions == EmptyView {
    init(systemImage: String, title: String, detail: String) {
        self.init(systemImage: systemImage, title: title, detail: detail) { EmptyView() }
    }
}
