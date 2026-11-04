import AppKit
import SwiftTerm
import SwiftUI
import UDesignKit
import UPaneGroups
import UPaneTree

/// 本机终端窗口的身份。一个窗口一棵分屏树，每个标签一个 shell；手机远控「新建终端」优先把标签加进
/// 最近活跃的本机终端窗口（见 `LocalShellWindowRouter`），没有才开新窗口。
nonisolated struct LocalShellWindowID: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    /// 第一个标签的会话 id。手机远控开窗口时预先定好，好按它等会话登记；为 nil 时窗口自己开一个。
    var firstPaneID: UUID?
}

/// 存在 holder 里的会话归属：App 重启后据此把标签放回原来的窗口。holder 只当它是不透明的数据。
nonisolated struct LocalShellSessionAttributes: Codable, Equatable, Sendable {
    var windowID: UUID
    var ordinal: Int
}

/// 本机 shell 在会话注册表里的身份。不对应任何 `ServerProfile`：`serverID` 用固定的哨兵值，
/// 手机据此认出「这是 Mac 本机」，不去自己的主机列表里找。
nonisolated enum LocalShellIdentity {
    static var serverID: UUID { RemoteConstants.localShellServerID }
    static let serverName = "本机"
}

/// 一个本机 shell 的会话：起 shell、登记到注册表、结束。`id` 就是注册表里的会话 id。
@MainActor
@Observable
final class LocalShellPane: Identifiable {
    let id: UUID
    let session = TerminalSession()
    /// 登录 shell 的名字（zsh / bash …），标题用。
    let shellName = (LocalShellPane.userShell() as NSString).lastPathComponent
    /// 窗口里的序号。开标签时定下、不随位置变：标签可以拖来拖去，名字不该跟着改。
    let ordinal: Int
    @ObservationIgnored private var registrar: TerminalSessionRegistrar?
    @ObservationIgnored private(set) var isDisposed = false

    /// 同名 shell 多开时名字带序号（zsh、zsh 2……），手机列表里分得清；shell 没设标题时标签也显示它。
    var defaultTitle: String { ordinal > 1 ? "\(shellName) \(ordinal)" : shellName }

    init(id: UUID = UUID(), ordinal: Int = 1) {
        self.id = id
        self.ordinal = ordinal
        session.onConnectionStateChange = { [weak self] state in
            self?.syncRegistration(state)
        }
    }

    func attach(_ registrar: TerminalSessionRegistrar) {
        self.registrar = registrar
        syncRegistration(session.connectionState)
    }

    func start() async {
        guard session.connectionState != .connected, session.connectionState != .connecting else { return }
        await session.close()
        let terminal = session.terminalView.getTerminal()
        let backend = LocalShellBackend(client: LocalShellService.shared.client, sessionID: id,
                                        columns: terminal.cols, rows: terminal.rows)
        await session.connect(using: backend)
        if let windowID = registrar?.windowID, session.backend === backend,
           let attributes = try? JSONEncoder().encode(LocalShellSessionAttributes(windowID: windowID, ordinal: ordinal)) {
            await backend.setAttributes(attributes)
        }
    }

    /// 关标签 / 关窗口：结束 shell。退出 App 时不走这里的结束（见 `LocalShellQuitPolicy`）：只断开，shell 留着下次接回。
    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        registrar?.unregister(paneID: id)
        // `session.dispose()` 会清掉 backend，之后 `session.close()` 就关不到它了，要先留一份。
        let backend = session.backend
        // 退出流程里异步任务不一定来得及跑，要同步把话说完。
        if LocalShellQuitPolicy.shared.isQuitting {
            finishForQuit(endingSession: LocalShellQuitPolicy.shared.endsSessionsOnQuit)
            session.dispose()
            if let held = backend as? any HeldTerminalBackend { Task { await held.detach() } }
        } else {
            session.dispose()
            Task { await backend?.close() }
        }
    }

    /// 退出流程的最后一步（`willTerminate`）：之后进程就没了，不能再指望异步任务。
    func finishForQuit(endingSession: Bool) {
        guard let held = session.backend as? any HeldTerminalBackend else { return }
        session.saveHeldCheckpointNow()
        if endingSession { held.holderLink.send(HolderFrame(.terminate)) }
        held.holderLink.flushAndClose(timeout: 0.5)
    }

    private func syncRegistration(_ state: TerminalSession.ConnectionState) {
        guard let registrar else { return }
        guard state == .connected else {
            registrar.unregister(paneID: id)
            return
        }
        registrar.register(paneID: id, serverID: LocalShellIdentity.serverID,
                           serverName: LocalShellIdentity.serverName, session: session)
    }

    /// 主程序在沙盒里读不到目录服务也没关系：只用来起标题，真正起哪个 shell 由辅助程序决定。
    nonisolated static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}

