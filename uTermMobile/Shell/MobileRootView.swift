import SwiftUI
import SwiftData

/// 自适应外壳：**一棵**系统 `TabView`（`.sidebarAdaptable`）。紧凑宽度（iPhone、iPhone Duo
/// 外屏 / 内屏分屏）是标签栏；常规宽度（iPad、iPhone Duo 展开）默认是侧栏，可收成顶部标签条。
///
/// 改前是按 `horizontalSizeClass` 在 `TabView` 与 `NavigationSplitView` 两套外壳间二选一：
/// size class 一翻（Plus/Max 横屏、iPhone Duo 开合），整棵标签内容树换了身份、全部重建，
/// 各屏的 `@State`（筛选、滚动位置、正在填的表单抽屉、确认框……）随之丢失。终端 / SFTP 会话
/// 为此上移到了本视图，但其它屏没有。iPhone Duo 一天要开合很多次，这类丢失会被放大，
/// 所以改成同一棵 `TabView` 让系统自己在标签栏 ⇄ 侧栏之间变形，内容视图身份不变。
/// 会话状态仍留在根视图持有（不依赖外壳是否重建，属于兜底）。
struct MobileRootView: View {
    @State private var store = MobileStore()
    /// host-key 信任挑战桥：终端 / SFTP 控制器共用一份，根视图据此弹出信任弹层。
    @State private var hostKeyRelay = HostKeyChallengeRelay()
    /// 会话工作区（终端 + 文件浏览标签、分屏）在根视图持有（高于标签栏 ⇄ 侧栏外壳），
    /// 横屏切 size class 时不丢会话 / 不退回根目录。
    @State private var workspace = MobileWorkspace()

    var body: some View {
        @Bindable var store = store
        ZStack {
            MobileTabShell()
            // 会话工作区：终端 / 文件标签与分屏，全屏盖住标签栏。常驻挂载（收起时移到屏外），
            // 这样会话、滚动位置与各格的视图状态都不随收起丢失；连接请求也随时有人消费。
            WorkspaceLayer()
        }
        .environment(store)
        .environment(hostKeyRelay)
        .environment(workspace)
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
                    M.backdrop.ignoresSafeArea()
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

// MARK: - 外壳：标签栏 ⇄ 侧栏自适应（系统原生 TabView）

private struct MobileTabShell: View {
    @Environment(MobileStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.tab) {
            ForEach(MTab.allCases) { tab in
                Tab(tab.label, systemImage: MGlyph.symbol(tab.icon), value: tab) {
                    tabContent(tab)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // 侧栏头：品牌名 + 命令面板入口（改前挂在 NavigationSplitView 侧栏的工具栏上）。
        .tabViewSidebarHeader {
            HStack(spacing: 8) {
                Text("uTerm").font(M.sans(22, weight: .bold)).foregroundStyle(M.text)
                Spacer(minLength: 0)
                Button { store.showPalette = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: M.minTarget, height: M.minTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("命令面板"))
            }
        }
    }

    @ViewBuilder private func tabContent(_ tab: MTab) -> some View {
        switch tab {
        case .hosts:    HostsScreen()
        case .commands: CommandsScreen()
        case .settings: SettingsScreen()
        }
    }
}

// MARK: - 工作区层

/// 收起时整层平移到屏幕右侧之外、不可点、读屏跳过；展开时从右侧推入（与下钻同向）。
private struct WorkspaceLayer: View {
    @Environment(MobileStore.self) private var store

    var body: some View {
        let visible = store.showWorkspace
        WorkspaceScreen()
            .background(M.surface.ignoresSafeArea())
            // 收起时要整层（连同伸进安全区的底色）都移出屏幕：proxy.size 不含安全区，只移
            // size.width 的话，`.background(…ignoresSafeArea())` 伸进右侧安全区的那一截还留在
            // 屏上。iPhone Duo 的标签栏 / 工具栏按钮恰好在右侧安全区那一列，于是被这截底色整列
            // 盖住、看上去侧边导航栏没了（实机反馈）。
            .visualEffect { content, proxy in
                let insets = proxy.safeAreaInsets
                return content.offset(x: visible ? 0 : proxy.size.width + insets.leading + insets.trailing)
            }
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(.easeInOut(duration: 0.28), value: visible)
    }
}
