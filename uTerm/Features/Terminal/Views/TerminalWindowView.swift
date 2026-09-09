import UPaneGroups
import UPaneTree
import UDesignKit
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

            // 内容区两态切换；分隔线 + 状态栏两态共用，提到 switch 外避免重复。
            switch mode {
            case .terminal:
                TerminalArea(workspace: workspace, server: server)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .agent:
                TerminalAgentView(
                    model: workspace.assistantModel,
                    host: server.displayEndpoint,
                    serverContext: "服务器：\(server.name)（\(server.displayEndpoint)）",
                    safety: safetyBinding,
                    activeProviderIDString: $activeProviderIDString,
                    onOpenSettings: { openWindow(id: SettingsWindow.id) })
            }
            Rectangle().fill(UD.border).frame(height: 1)
            StatusBarView(workspace: workspace)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: chromeTitle))
        .background(WorkspaceCloseShortcutInstaller { window in
            handleCloseShortcut(window: window)
        })
        .commandPalette(model: palette) { terminalCommandItems(server: server) }
        // 把本窗口的终端会话接进跨窗口注册表（CLI 的 terminals / read / send）。
        .modifier(TerminalRegistryBinding(
            workspace: workspace,
            windowID: windowID?.id ?? server.id,
            windowKind: TerminalWindowKind.terminal))
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
            workspace.assistantModel.executor = (try? WorkspaceCommandExecutorFactory.make(
                server: server, container: modelContext.container))?.executor
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
        if workspace.closeActiveTerminalTab() { return }
        window.performClose(nil)
    }

    /// ⌘K 命令面板：终端布局相关命令（对齐设计稿 terminal.jsx 的命令面板）。
    @MainActor
    private func terminalCommandItems(server: ServerProfile) -> [CommandPaletteItem] {
        let single = workspace.terminalGroups.groupCount <= 1
        return [
            CommandPaletteItem(id: "term.splitH", kind: .command,
                               title: "向右分屏", detail: "", hint: "⌘D", group: nil) {
                mode = .terminal
                workspace.splitActiveGroup(direction: .horizontal)
            },
            CommandPaletteItem(id: "term.splitV", kind: .command,
                               title: "向下分屏", detail: "", hint: "⌘⇧D", group: nil) {
                mode = .terminal
                workspace.splitActiveGroup(direction: .vertical)
            },
            CommandPaletteItem(id: "term.closePane", kind: .command,
                               title: "关闭当前终端标签", detail: single ? "仅一个分组" : "", hint: "⌘W", group: nil) {
                _ = workspace.closeActiveTerminalTab()
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
            // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动（见 WindowDragHandle）。
            .allowsHitTesting(false)

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
