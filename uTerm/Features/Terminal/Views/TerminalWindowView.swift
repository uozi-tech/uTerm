import UPaneGroups
import UPaneTree
import UDesignKit
import SwiftUI
import SwiftData
import AppKit

/// 终端窗口内容区两态：纯终端窗格 ⇄ Agent 自然语言。编码工具的历史会话是终端区里的一种标签页（Code 标签页），不是一档模式。
enum TerminalWindowContentMode: Hashable, CaseIterable { case terminal, agent }

/// 一个独立「纯终端」窗口。**不绑定单台服务器**：每个标签各连各的主机，「在终端中打开」
/// 把主机作为新标签送进最近活跃的终端窗口（`TerminalWindowRouter`），不再一台主机一个窗口。
/// 标题栏 / 端口转发 / Agent 都跟随**活动标签**的那台主机。
///
/// 结构自上而下：标题栏（终端 ⇄ Agent 开关 / 主机 · 已连接 / 端口转发 · 断开）→
/// 终端模式：会话标签栏 + 可拖拽分屏窗格树 + 状态栏；Agent 模式：自然语言交互层 +
/// 状态栏。复用 `WorkspaceModel`（多标签 + 分屏 + 拖拽 + Agent model），但**不挂**
/// SFTP 侧栏 / 预览区 —— 终端窗口的精简形态。对齐设计稿 `pages/terminal.jsx` /
/// `pages/terminal-agent.jsx`。
struct TerminalWindowView: View {
    let windowID: TerminalWindowID?

    @Query private var profiles: [ServerProfile]
    @Query(sort: \AIProvider.sortOrder) private var providers: [AIProvider]
    @AppStorage(DefaultsKey.activeProviderID) private var activeProviderIDString: String = ""
    @AppStorage(DefaultsKey.agentSafety) private var agentSafetyRaw: String = AgentSafety.readAuto.rawValue

    @State private var workspace = WorkspaceModel()
    @State private var mode: TerminalWindowContentMode = .terminal
    @State private var didOpen = false
    @State private var palette = CommandPaletteModel()
    /// 最近一次活动终端标签连的主机。标签全关掉（或前台不是终端）时标题栏 / ⌘T 回落到它。
    @State private var lastServerID: UUID?
    /// 界面画廊注入的现成模型（标签、假后端都已接好）：不恢复会话、不开新标签、不接真执行器、关时不释放。
    private let isCatalog: Bool

