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
    /// 终端状态上灵动岛 / 锁屏、后台提醒、「离开后继续运行」。
    @State private var activityCenter = TerminalActivityCenter()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var store = store
        ZStack {
            MobileTabShell()
            // 会话工作区：终端 / 文件标签与分屏，全屏盖住标签栏。常驻挂载（收起时移到屏外），
            // 这样会话、滚动位置与各格的视图状态都不随收起丢失；连接请求也随时有人消费。
            WorkspaceLayer()
            // App 被系统结束后重新打开：把上次的终端标签开回来，接回主机上还在跑的会话。
            MobileTerminalTabRestorer()
            #if DEBUG
            MLayoutDiagnosticsOverlay()
            #endif
        }
        // 灵动岛 / 锁屏 / 通知点进来：切到那个终端标签页。
        .modifier(TerminalActivityLinkHandler())
        .task {
            activityCenter.start(workspace: workspace)
            #if DEBUG
            TerminalActivityDemo.open(in: workspace, store: store, container: modelContext.container,
                                      center: activityCenter)
            #endif
        }
        .environment(activityCenter)
        .environment(store)
        .environment(hostKeyRelay)
        .environment(workspace)
        .mobileLANSyncHost()
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
        // 并行执行：命令详情「运行」触发，全屏覆盖呈现真实多台广播。会话由 store 持有，
        // 关掉全屏页也继续跑；再次打开拿回同一个控制器（不会重跑）。
        .fullScreenCover(item: $store.presentedParallel) { session in
            ParallelRunView(request: session.request,
                            controller: session.controller,
                            onControllerReady: { session.controller = $0 },
                            onRerun: { store.parallelRerun(session) },
                            onClose: { store.closeParallel(session) })
                .environment(store)
                .environment(\.mAccent, M.accent)
                .tint(M.accent)
        }
        // 远程桌面：看 / 控制 Mac 的屏幕，全屏覆盖（横竖屏都可用）。
        .fullScreenCover(item: $store.remoteDesktop) { req in
            RemoteDesktopScreen(client: req.client, tappedAt: req.tappedAt, started: req.session,
                                initialWindow: req.windowID) {
                store.remoteDesktop = nil
            }
                .environment(\.mAccent, M.accent)
                .tint(M.accent)
        }
        // 连接中页：选定主机后、会话/文件浏览打开前的全屏中转页（防误触打断半开连接）。
        // 用 overlay（非 fullScreenCover）以便下面的主机密钥信任弹层仍能叠在其上。
        .overlay {
            // 分屏时在工作区里新开的标签：连接中页只盖那个标签（WorkspaceScreen 自己画），
            // 另一格照常可用。其余（从主机列表进来、没分屏）照旧盖满整屏。
            if let req = store.connecting, !req.showsInPane(workspace, workspaceVisible: store.showWorkspace) {
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
        .animation(.easeOut(duration: 0.18), value: store.connecting?.id)
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
        // 后台运行中的并行执行：标签栏上方一条（iOS 26.1 起用系统的底部附件，与「音乐」正在播放同款）。
        .modifier(ParallelRunAccessoryHost())
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
    @Environment(\.mChrome) private var chrome

    var body: some View {
        let visible = store.showWorkspace
        let screen = chrome.screen
        let leadingInset = chrome.safeAreaInsets.leading
        WorkspaceScreen()
            .background(M.surface.ignoresSafeArea())
            // 收起时整层（连同伸进安全区的底色）移到屏幕右缘之外。按根视图量到的整屏矩形算，
            // 不按 visualEffect 里的安全区算：iPhone Duo 横屏 / 折叠时状态栏那一列在右侧安全区，
            // 而这里拿到的安全区不含它，只移 `宽 + 安全区` 会让工作区最左那一截（返回钮、
            // 第一个标签）留在那一列里（实机：有标签时返回主机列表，右侧多出半条标签条）。
            .visualEffect { content, proxy in
                guard !visible else { return content.offset(x: 0) }
                let insets = proxy.safeAreaInsets
                let byInsets = proxy.size.width + insets.leading + insets.trailing
                let byScreen = screen.width > 0
                    ? screen.maxX - proxy.frame(in: .global).minX + leadingInset
                    : 0
                return content.offset(x: max(byInsets, byScreen))
            }
            // 兜底：收起后整层透明。滑出与淡出同步，看上去仍是推出；任何没跟着平移走的部分
            // （例如宿主 UIKit 视图）也不会留在屏上。
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(.easeInOut(duration: 0.28), value: visible)
    }
}
