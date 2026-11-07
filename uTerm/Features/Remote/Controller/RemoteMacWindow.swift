import AppKit
import SwiftUI
import UDesignKit
import UPaneGroups

/// 一台远程 Mac 的窗口：连上（第一次时在那台 Mac 上核对数字配对），整台接管它的终端，每个一个标签；
/// 标签条上的「屏幕」按钮再开一个看 / 控它桌面的标签。关标签、关窗口只断开接入，那台 Mac 上的终端照常运行。
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
            guard let model, model.tabCount > 1, let active = model.active else {
                window.performClose(nil)
                return
            }
            model.close(active.id)
        })
        .frame(minWidth: 560, minHeight: 360)
        .task { await start() }
        .onDisappear {
            model?.disposeAll()
            model?.client.disconnect()
        }
    }

    private var title: String { model?.client.macName ?? String(localized: "远程 Mac") }

    private var titleBar: some View {
        Text(title)
            .font(UD.mono(13))
            .foregroundStyle(UD.text3)
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
            RemoteMacSessionView(model: model)
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
        let model = RemoteMacWindowModel(client: directory.client(for: mac))
        self.model = model
        await model.client.connect()
    }
}

/// 窗口内容：按连接状态显示连接中 / 核对配对数字 / 失败，连上后是终端标签区。
private struct RemoteMacSessionView: View {
    let model: RemoteMacWindowModel

    var body: some View {
        let client = model.client
        Group {
            switch client.state {
            case .idle where model.isEmpty, .connecting where model.isEmpty:
                RemoteMacProgressView(text: String(localized: "正在连接 \(client.macName)…"))
            case .awaitingApproval(let code):
                RemoteMacPairingCodeView(macName: client.macName, code: code)
            case .failed(let message) where model.isEmpty:
                RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法连接"),
                                   detail: message) {
                    UDButton(title: "重试") { Task { await client.connect() } }
                }
            default:
                RemoteMacTerminalArea(model: model)
                    .overlay(alignment: .top) { connectionNotice }
            }
        }
        .onChange(of: client.state, initial: true) { _, state in
            if state == .connected { model.takeOver() }
        }
        .onChange(of: client.listedSessionIDs) { _, ids in model.follow(ids) }
    }

    /// 连着的过程中断了：标签留着（各自在后台重连），顶上说一声。
    @ViewBuilder private var connectionNotice: some View {
        switch model.client.state {
        case .connecting:
            SettingsInlineNote(tone: .neutral, text: String(localized: "连接断开，正在重新连接…"))
                .padding(8)
        case .failed(let message):
            HStack(spacing: 8) {
                SettingsInlineNote(tone: .warning, text: message)
                UDButton(title: "重试", style: .secondary) { Task { await model.client.connect() } }
            }
            .padding(8)
        default:
            EmptyView()
        }
    }
}

/// 标签区（终端 + 屏幕）：拖放分屏、按下即激活都在组件里，与本机终端窗口一致。不显示分屏按钮：远程终端没法「复制」一个。
private struct RemoteMacTerminalArea: View {
    let model: RemoteMacWindowModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var openError: String?

    var body: some View {
        let background = SwiftUI.Color(
            nsColor: TerminalColorScheme.resolve(dark: colorScheme == .dark).backgroundColor)
        Group {
            if model.isEmpty {
                RemoteMacStateView(systemImage: "terminal", title: String(localized: "这台 Mac 上没有打开的终端"),
                                   detail: String(localized: "新建一个，那台 Mac 上也会弹出对应的终端窗口。")) {
                    HStack(spacing: 8) {
                        UDButton(title: "新建终端") { openNewShell() }
                            .disabled(!canOpenShell)
                        if model.client.supportsDesktop {
                            UDButton(title: "查看屏幕", style: .secondary) { model.openDesktop() }
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
                        switch tab.payload {
                        case .terminal(let pane): RemoteTerminalPaneView(pane: pane, background: background)
                        case .desktop(let pane): RemoteDesktopMacView(pane: pane, macName: model.client.macName)
                        }
                    },
                    emptyGroup: { _ in background },
                    onRequestClose: { tab in model.close(tab.id) },
                    stripAccessory: { _ in
                        HStack(spacing: 2) {
                            if model.client.supportsDesktop { desktopButton }
                            newShellButton
                        }
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

    private func descriptor(for tab: RemoteMacPane) -> UPaneTabDescriptor {
        switch tab {
        case .terminal(let pane): return descriptor(for: pane)
        case .desktop(let pane):
            let streaming = pane.session.state == .streaming
            return UPaneTabDescriptor(title: String(localized: "屏幕"), icon: .system("display"),
                                      leadingDot: streaming ? UD.success : UD.text4,
                                      help: String(localized: "\(model.client.macName) 的屏幕"))
        }
    }

    private func descriptor(for pane: RemoteTerminalPane) -> UPaneTabDescriptor {
        let session = pane.session
        let status = session.programStatus
        return UPaneTabDescriptor(
            title: pane.title(in: model.client.sessions),
            icon: .none,
            leadingDot: status?.tabDot ?? (session.connectionState == .connected ? UD.success : UD.text4),
            help: status?.tabHelp ?? pane.title(in: model.client.sessions))
    }

    private var canOpenShell: Bool { model.client.supportsLocalShell && model.client.state == .connected }

    private func openNewShell() {
        Task {
            do { try await model.openNewShell() } catch { openError = error.localizedDescription }
        }
    }

    private var desktopButton: some View {
        Button { model.openDesktop() } label: {
            Image(systemName: "display")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .iconButtonHover(cornerRadius: 6)
        .disabled(model.client.state != .connected)
        .help(String(localized: "查看这台 Mac 的屏幕"))
        .accessibilityLabel(Text("查看屏幕"))
    }

    private var newShellButton: some View {
        Button { openNewShell() } label: {
            Image(systemName: "plus")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .iconButtonHover(cornerRadius: 6)
        .disabled(!canOpenShell)
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
                TerminalHostView(terminalView: pane.session.terminalView, isActive: activePaneGate?.isActive ?? true)
            case .failed(let message):
                RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法接入这个终端"),
                                   detail: message) {
                    UDButton(title: "重试") { Task { await pane.start() } }
                }
            case .disconnected:
                RemoteMacStateView(systemImage: "checkmark.circle", title: String(localized: "终端已结束"), detail: "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }
}

/// 第一次连：两边显示同一组数字，在那台 Mac 上点「允许」。
struct RemoteMacPairingCodeView: View {
    let macName: String
    let code: String

    var body: some View {
        VStack(spacing: 14) {
            Text("在「\(macName)」上确认配对").font(.system(size: 17, weight: .semibold)).foregroundStyle(UD.text)
            Text("\(code.prefix(3)) \(code.suffix(3))")
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .foregroundStyle(UD.text)
            Text("那台 Mac 上会弹出同样的 6 位数字。一致再点「允许」；不一致说明连接可能被截获，点「拒绝」。")
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

    var body: some View {
        VStack(spacing: 10) {
            UDIndeterminateBar().frame(width: 140)
            Text(text).font(UD.caption).foregroundStyle(UD.text3)
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
