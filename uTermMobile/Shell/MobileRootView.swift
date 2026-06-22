import SwiftUI
import SwiftData

/// 自适应外壳：iPhone（compact）底部标签栏 + 各标签独立导航栈；
/// iPad（regular）侧栏 + 详情的 `NavigationSplitView`。
struct MobileRootView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var store = MobileStore()
    /// host-key 信任挑战桥：终端 / SFTP 控制器共用一份，根视图据此弹出信任弹层。
    @State private var hostKeyRelay = HostKeyChallengeRelay()
    /// 终端会话集合在根视图持有（高于 compact/regular 外壳切换），横屏切 size class 时不丢会话。
    @State private var terminalSessions = TerminalSessions()
    /// SFTP 会话同理在根视图持有，横屏切 size class 时不丢会话 / 不退回根目录。
    @State private var sftpSession = MobileSFTPSession()

    var body: some View {
        @Bindable var store = store
        Group {
            if hSize == .regular {
                MobileSplitShell()
            } else {
                MobileTabShell()
            }
        }
        .environment(store)
        .environment(hostKeyRelay)
        .environment(terminalSessions)
        .environment(sftpSession)
        .environment(\.mAccent, M.accent)
        .tint(M.accent)
        // ⌘K 硬件快捷键（iPad 外接键盘）：唤起命令面板。
        .background {
            Button("命令面板") { store.showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
        }
        // 命令面板 ⌘K：在所有标签之上以全屏覆盖呈现。
        .fullScreenCover(isPresented: $store.showPalette) {
            CommandPaletteView()
                .environment(store)
                .environment(\.mAccent, M.accent)
                .tint(M.accent)
        }
        // 并行执行：命令详情「运行」触发，全屏覆盖呈现真实多台广播。
        .fullScreenCover(item: $store.parallelRun) { req in
            ParallelRunView(request: req) { store.parallelRun = nil }
                .environment(store)
                .environment(\.mAccent, M.accent)
                .tint(M.accent)
        }
        // 连接中页：选定主机后、会话/文件浏览打开前的全屏中转页（防误触打断半开连接）。
        // 用 overlay（非 fullScreenCover）以便下面的主机密钥信任弹层仍能叠在其上。
        .overlay {
            if let req = store.connecting {
                ConnectingCoverView(
                    request: req,
                    onFinish: { store.finishConnect() },
                    onCancel: { store.cancelConnect() },
                    onRetry: { store.retryConnect() })
                    .environment(store)
                    .environment(hostKeyRelay)
                    .environment(\.mAccent, M.accent)
                    .tint(M.accent)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: store.connecting?.id)
        // 主机密钥信任弹层：连接遇到首次 / 变化的密钥时，覆盖所有标签居中呈现。
        .overlay {
            if let challenge = hostKeyRelay.pendingChallenge {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    MCenterModalContainer(width: 400) {
                        HostKeyTrustModal(challenge: challenge,
                                          onCancel: { hostKeyRelay.resolve(false) },
                                          onTrust: { hostKeyRelay.resolve(true) })
                    }
                }
                .environment(\.mAccent, M.accent)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: hostKeyRelay.pendingChallenge)
    }
}

// MARK: - iPhone：底部标签栏（系统原生 TabView）

private struct MobileTabShell: View {
    @Environment(MobileStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.tab) {
            ForEach(MTab.allCases) { tab in
                tabContent(tab)
                    .tabItem { Label(tab.label, systemImage: MGlyph.symbol(tab.icon)) }
                    .tag(tab)
            }
        }
    }

    @ViewBuilder private func tabContent(_ tab: MTab) -> some View {
        switch tab {
        case .hosts:    HostsScreen()
        case .terminal: TerminalScreen()
        case .sftp:     SFTPScreen()
        case .commands: CommandsScreen()
        case .settings: SettingsScreen()
        }
    }
}

// MARK: - iPad：侧栏 + 详情

private struct MobileSplitShell: View {
    @Environment(MobileStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let selection = Binding<MTab?>(
            get: { store.tab },
            set: { if let v = $0 { store.tab = v } })
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach(MTab.allCases) { tab in
                        Label { Text(tab.label).font(M.sans(15, weight: .medium)) }
                        icon: { MIcon(name: tab.icon, size: 18, color: M.text2) }
                            .tag(tab)
                    }
                }
            }
            .navigationTitle("uTerm")
            .listStyle(.sidebar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.showPalette = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        } detail: {
            switch store.tab {
            case .hosts:    HostsScreen()
            case .terminal: TerminalScreen()
            case .sftp:     SFTPScreen()
            case .commands: CommandsScreen()
            case .settings: SettingsScreen()
            }
        }
    }
}
