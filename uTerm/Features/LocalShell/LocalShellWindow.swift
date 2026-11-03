import AppKit
import SwiftTerm
import SwiftUI
import UDesignKit

/// 本机终端窗口的身份。一个窗口多个标签，每个标签一个 shell；手机远控「新建终端」优先把标签加进
/// 最近活跃的本机终端窗口（见 `LocalShellWindowRouter`），没有才开新窗口。
nonisolated struct LocalShellWindowID: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    /// 第一个标签的会话 id。手机远控开窗口时预先定好，好按它等会话登记；为 nil 时窗口自己开一个。
    var firstPaneID: UUID?
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
    @ObservationIgnored private var registrar: TerminalSessionRegistrar?

    init(id: UUID = UUID()) {
        self.id = id
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
        let backend = LocalShellBackend(client: LocalShellService.shared.client,
                                        columns: terminal.cols, rows: terminal.rows)
        await session.connect(using: backend)
    }

    func dispose() {
        registrar?.unregister(paneID: id)
        session.dispose()
        Task { await session.close() }
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

/// 一个本机终端窗口的标签：每个标签一个 `LocalShellPane`。
@MainActor
@Observable
final class LocalShellWindowModel {
    private(set) var panes: [LocalShellPane] = []
    private(set) var activeID: UUID?
    @ObservationIgnored private var registrar: TerminalSessionRegistrar?

    var active: LocalShellPane? { panes.first { $0.id == activeID } ?? panes.last }

    func attach(_ registrar: TerminalSessionRegistrar) {
        self.registrar = registrar
        for pane in panes { pane.attach(registrar) }
        syncFocus()
    }

    /// 新开一个标签并切过去，返回它的会话 id（可以预先指定）。
    @discardableResult
    func addTab(id: UUID = UUID()) -> UUID {
        let pane = LocalShellPane(id: id)
        if let registrar { pane.attach(registrar) }
        panes.append(pane)
        activeID = id
        syncFocus()
        Task { await pane.start() }
        return id
    }

    func activate(_ id: UUID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        activeID = id
        syncFocus()
    }

    /// 关掉一个标签（连同它的 shell）。返回 false = 没有这个标签。
    @discardableResult
    func close(_ id: UUID) -> Bool {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return false }
        let pane = panes.remove(at: index)
        pane.dispose()
        if activeID == id {
            activeID = panes.isEmpty ? nil : panes[min(index, panes.count - 1)].id
        }
        syncFocus()
        return true
    }

    func disposeAll() {
        for pane in panes { pane.dispose() }
        panes.removeAll()
        activeID = nil
    }

    /// 同名 shell 多开时标题带序号（zsh、zsh 2……），手机列表里分得清。
    func title(for pane: LocalShellPane) -> String {
        let same = panes.filter { $0.shellName == pane.shellName }
        guard same.count > 1, let index = same.firstIndex(where: { $0.id == pane.id }), index > 0 else {
            return pane.shellName
        }
        return "\(pane.shellName) \(index + 1)"
    }

    private func syncFocus() {
        guard let registrar else { return }
        registrar.registry.setFocusedSession(active?.id, inWindow: registrar.windowID)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var terminalBackground: SwiftUI.Color {
        SwiftUI.Color(nsColor: TerminalColorScheme.resolve(dark: colorScheme == .dark).backgroundColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(terminalBackground)
                .udCard()
                .padding(.horizontal, UD.Layout.cardInset)
                .padding(.bottom, UD.Layout.cardInset)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.pageBg)
        .background(WorkspaceWindowChrome(serverName: "本机终端", background: WS.canvasNSColor))
        .background(LocalShellWindowRouterBinding(windowID: windowID?.id, model: model))
        .frame(minWidth: 560, minHeight: 360)
        .task {
            guard let windowID else { return }
            // 凭条与关闭入口都存进别处（model 自己 / 注册表），只弱引用 model，免得互相持有。
            let windowModel = model
            model.attach(TerminalSessionRegistrar(
                registry: registry, windowID: windowID.id, windowKind: TerminalWindowKind.terminal,
                customTitle: { [weak windowModel] paneID in
                    windowModel?.panes.first { $0.id == paneID }.map { windowModel?.title(for: $0) ?? $0.shellName }
                }))
            // 手机远控「同时关闭 Mac 上的终端」走这里。
            registry.setCloser(forWindow: windowID.id) { [weak windowModel] paneID in
                windowModel?.close(paneID) ?? false
            }
            registry.setKeyWindow(windowID: windowID.id, isKey: controlActiveState == .key)
            if model.panes.isEmpty { model.addTab(id: windowID.firstPaneID ?? UUID()) }
        }
        .onChange(of: controlActiveState) { _, state in
            guard let windowID else { return }
            registry.setKeyWindow(windowID: windowID.id, isKey: state == .key)
            if state == .key { LocalShellWindowRouter.shared.markActive(windowID: windowID.id) }
        }
        // 最后一个标签关掉（Mac 上点 ×，或手机远控连 Mac 上的一起关）就关窗口。
        .onChange(of: model.panes.isEmpty) { _, empty in
            if empty { dismiss() }
        }
        .onDisappear {
            model.disposeAll()
            if let windowID { registry.forgetWindow(windowID.id) }
        }
    }

    // MARK: - 标题栏（标签条）

    private var titleBar: some View {
        HStack(spacing: 6) {
            SwiftUI.Color.clear.frame(width: 68)   // 让位窗口红绿灯
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.panes) { pane in
                        tab(pane)
                    }
                    WSIconButton(systemName: "plus", help: "新开本机终端") { model.addTab() }
                        .padding(.leading, 4)
                }
                // 胶囊比卡片轮廓 / 投影多出 1–2pt，留出来别被 ScrollView 裁掉。
                .padding(.vertical, 2)
            }
            Spacer(minLength: 8)
            WSIconButton(systemName: "power", help: "结束全部 shell 并关闭窗口") { dismiss() }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle(fill: WS.canvasNSColor))
    }

    /// 标签样式与 SFTP 标签条同一套（`WSCanvasTab`）：激活胶囊用终端底色，就是下面那张终端卡。
    private func tab(_ pane: LocalShellPane) -> some View {
        WSCanvasTab(name: model.title(for: pane), active: pane.id == model.active?.id,
                    activeFill: terminalBackground, closeHelp: "关闭这个 shell",
                    onSelect: { model.activate(pane.id) }, onClose: { model.close(pane.id) }) { _ in
            Circle()
                .fill(pane.session.connectionState == .connected ? UD.success : UD.text4)
                .frame(width: 6, height: 6)
            if pane.session.remoteController != nil {
                Image(systemName: "iphone").font(.system(size: 10)).foregroundStyle(UD.accent)
                    .help("正在被手机接管")
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder private var content: some View {
        if let pane = model.active {
            paneContent(pane).id(pane.id)
        } else {
            SwiftUI.Color.clear
        }
    }

    @ViewBuilder private func paneContent(_ pane: LocalShellPane) -> some View {
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
            stateView(pane, systemImage: "exclamationmark.triangle", title: "本机终端没能启动", detail: message)
        case .disconnected:
            stateView(pane, systemImage: "checkmark.circle", title: "shell 已退出", detail: "")
        }
    }

    private func stateView(_ pane: LocalShellPane, systemImage: String, title: String, detail: String) -> some View {
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
                UDButton(title: "关闭标签", style: .secondary) { model.close(pane.id) }
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
