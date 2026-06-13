import SwiftUI
import SwiftData
import AppKit

/// 终端窗口内容区两态：纯终端窗格 ⇄ Agent 自然语言。
enum TerminalWindowContentMode: Hashable { case terminal, agent }

/// 一个独立「纯终端」窗口：绑定单台服务器（由 `TerminalWindowID` 指定）。
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
    @AppStorage("activeProviderID") private var activeProviderIDString: String = ""
    @AppStorage("agentSafety") private var agentSafetyRaw: String = AgentSafety.readAuto.rawValue

    @State private var workspace = WorkspaceModel()
    @State private var mode: TerminalWindowContentMode = .terminal
    @State private var didOpen = false
    @State private var palette = CommandPaletteModel()

    @Environment(\.modelContext) private var modelContext
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(ForwardingCoordinator.self) private var forwarding

    private var server: ServerProfile? {
        guard let id = windowID?.serverID else { return nil }
        return profiles.first { $0.id == id }
    }

    private var safetyBinding: Binding<AgentSafety> {
        Binding(get: { AgentSafety(rawValue: agentSafetyRaw) ?? .readAuto },
                set: { agentSafetyRaw = $0.rawValue })
    }

    var body: some View {
        Group {
            if windowID != nil, let server {
                terminalBody(server: server)
            } else {
                ContentUnavailableView(windowID == nil ? "正在恢复…" : "服务器已删除",
                                       systemImage: windowID == nil ? "clock" : "server.rack")
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder
    private func terminalBody(server: ServerProfile) -> some View {
        let chromeTitle = ServerChromeTitle.serverTitle(serverName: server.name, groupName: server.group)
        VStack(spacing: 0) {
            TerminalWindowTitleBar(
                host: server.displayEndpoint,
                session: workspace.focusedTerminalSession(),
                mode: $mode,
                activeForwardCount: forwarding.activeCount(forServer: server.id),
                onOpenForwarding: {
                    openWindow(value: PortForwardWindowID(id: UUID(), serverID: server.id))
                },
                onDisconnect: { dismiss() })

            switch mode {
            case .terminal:
                TerminalArea(workspace: workspace, server: server)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(UD.border).frame(height: 1)
                TerminalWindowStatusBar(workspace: workspace, server: server)
            case .agent:
                TerminalAgentView(
                    model: workspace.assistantModel,
                    host: server.displayEndpoint,
                    serverContext: "服务器：\(server.name)（\(server.displayEndpoint)）",
                    safety: safetyBinding,
                    activeProviderIDString: $activeProviderIDString,
                    onOpenSettings: { openWindow(id: SettingsWindow.id) })
                Rectangle().fill(UD.border).frame(height: 1)
                TerminalAgentStatusBar(model: workspace.assistantModel,
                                       host: server.displayEndpoint,
                                       safety: safetyBinding.wrappedValue)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: chromeTitle))
        .background(WorkspaceCloseShortcutInstaller { window in
            handleCloseShortcut(window: window)
        })
        .commandPalette(model: palette) { terminalCommandItems(server: server) }
        .task {
            // 仅首次：开一个默认终端标签。窗格连接由 PaneView 自身的 .task 走
            // 共享 modelContainer 自动建立（与工作区窗口同路径）。
            guard !didOpen else { return }
            didOpen = true
            workspace.openServer(profileID: server.id, title: server.name)
        }
        // Agent run_command 真实执行器：每台服务器解析一次认证材料并注入。
        // 失败（缺密码 / 私钥等）→ try? 吞掉、executor 留 nil → Agent 退化为纯文本对话。
        .task(id: server.id) {
            workspace.assistantModel.executor = try? WorkspaceCommandExecutorFactory.make(
                server: server, container: modelContext.container)
        }
        .onDisappear { workspace.dispose() }
        // 全局 CommandGroup 通知广播到所有窗口；controlActiveState == .key 守卫，只让
        // 前台窗口响应。分屏命令仅终端模式生效。
        .onReceive(NotificationCenter.default.publisher(for: .newTerminalTab)) { _ in
            guard controlActiveState == .key else { return }
            workspace.openServer(profileID: server.id, title: server.name)
            mode = .terminal
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneHorizontal)) { _ in
            guard controlActiveState == .key, mode == .terminal else { return }
            workspace.activeTab?.splitFocusedPane(direction: .horizontal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneVertical)) { _ in
            guard controlActiveState == .key, mode == .terminal else { return }
            workspace.activeTab?.splitFocusedPane(direction: .vertical)
        }
        .modifier(AssistantBindingModifier(
            assistant: workspace.assistantModel,
            providers: providers,
            activeProviderIDString: activeProviderIDString))
    }

    /// ⌘W：终端模式按「关聚焦窗格 → 最后窗格关标签 → 最后标签关窗口」；Agent 模式关窗口。
    @MainActor
    private func handleCloseShortcut(window: NSWindow) {
        guard mode == .terminal, let tab = workspace.activeTab else {
            window.performClose(nil)
            return
        }
        // closePane 返回 true = 关掉了一个分屏窗格；false = 该窗格是最后一个（未关）。
        if let pid = tab.focusedPaneID, tab.closePane(pid) { return }
        if workspace.tabs.count > 1 {
            workspace.closeTab(tab.id)
        } else {
            window.performClose(nil)
        }
    }

    /// ⌘K 命令面板：终端布局相关命令（对齐设计稿 terminal.jsx 的命令面板）。
    @MainActor
    private func terminalCommandItems(server: ServerProfile) -> [CommandPaletteItem] {
        let single = (workspace.activeTab?.root.leafCount ?? 1) <= 1
        return [
            CommandPaletteItem(id: "term.splitH", kind: .command,
                               title: "向右分屏当前窗格", detail: "", hint: "⌘D", group: nil) {
                mode = .terminal
                workspace.activeTab?.splitFocusedPane(direction: .horizontal)
            },
            CommandPaletteItem(id: "term.splitV", kind: .command,
                               title: "向下分屏当前窗格", detail: "", hint: "⌘⇧D", group: nil) {
                mode = .terminal
                workspace.activeTab?.splitFocusedPane(direction: .vertical)
            },
            CommandPaletteItem(id: "term.closePane", kind: .command,
                               title: "关闭当前窗格", detail: single ? "仅一个窗格" : "", hint: "⌘W", group: nil) {
                if let tab = workspace.activeTab, let pid = tab.focusedPaneID {
                    _ = tab.closePane(pid)
                }
            },
            CommandPaletteItem(id: "term.newTab", kind: .command,
                               title: "新建终端标签", detail: "", hint: "⌘T", group: nil) {
                workspace.openServer(profileID: server.id, title: server.name)
                mode = .terminal
            },
            CommandPaletteItem(id: "term.agent", kind: .command,
                               title: "切换到 Agent 模式", detail: "用自然语言操作", hint: "", group: nil) {
                mode = .agent
            },
        ]
    }
}

// MARK: - 标题栏

/// 终端窗口自绘标题栏：左让位红绿灯 + 「终端 ⇄ Agent」分段开关；居中主机 · 已连接；
/// 右端口转发 · 断开。38px 扁平条 + 底 1px 描边（与工作区 / SFTP 窗口同构）。
struct TerminalWindowTitleBar: View {
    let host: String
    let session: TerminalSession?
    @Binding var mode: TerminalWindowContentMode
    let activeForwardCount: Int
    let onOpenForwarding: () -> Void
    let onDisconnect: () -> Void

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
                }
            }

            // 两侧簇
            HStack(spacing: 8) {
                Color.clear.frame(width: 68)   // 让位窗口红绿灯
                TerminalModeToggle(mode: $mode)
                Spacer()
                ZStack(alignment: .topTrailing) {
                    WSIconButton(systemName: "arrow.left.arrow.right",
                                 help: "端口转发", action: onOpenForwarding)
                    if activeForwardCount > 0 {
                        UDCountBadge(activeForwardCount, accent: true)
                            .scaleEffect(0.72)
                            .offset(x: 6, y: -5)
                            .allowsHitTesting(false)
                    }
                }
                WSIconButton(systemName: "power", help: "断开并关闭窗口", action: onDisconnect)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}