    init(windowID: TerminalWindowID?, catalogModel: WorkspaceModel? = nil,
         catalogMode: TerminalWindowContentMode = .terminal) {
        self.windowID = windowID
        self.isCatalog = catalogModel != nil
        if let catalogModel {
            _workspace = State(initialValue: catalogModel)
            _didOpen = State(initialValue: true)
            _mode = State(initialValue: catalogMode)
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow
    @Environment(ForwardingCoordinator.self) private var forwarding

    /// 标题栏 / 端口转发 / Agent / ⌘T 当前作用的主机：活动终端标签那台 → 最近一次活动的那台 →
    /// 窗口首个标签那台 → 任意一台能开终端的主机（前几台都被删了也别让整窗变成空态）。
    private var currentServer: ServerProfile? {
        let candidates = [workspace.focusedTerminalServerID, lastServerID, windowID?.serverID]
        for case let id? in candidates {
            if let profile = profiles.first(where: { $0.id == id }) { return profile }
        }
        return profiles.first { !$0.sftpOnly }
    }

    private var safetyBinding: Binding<AgentSafety> {
        Binding(get: { AgentSafety(rawValue: agentSafetyRaw) ?? .readAuto },
                set: { agentSafetyRaw = $0.rawValue })
    }

    var body: some View {
        Group {
            if let windowID, let server = currentServer {
                terminalBody(server: server, windowID: windowID)
            } else {
                ContentUnavailableView(windowID == nil ? "正在恢复…" : "主机已删除",
                                       systemImage: windowID == nil ? "clock" : "server.rack")
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder
    private func terminalBody(server: ServerProfile, windowID: TerminalWindowID) -> some View {
        VStack(spacing: 0) {
            TerminalWindowTitleBar(
                host: server.displayEndpoint,
                session: workspace.focusedTerminalSession(),
                mode: $mode,
                activeForwardCount: forwarding.activeCount(forServer: server.id),
                onOpenForwarding: {
                    openWindow(value: PortForwardWindowID(id: UUID(), serverID: server.id))
                })

            // 内容区两态切换，同一张内容卡（分区方案 v3：距窗口左右 8pt，标签胶囊条 +
            // 终端凹槽 / Agent 对话都在卡里）；状态栏两态共用、坐在画布上，提到 switch 外。
            Group {
                switch mode {
                case .terminal:
                    TerminalArea(workspace: workspace, server: server, allowsOtherHosts: true)
                case .agent:
                    TerminalAgentView(
                        model: workspace.assistantModel,
                        host: server.displayEndpoint,
                        serverContext: String(localized: "主机：\(server.name)（\(server.displayEndpoint)）",
                                              comment: "附给 Agent 的上下文：当前主机名与地址"),
                        safety: safetyBinding,
                        activeProviderIDString: $activeProviderIDString,
                        onOpenSettings: { openWindow(id: SettingsWindow.id) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .udCard()
            .padding(.horizontal, UD.Layout.cardInset)
            StatusBarView(workspace: workspace)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.pageBg)
        .background(WorkspaceWindowChrome(
            serverName: ServerChromeTitle.terminalWindowTitle(serverName: server.name,
                                                              groupName: server.group),
            background: WS.canvasNSColor))
        .background(WorkspaceCloseShortcutInstaller { window in
            handleCloseShortcut(window: window)
        })
        .background(HeldWindowTrackerBinding(tracker: workspace.windowTracker))
        // 关窗前先存编辑器里改了没存的文件（自动保存还没到点的那一秒也算）。
        .background(EditorWindowCloseGuardInstaller(models: { [workspace.filePreviewModel] }))
        .background(TerminalWindowCloseGuardInstaller(sessions: { workspace.terminalSessions }))
        .commandPalette(model: palette) { terminalCommandItems(server: server) }
        // 把本窗口的终端会话接进跨窗口注册表（CLI 的 terminals / read / send）。
        .modifier(TerminalRegistryBinding(
            workspace: workspace,
            windowID: windowID.id,
            windowKind: TerminalWindowKind.terminal))
        // 登记成「在终端中打开」的落点：别处打开主机时作为新标签送进来。
        .background(TerminalWindowRouterBinding(windowID: windowID.id) { serverID in
            openTab(serverID: serverID)
        })
        .onChange(of: controlActiveState, initial: true) { _, state in
            if state == .key { TerminalWindowRouter.shared.markActive(windowID: windowID.id) }
        }
        .onChange(of: workspace.focusedTerminalServerID) { _, id in
            if let id { lastServerID = id }
        }
        .task {
            // 仅首次：上次留下的会话放回来；没有就把开窗口时带来的那台主机作为第一个标签。
            // 窗格连接由 PaneView 自身的 .task 走共享 modelContainer 自动建立（与工作区窗口同路径）。
            guard !didOpen else { return }
            didOpen = true
            // 终端里 ⌘ 点的路径 / 程序请求预览的文件开在终端区，按那个终端的主机读。
            workspace.makeFileProvider = WorkspaceModel.liveFileProvider(container: modelContext.container)
            workspace.connectCodeRun = WorkspaceModel.liveCodeRunConnector(container: modelContext.container)
            let heldSessions = await SSHSessionRestorer.shared.claim(windowID: windowID.id)
            if heldSessions.isEmpty {
                openTab(serverID: windowID.serverID)
            } else {
                workspace.adoptHeldSessions(heldSessions, knownServerIDs: Set(profiles.map(\.id)))
                workspace.reattachHeldSessions(heldSessions, profiles: profiles, modelContainer: modelContext.container)
            }
        }
        // Agent run_command 真实执行器：每台服务器解析一次认证材料并注入。
        // 失败（缺密码 / 私钥等）→ try? 吞掉、executor 留 nil → Agent 退化为纯文本对话。
        .task(id: server.id) {
            guard !isCatalog else { return }
            workspace.assistantModel.executor = (try? WorkspaceCommandExecutorFactory.make(
                server: server, container: modelContext.container))?.executor
        }
        .onDisappear {
            guard !isCatalog else { return }
            workspace.dispose()
        }
        // 全局 CommandGroup 通知广播到所有窗口；controlActiveState == .key 守卫，只让
        // 前台窗口响应。分屏命令仅终端模式生效。
        // ⌘S：终端区里的文件标签（⌘ 点的路径、程序请求预览的文件）。编辑器聚焦时通知里带着正在编辑的文档。
        .onReceive(NotificationCenter.default.publisher(for: .savePreviewBuffer)) { note in
            guard controlActiveState == .key else { return }
            let requested = note.userInfo?[SavePreviewBufferKey.bufferID] as? UUID
            guard let id = requested ?? workspace.activeTerminalFileBufferID,
                  workspace.filePreviewModel.owns(id) else { return }
            Task { await workspace.filePreviewModel.saveInteractively(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTerminalTab)) { _ in
            guard controlActiveState == .key else { return }
            workspace.openServer(profileID: server.id, title: server.name)
            mode = .terminal
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneHorizontal)) { _ in
            guard controlActiveState == .key, mode == .terminal else { return }
            workspace.splitActiveGroup(direction: .horizontal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneVertical)) { _ in
            guard controlActiveState == .key, mode == .terminal else { return }
            workspace.splitActiveGroup(direction: .vertical)
        }
        .modifier(AssistantBindingModifier(
            assistant: workspace.assistantModel,
            providers: providers,
            activeProviderIDString: activeProviderIDString))
    }

    /// 在活动组里开一个连 `serverID` 的新标签并切回终端模式。主机已被删除则忽略。
    private func openTab(serverID: UUID) {
        guard let profile = profiles.first(where: { $0.id == serverID }) else { return }
        workspace.openServer(profileID: profile.id, title: profile.name)
        mode = .terminal
    }

    /// ⌘W：终端模式按「关活动标签 → 最后一个标签关窗口」；Agent 模式关窗口。
    @MainActor
    private func handleCloseShortcut(window: NSWindow) {
        guard mode == .terminal else {
            window.performClose(nil)
            return
        }
        let groups = workspace.terminalGroups
        // 纯终端窗口没有「空终端区」这个有意义的状态：只剩一个组一个标签时
        // ⌘W 关窗口（对齐旧的「最后一个窗格 / 最后一个标签 → 关窗口」）。
        guard groups.groupCount > 1 || groups.allTabs.count > 1 else {
            window.performClose(nil)
            return
        }
        if let tab = groups.activeTab {
            workspace.requestCloseTerminalTab(tab.id)
        } else if !workspace.closeActiveTerminalTab() {
            window.performClose(nil)
        }
    }

    /// ⌘K 命令面板：终端布局相关命令（对齐设计稿 terminal.jsx 的命令面板）。
    @MainActor
    private func terminalCommandItems(server: ServerProfile) -> [CommandPaletteItem] {
        let single = workspace.terminalGroups.groupCount <= 1
        return [
            CommandPaletteItem(id: "term.splitH", kind: .command,
                               title: String(localized: "向右分屏"), detail: "", hint: "⌘D", group: nil) {
                mode = .terminal
                workspace.splitActiveGroup(direction: .horizontal)
            },
            CommandPaletteItem(id: "term.splitV", kind: .command,
                               title: String(localized: "向下分屏"), detail: "", hint: "⇧⌘D", group: nil) {
                mode = .terminal
                workspace.splitActiveGroup(direction: .vertical)
            },
            CommandPaletteItem(id: "term.closePane", kind: .command,
                               title: String(localized: "关闭当前终端标签页"),
                               detail: single ? String(localized: "仅一个分组") : "", hint: "⌘W", group: nil) {
                workspace.requestCloseActiveTerminalTab()
            },
            CommandPaletteItem(id: "term.newTab", kind: .command,
                               title: String(localized: "新建终端标签页"), detail: "", hint: "⌘T", group: nil) {
                workspace.openServer(profileID: server.id, title: server.name)
                mode = .terminal
            },
            CommandPaletteItem(id: "term.agent", kind: .command,
                               title: String(localized: "切换到 Agent 模式"), detail: String(localized: "用自然语言操作"),
                               hint: "", group: nil) {
                mode = .agent
            },
            CommandPaletteItem(id: "term.code", kind: .command,
                               title: CodeTabButton.title,
                               detail: String(localized: "查看这台主机上编码工具的历史会话"),
                               hint: "", group: nil) {
                mode = .terminal
                let names = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                workspace.openCodeTab(fallbackServerID: server.id) { names[$0] ?? server.name }
            },
        ] + hostCommandItems()
    }

    /// 命令面板里的主机：选中即在本窗口开一个连它的新标签。
    @MainActor
    private func hostCommandItems() -> [CommandPaletteItem] {
        profiles
            .filter { !$0.sftpOnly }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { profile in
                let id = profile.id
                return CommandPaletteItem(
                    id: "host.\(id.uuidString)", kind: .host,
                    title: profile.name.isEmpty ? profile.host : profile.name,
                    detail: profile.displayEndpoint,
                    hint: String(localized: "新标签页", comment: "命令面板提示：在新标签页中打开这台主机"), group: profile.group) {
                        openTab(serverID: id)
                    }
            }
    }
}

// MARK: - 路由登记

/// 把终端窗口登记进 `TerminalWindowRouter`：视图挂上窗口时登记（带上 `NSWindow`，
/// 好在送标签时把它带到前台），离开窗口时注销。
private struct TerminalWindowRouterBinding: NSViewRepresentable {
    let windowID: UUID
    let openTab: @MainActor (UUID) -> Void

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(windowID: windowID, openTab: openTab)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.openTab = openTab
        nsView.registerIfNeeded()
    }

    final class ProbeView: NSView {
        let windowID: UUID
        var openTab: @MainActor (UUID) -> Void

        init(windowID: UUID, openTab: @escaping @MainActor (UUID) -> Void) {
            self.windowID = windowID
            self.openTab = openTab
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                TerminalWindowRouter.shared.unregister(windowID: windowID)
            } else {
                registerIfNeeded()
            }
        }

        /// 闭包每次 update 都可能换新（捕获的视图值变了），所以每次都重登一遍；
        /// 路由按 id 覆盖，不会重复。
        func registerIfNeeded() {
            guard let window else { return }
            TerminalWindowRouter.shared.register(windowID: windowID, window: window) { [weak self] serverID in
                self?.openTab(serverID)
            }
        }
    }
}

// MARK: - 标题栏

/// 终端窗口自绘标题栏：左让位红绿灯 + 「终端 | Agent」分段开关；居中主机 · 已连接；
/// 右端口转发。38px，分区方案 v3：画在窗口画布上，无底色、无分隔线。
struct TerminalWindowTitleBar: View {
    let host: String
    let session: TerminalSession?
    @Binding var mode: TerminalWindowContentMode
    let activeForwardCount: Int
    let onOpenForwarding: () -> Void

    /// 左边那一簇（红绿灯让位 + 模式开关）有多宽：居中的主机名两侧都让出这么多，窗口窄时截短主机名，不压到开关上。
    @State private var leadingWidth: CGFloat = 0

    var body: some View {
        ZStack {
            // 居中：主机 mono + 连接状态胶囊
            HStack(spacing: 9) {
                Text(host)
                    .font(UD.mono(13))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let session {
                    WSStatusPill(state: session.connectionState)
                        .fixedSize()
                }
            }
            .padding(.horizontal, leadingWidth + 16)
            // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动（见 WindowDragHandle）。
            .allowsHitTesting(false)

            // 两侧簇
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 68)   // 让位窗口红绿灯
                    TerminalModeToggle(mode: $mode)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
                Spacer()
                ZStack(alignment: .topTrailing) {
                    WSIconButton(systemName: "arrow.left.arrow.right",
                                 help: String(localized: "端口转发"), action: onOpenForwarding)
                    if activeForwardCount > 0 {
                        UDCountBadge(activeForwardCount, accent: true)
                            .scaleEffect(0.72)
                            .offset(x: 6, y: -5)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle(fill: WS.canvasNSColor))
    }
}

/// 「终端 | Agent」分段开关（对齐设计稿 terminal.jsx 的 ModeTab）：激活段 accent 底 + 白字。
/// 「Agent」是名字，五种语言都不翻译。
struct TerminalModeToggle: View {
    @Binding var mode: TerminalWindowContentMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.terminal, label: String(localized: "终端", comment: "终端 / Agent 模式切换"), systemImage: "terminal")
            segment(.agent, label: "Agent", systemImage: "sparkles")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillFaint))
    }

    private func segment(_ m: TerminalWindowContentMode, label: String, systemImage: String) -> some View {
        let active = mode == m
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) { mode = m }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(active ? .white : UD.text3)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? UD.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}
