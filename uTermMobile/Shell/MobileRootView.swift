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
    /// 订阅门禁：交给 `MobileStore`，「开始用」的入口都经它（`MobileStore.admits`）。
    @Environment(SubscriptionStore.self) private var subscriptions: SubscriptionStore?

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
        .onAppear { store.subscription = subscriptions }
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
        #if DEBUG || UTERM_BENCH
        .task { await WorkspaceSlideBench.runIfRequested(store: store) }
        #endif
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
                                          onCancel: { hostKeyRelay.resolve(false, for: challenge.id, byUser: true) },
                                          onTrust: { hostKeyRelay.resolve(true, for: challenge.id, byUser: true) })
                    }
                }
                .environment(\.mAccent, M.accent)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: hostKeyRelay.pendingChallenge)
        // 根视图在就有人看得到这一问（`HostKeyChallengeRelay.isPresented`）。
        .onAppear { hostKeyRelay.presenterAppeared() }
        .onDisappear { hostKeyRelay.presenterDisappeared() }
    }
}

// MARK: - 外壳：标签栏 ⇄ 侧栏自适应（系统原生 TabView）

struct MobileTabShell: View {
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
struct WorkspaceLayer: View {
    @Environment(MobileStore.self) private var store

    var body: some View {
        let visible = store.showWorkspace
        WorkspaceSlideHost(visible: visible)
            // 整屏：工作区在自己的宿主里按窗口算安全区与键盘，外层不再替它让一次（否则键盘让两遍）。
            .ignoresSafeArea()
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    /// 展开 / 收起滑动的时长。
    static let slideSeconds = 0.28
    /// 多久算滑完、停稳（动画时长再留一点余量）。重活等到这之后：收起时主机页的工具栏按钮、真关标签、
    /// 收键盘，展开时新开的终端拿键盘（见 `WorkspaceScreen`）。
    static let slideSettleSeconds = slideSeconds + 0.06
    static let slideSettle: Duration = .seconds(slideSettleSeconds)
}

/// 工作区放进自己的 `UIHostingController`，滑动交给 Core Animation：动画在系统的渲染进程里插值，
/// 主线程这时候忙（终端上下屏、盖旧帧、键盘交接、SwiftUI 重算）也不掉帧——和系统导航推入同一种做法。
///
/// 改前是 SwiftUI 的 `.offset` + `.opacity` 动画，每一帧都由主线程算一遍再提交，主线程一卡就掉帧
/// （vphone 120 Hz：滑进来 10 次掉 35–38 帧，其中 15–17 帧在滑的过程中）。
///
/// 外层的环境整份交给里面（`\.self`）：工作区下面用到的环境对象很多（主机目录、订阅、工作区、模型上下文……），
/// 逐个转交容易漏，漏一个就是运行时崩溃。
private struct WorkspaceSlideHost: UIViewControllerRepresentable {
    let visible: Bool

    func makeUIViewController(context: Context) -> WorkspaceSlideController {
        WorkspaceSlideController(rootView: content(context.environment), visible: visible)
    }

    func updateUIViewController(_ controller: WorkspaceSlideController, context: Context) {
        controller.hosting.rootView = content(context.environment)
        controller.setVisible(visible)
    }

    private func content(_ environment: EnvironmentValues) -> AnyView {
        AnyView(
            WorkspaceScreen()
                .background(M.surface.ignoresSafeArea())
                .environment(\.self, environment)
        )
    }
}

/// 宿主里的工作区只在呈现层上平移：模型层的位置始终贴着屏幕（收起 = 透明），安全区、键盘避让、
/// 尺寸都不随滑动变，SwiftUI 里面也就不会因为滑动重新布局。
final class WorkspaceSlideController: UIViewController {
    let hosting: UIHostingController<AnyView>
    private(set) var visible: Bool

    init(rootView: AnyView, visible: Bool) {
        hosting = UIHostingController(rootView: rootView)
        self.visible = visible
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        applyResting()
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        guard isViewLoaded else { return }
        guard view.window != nil, UIView.areAnimationsEnabled else { return applyResting() }
        slide(in: visible)
    }

    private static let slideKey = "uterm.workspace.slide"
    private static let fadeKey = "uterm.workspace.fade"

    /// 没有动画时直接落到终点。
    private func applyResting() {
        let layer = hosting.view.layer
        layer.removeAnimation(forKey: Self.slideKey)
        layer.removeAnimation(forKey: Self.fadeKey)
        hosting.view.alpha = visible ? 1 : 0
    }

    /// 收起时移到屏幕右缘之外：按窗口算，不按安全区算。iPhone Duo 横屏 / 折叠时状态栏那一列在右侧安全区，
    /// 只移「宽 + 安全区」会让工作区最左那一截（返回钮、第一个标签）留在那一列里。
    private var offscreenX: CGFloat {
        let width = hosting.view.bounds.width
        guard let window = view.window else { return width }
        let minX = hosting.view.convert(CGPoint.zero, to: window).x
        return max(width, window.bounds.maxX - minX)
    }

    /// 从当前呈现位置滑到终点。半路反向时接着当前的位置和透明度走，按剩下的路程折算时长。
    private func slide(in visible: Bool) {
        let layer = hosting.view.layer
        let distance = offscreenX
        // 停着的时候呈现层的平移也是 0（收起 = 原地透明），要从屏外进来；正在滑就从它此刻的位置接着走。
        let inFlight = layer.animation(forKey: Self.slideKey) != nil ? layer.presentation() : nil
        let currentX = (inFlight?.value(forKeyPath: "transform.translation.x") as? CGFloat)
            ?? (visible ? distance : 0)
        let currentAlpha = inFlight.map { CGFloat($0.opacity) } ?? (visible ? 0 : 1)
        let targetX: CGFloat = visible ? 0 : distance
        let remaining = distance > 0 ? min(1, abs(targetX - currentX) / distance) : 1
        let duration = WorkspaceLayer.slideSeconds * max(remaining, 0.2)
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)

        // 模型层：平移始终为 0（不动布局），透明度直接是终点；动画只改呈现层。
        layer.removeAnimation(forKey: Self.slideKey)
        layer.removeAnimation(forKey: Self.fadeKey)
        hosting.view.alpha = visible ? 1 : 0

        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = currentX
        slide.toValue = targetX
        slide.duration = duration
        slide.timingFunction = timing
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentAlpha
        fade.toValue = visible ? 1 : 0
        fade.duration = duration
        fade.timingFunction = timing
        layer.add(slide, forKey: Self.slideKey)
        layer.add(fade, forKey: Self.fadeKey)
    }
}