/// 一个本机终端窗口的布局：VSCode 编辑组模型，与 SSH 终端窗口同一套（`UPaneGroupsModel`）。
/// 标签 id 就是 `LocalShellPane.id`，也就是注册表里的会话 id。
@MainActor
@Observable
final class LocalShellWindowModel {
    let groups = UPaneGroupsModel<LocalShellPane>(policy: UPaneGroupsPolicy(
        splitButtonMaxGroups: nil,
        collapsesEmptyGroups: true,
        allowsLastGroupEmpty: true,
        releasesHiddenEditorFocusOnTabSwitch: true,
        keepAlive: TerminalPaneAreaTuning.keepAlive))
    @ObservationIgnored private var registrar: TerminalSessionRegistrar?
    private let startShell: @MainActor (LocalShellPane) -> Void

    var panes: [LocalShellPane] { groups.allTabs.map(\.payload) }
    var active: LocalShellPane? { groups.activeTab?.payload }

    init(startShell: @escaping @MainActor (LocalShellPane) -> Void = { pane in
        Task { await pane.start() }
    }) {
        self.startShell = startShell
        groups.onTabRemoved = { removed, _ in removed.payload.dispose() }
        // 组内唯一的标签拖到本组边缘 → 组件要一份克隆才分得出屏。shell 没法克隆，新开一个。
        groups.cloneTab = { [weak self] _ in self?.makeTab() }
        // 分屏按钮 / ⌘D 开的新组里放一个新 shell。
        groups.makeTabForNewGroup = { [weak self] in self?.makeTab() }
    }

    func attach(_ registrar: TerminalSessionRegistrar) {
        self.registrar = registrar
        for pane in panes { pane.attach(registrar) }
        syncFocus()
    }

    /// 在 `groupID`（默认活动组）新开一个标签并切过去，返回它的会话 id（可以预先指定）。
    @discardableResult
    func addTab(id: UUID = UUID(), ordinal: Int? = nil, in groupID: UUID? = nil) -> UUID {
        let tab = makeTab(id: id, ordinal: ordinal)
        groups.openTab({ tab }, in: groupID)
        return id
    }

    /// 关掉一个标签（连同它的 shell）。返回 false = 没有这个标签。
    @discardableResult
    func close(_ id: UUID) -> Bool {
        guard let at = groups.locateTab(id) else { return false }
        groups.closeTab(groupID: at.groupID, index: at.index)
        return true
    }

    func splitActiveGroup(direction: SplitDirection) {
        guard let groupID = groups.activeGroupID ?? groups.root.firstLeafID else { return }
        groups.splitGroup(groupID, direction: direction)
    }

    func disposeAll() {
        for pane in panes { pane.dispose() }
        groups.reset()
    }

    func syncFocus() {
        guard let registrar else { return }
        registrar.registry.setFocusedSession(active?.id, inWindow: registrar.windowID)
    }

    private func makeTab(id: UUID = UUID(), ordinal: Int? = nil) -> UPaneTab<LocalShellPane> {
        let pane = LocalShellPane(id: id, ordinal: ordinal ?? nextOrdinal())
        if let registrar { pane.attach(registrar) }
        startShell(pane)
        return UPaneTab(id: id, payload: pane)
    }

    /// 最小的没人用的序号。
    private func nextOrdinal() -> Int {
        let used = Set(panes.map(\.ordinal))
        return (1...).first { !used.contains($0) } ?? 1
    }
}

/// 本机终端「开标签」的路由：手机远控新建的 shell 送进最近活跃的本机终端窗口；没有窗口时由调用方开新窗口
///（`LocalShellWindowID` 只能在 Scene 环境里开）。同 `TerminalWindowRouter`。
@MainActor
final class LocalShellWindowRouter {
    static let shared = LocalShellWindowRouter()

    private struct Entry {
        weak var window: NSWindow?
        weak var model: LocalShellWindowModel?
    }

    private var entries: [UUID: Entry] = [:]
    /// 按最近成为 key 的先后排列，最后一个最新。
    private var activationOrder: [UUID] = []

    private init() {}

    func register(windowID: UUID, window: NSWindow?, model: LocalShellWindowModel) {
        let previous = entries[windowID]?.window
        entries[windowID] = Entry(window: window ?? previous, model: model)
        if !activationOrder.contains(windowID) { activationOrder.append(windowID) }
    }

