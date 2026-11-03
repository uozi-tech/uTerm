import AppKit
import SwiftTerm
import SwiftUI
import UDesignKit

/// 本机终端窗口的身份：一个窗口一个 shell。手机远控「新建终端」开的就是它，Mac 上也看得到、能接着用。
nonisolated struct LocalShellWindowID: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
}

/// 本机 shell 在会话注册表里的身份。不对应任何 `ServerProfile`：`serverID` 用固定的哨兵值，
/// 手机据此认出「这是 Mac 本机」，不去自己的主机列表里找。
nonisolated enum LocalShellIdentity {
    static var serverID: UUID { RemoteConstants.localShellServerID }
    static let serverName = "本机"
}

/// 一个本机 shell 的会话：起 shell、登记到注册表、结束。
@MainActor
@Observable
final class LocalShellPane {
    let id = UUID()
    let session = TerminalSession()
    /// 登录 shell 的名字（zsh / bash …），标题用。
    let shellName = (LocalShellPane.userShell() as NSString).lastPathComponent
    @ObservationIgnored private var registrar: TerminalSessionRegistrar?

    init() {
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
        if let problem = LocalShellService.shared.readinessProblem() {
            session.markFailed(problem)
            return
        }
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

    /// 主程序在沙盒里读不到目录服务也没关系：只用来起标题，真正起哪个 shell 由辅助进程决定。
    nonisolated static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}

struct LocalShellWindowView: View {
    let windowID: LocalShellWindowID?

    @State private var pane = LocalShellPane()
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
        .background(WorkspaceWindowChrome(serverName: "本机 · \(pane.shellName)", background: WS.canvasNSColor))
        .frame(minWidth: 560, minHeight: 360)
        .task {
            guard let windowID else { return }
            let shell = pane.shellName
            pane.attach(TerminalSessionRegistrar(registry: registry, windowID: windowID.id,
                                                 windowKind: TerminalWindowKind.terminal,
                                                 customTitle: { _ in shell }))
            registry.setKeyWindow(windowID: windowID.id, isKey: controlActiveState == .key)
            registry.setFocusedSession(pane.id, inWindow: windowID.id)
            await pane.start()
        }
        .onChange(of: controlActiveState) { _, state in
            guard let windowID else { return }
            registry.setKeyWindow(windowID: windowID.id, isKey: state == .key)
        }
        .onDisappear { pane.dispose() }
    }

    private var titleBar: some View {
        ZStack {
            HStack(spacing: 9) {
                Text("本机 · \(pane.shellName)")
                    .font(UD.mono(13))
                    .foregroundStyle(UD.text3)
                WSStatusPill(state: pane.session.connectionState)
            }
            .allowsHitTesting(false)
            HStack(spacing: 8) {
                SwiftUI.Color.clear.frame(width: 68)   // 让位窗口红绿灯
                Spacer()
                WSIconButton(systemName: "power", help: "结束 shell 并关闭窗口") { dismiss() }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle(fill: WS.canvasNSColor))
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
            TerminalHostView(terminalView: pane.session.terminalView)
                .overlay(alignment: .topTrailing) {
                    if let controller = pane.session.remoteController {
                        RemoteControlBadge(deviceName: controller) { pane.session.remoteDisconnect?() }
                            .padding(8)
                    }
                }
        case .failed(let message):
            stateView(systemImage: "exclamationmark.triangle", title: "本机终端没能启动", detail: message,
                      showsLoginItems: LocalShellService.shared.status == .requiresApproval)
        case .disconnected:
            stateView(systemImage: "checkmark.circle", title: "shell 已退出", detail: "", showsLoginItems: false)
        }
    }

    private func stateView(systemImage: String, title: String, detail: String, showsLoginItems: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(UD.text3)
            Text(title).font(.headline).foregroundStyle(UD.text)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(UD.text3)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 10) {
                if showsLoginItems {
                    UDButton(title: "打开登录项设置") { LocalShellService.shared.openLoginItemsSettings() }
                }
                UDButton(title: "重新启动") { Task { await pane.start() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