/// 「终端 | Agent」分段开关（对齐设计稿 terminal.jsx 的 ModeTab）：激活段 accent 底 + 白字。
struct TerminalModeToggle: View {
    @Binding var mode: TerminalWindowContentMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.terminal, label: "终端", systemImage: "terminal")
            segment(.agent, label: "Agent", systemImage: "sparkles")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillFaint))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UD.border, lineWidth: 1))
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
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 状态栏

/// 终端模式状态栏（mono）：主机 · :端口 · SSH-2.0 · UTF-8 · N 窗格 · 时钟。
struct TerminalWindowStatusBar: View {
    let workspace: WorkspaceModel
    let server: ServerProfile

    private var paneCount: Int { workspace.activeTab?.root.leafCount ?? 0 }
    private var session: TerminalSession? { workspace.focusedTerminalSession() }
    private var dotColor: Color {
        guard let session else { return UD.text4 }
        return ConnectionStatusDisplay(state: session.connectionState).tint.color
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(server.displayEndpoint)
            }
            Text(":\(server.port)").foregroundStyle(UD.text4)
            Text("SSH-2.0")
            Spacer(minLength: 8)
            Text("UTF-8")
            Text("\(paneCount) 窗格").foregroundStyle(UD.text2)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.clockFormatter.string(from: ctx.date)).foregroundStyle(UD.text4)
            }
        }
        .font(UD.mono(11))
        .foregroundStyle(UD.text3)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(UD.panel)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Agent 模式状态栏（mono）：主机 · 模型 · 安全档位。
struct TerminalAgentStatusBar: View {
    let model: AssistantModel
    let host: String
    let safety: AgentSafety

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(UD.success).frame(width: 6, height: 6)
                Text(host)
            }
            if let p = model.activeProvider {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(UD.accent)
                    Text(p.model.isEmpty ? p.name : p.model).foregroundStyle(UD.text2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 10))
                Text(safety.label)
            }
        }
        .font(UD.mono(11))
        .foregroundStyle(UD.text3)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(UD.panel)
    }
}