    func unregister(windowID: UUID) {
        entries[windowID] = nil
        activationOrder.removeAll { $0 == windowID }
    }

    func model(forWindow windowID: UUID) -> LocalShellWindowModel? {
        entries[windowID]?.model
    }

    /// 所有本机终端窗口里的会话，退出流程用。
    var allPanes: [LocalShellPane] {
        entries.values.flatMap { $0.model?.panes ?? [] }
    }

    func markActive(windowID: UUID) {
        guard entries[windowID] != nil else { return }
        activationOrder.removeAll { $0 == windowID }
        activationOrder.append(windowID)
    }

    /// 在最近活跃的本机终端窗口里开一个标签（会话 id = `paneID`）并带到前台。
    /// 返回 false = 当前没有本机终端窗口，调用方应开新窗口。
    func openTabInExistingWindow(paneID: UUID) -> Bool {
        for id in activationOrder.reversed() {
            guard let entry = entries[id], let model = entry.model else { continue }
            model.addTab(id: paneID)
            if let window = entry.window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return true
        }
        return false
    }
}

struct LocalShellWindowView: View {
    let windowID: LocalShellWindowID?

    @State private var model = LocalShellWindowModel()
    @Environment(TerminalSessionRegistry.self) private var registry
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            LocalShellTerminalArea(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .udCard()
                .padding(.horizontal, UD.Layout.cardInset)
                .padding(.bottom, UD.Layout.cardInset)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.pageBg)
        .background(WorkspaceWindowChrome(serverName: "本机终端", background: WS.canvasNSColor))
        .background(LocalShellWindowRouterBinding(windowID: windowID?.id, model: model))
        .background(WorkspaceCloseShortcutInstaller { window in
            // 只剩一个标签时 ⌘W 关窗口，否则只关活动标签（同 SSH 终端窗口）。
            if model.panes.count > 1 {
                model.groups.closeActiveTab()
            } else {
                window.performClose(nil)
            }
        })
        .frame(minWidth: 560, minHeight: 360)
        .task {
            // 这是系统恢复的窗口（值要过几十毫秒才到，我们请求打开的窗口第一次就有值）。关掉：会话由
            // `LocalShellRestorer` 接回。要在这里就决定，等值到了再关的话，已经接上的会话会随窗口一起结束。
            guard let windowID else {
                dismiss()
                return
            }
            // 凭条与关闭入口都存进别处（model 自己 / 注册表），只弱引用 model，免得互相持有。
            let windowModel = model
            model.attach(TerminalSessionRegistrar(
                registry: registry, windowID: windowID.id, windowKind: TerminalWindowKind.terminal,
                customTitle: { [weak windowModel] paneID in
                    windowModel?.groups.tab(paneID)?.payload.defaultTitle
                }))
            // 手机远控「同时关闭 Mac 上的终端」走这里。
            registry.setCloser(forWindow: windowID.id) { [weak windowModel] paneID in
                windowModel?.close(paneID) ?? false
            }
            registry.setKeyWindow(windowID: windowID.id, isKey: controlActiveState == .key)
            LocalShellRestorer.shared.adoptPending(windowID: windowID.id, into: model)
            if model.panes.isEmpty { model.addTab(id: windowID.firstPaneID ?? UUID()) }
        }
        .onChange(of: controlActiveState) { _, state in
            guard let windowID else { return }
            registry.setKeyWindow(windowID: windowID.id, isKey: state == .key)
            if state == .key { LocalShellWindowRouter.shared.markActive(windowID: windowID.id) }
        }
        // 最后一个标签关掉（Mac 上点 ×，或手机远控连 Mac 上的一起关）就关窗口。
        .onChange(of: model.groups.isEmpty) { _, empty in
            if empty { dismiss() }
        }
        .onChange(of: model.active?.id) { _, _ in model.syncFocus() }
        // 全局 CommandGroup 的通知广播到所有窗口，只让前台窗口响应。
        .onReceive(NotificationCenter.default.publisher(for: .newTerminalTab)) { _ in
            if controlActiveState == .key { model.addTab() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneHorizontal)) { _ in
            if controlActiveState == .key { model.splitActiveGroup(direction: .horizontal) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneVertical)) { _ in
            if controlActiveState == .key { model.splitActiveGroup(direction: .vertical) }
        }
        .onDisappear {
            model.disposeAll()
            if let windowID { registry.forgetWindow(windowID.id) }
        }
    }

    // MARK: - 标题栏

    private var titleBar: some View {
        Text("本机终端")
            .font(UD.mono(13))
            .foregroundStyle(UD.text3)
            // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动。
            .allowsHitTesting(false)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(WindowDragHandle(fill: WS.canvasNSColor))
    }
}

/// 本机终端窗口的终端区。拖放分屏、分隔条、按下即激活都在组件里，参数与 SSH 终端窗口的 `TerminalArea` 一致。
struct LocalShellTerminalArea: View {
    let model: LocalShellWindowModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let background = SwiftUI.Color(
            nsColor: TerminalColorScheme.resolve(dark: colorScheme == .dark).backgroundColor)
        UPaneGroupArea(
            model: model.groups,
            dragType: .utermTabID,
            stripHeight: WorkspacePaneHeaderLayout.height,
            showsSplitButton: true,
            showsActiveGroupRing: false,
            splitButtonDirection: .automatic,
            splitButtonIcon: .system("rectangle.split.2x1"),
            descriptor: { tab in Self.descriptor(for: tab.payload) },
            content: { tab, _ in
                LocalShellPaneView(pane: tab.payload, background: background) { model.close(tab.id) }
            },
            emptyGroup: { _ in background },
            onRequestClose: { tab in model.close(tab.id) },
            stripAccessory: { groupID in newTabButton(groupID) })
            .uPaneGroupStyle(.card)
            .uPaneGroupWells()
    }

    /// 在每个 chip 自己的 body 里求值：`shellTitle` 可能高频变化，只让这一枚标签跟着重算。
    private static func descriptor(for pane: LocalShellPane) -> UPaneTabDescriptor {
        let session = pane.session
        let controlled = session.remoteController != nil
        let shellTitle = session.shellTitle
        return UPaneTabDescriptor(
            title: shellTitle.map(TerminalArea.clippedTabTitle) ?? pane.defaultTitle,
            icon: .system(controlled ? "iphone" : "terminal"),
            leadingDot: session.connectionState == .connected ? UD.success : UD.text4,
            help: controlled ? "正在被手机接管" : shellTitle ?? pane.defaultTitle)
    }

    private func newTabButton(_ groupID: UUID) -> some View {
        Button {
            model.addTab(in: groupID)
        } label: {
            Image(systemName: "plus")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .iconButtonHover(cornerRadius: 6)
        .help("新开本机终端（⌘T）")
        .accessibilityLabel(Text("新开本机终端"))
    }
}

/// 一个标签的面板内容。单独成视图：连接状态只让它自己重算。
private struct LocalShellPaneView: View {
    let pane: LocalShellPane
    let background: SwiftUI.Color
    let onClose: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
    }

    @ViewBuilder private var content: some View {
        switch pane.session.connectionState {
        case .idle, .connecting:
            VStack(spacing: 10) {
                UDIndeterminateBar().frame(width: 140)
                Text("正在启动本机 shell…").font(UD.caption).foregroundStyle(UD.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected:
            RemoteControlledTerminal(session: pane.session)
        case .failed(let message):
            stateView(systemImage: "exclamationmark.triangle", title: "本机终端没能启动", detail: message)
        case .disconnected:
            stateView(systemImage: "checkmark.circle", title: "shell 已退出", detail: "")
        }
    }

    private func stateView(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(UD.text3)
            Text(title).font(.headline).foregroundStyle(UD.text)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(UD.text3)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 10) {
                UDButton(title: "重新启动") { Task { await pane.start() } }
                UDButton(title: "关闭标签", style: .secondary, action: onClose)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// 把窗口登记进 `LocalShellWindowRouter`（拿到 NSWindow 才能带到前台）。同 `TerminalWindowRouterBinding`。
private struct LocalShellWindowRouterBinding: NSViewRepresentable {
    let windowID: UUID?
    let model: LocalShellWindowModel

    func makeNSView(context: Context) -> ProbeView { ProbeView(windowID: windowID, model: model) }

    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.registerIfNeeded() }

    final class ProbeView: NSView {
        let windowID: UUID?
        let model: LocalShellWindowModel

        init(windowID: UUID?, model: LocalShellWindowModel) {
            self.windowID = windowID
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let windowID else { return }
            if window == nil {
                LocalShellWindowRouter.shared.unregister(windowID: windowID)
            } else {
                registerIfNeeded()
            }
        }

        func registerIfNeeded() {
            guard let windowID, let window else { return }
            LocalShellWindowRouter.shared.register(windowID: windowID, window: window, model: model)
        }
    }
}
