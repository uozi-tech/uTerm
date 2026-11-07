import AppKit
import Observation
import SwiftUI
import UDesignKit

/// 远程 Mac 屏幕窗口的身份：一台 Mac 最多一个（同一个值再开会带出已有的那个）。
nonisolated struct RemoteDesktopWindowID: Codable, Hashable, Sendable {
    /// `RemoteMacDirectory.Mac.id`。
    let macID: String
}

/// 屏幕窗口的状态：连那台 Mac（与它的终端窗口共用一条连接），连上后开一路画面。
@MainActor
@Observable
final class RemoteDesktopWindowModel {
    let client: RemoteMacClient
    let session: RemoteDesktopSession
    var scaleMode: RemoteDesktopScaleMode = .fit
    @ObservationIgnored private var closed = false

    init(client: RemoteMacClient, session: RemoteDesktopSession? = nil) {
        self.client = client
        let size = Self.requestedPixels()
        self.session = session ?? RemoteDesktopSession(client: client, maxWidth: size.width, maxHeight: size.height)
    }

    /// 连上（第一次时在那台 Mac 上核对配对数字），再开流。已经在放就什么也不做。
    func start() async {
        closed = false
        await client.connect()
        await startStreamIfConnected()
    }

    /// 连接状态变了（核对完配对、断线重连上）：还没在放就开流。
    func startStreamIfConnected() async {
        guard !closed, client.state == .connected else { return }
        switch session.state {
        case .idle, .failed, .ended: await session.start()
        case .connecting, .streaming, .reconnecting, .unsupported: break
        }
    }

    /// 关窗口：停掉这一路画面（那台 Mac 停止采集，帘幕随之撤掉）。连接由目录按窗口计数决定断不断。
    func close() {
        closed = true
        session.stop()
    }

    /// 要多大的画面：按本机最大那块屏幕的像素，至少 1080p。那台 Mac 会按自己显示器的比例套进这个框里。
    static func requestedPixels(screens: [NSScreen] = NSScreen.screens) -> (width: Int, height: Int) {
        var width = 1920, height = 1080
        for screen in screens {
            let scale = screen.backingScaleFactor
            let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
            width = max(width, max(w, h))
            height = max(height, min(w, h))
        }
        return (width, height)
    }
}

/// 一台远程 Mac 的屏幕窗口：整窗黑底，顶上一条细工具栏（名字与状态、适配 / 原始大小、帘幕、全屏），
/// 下面全是画面，和手机上的远程桌面一样。画面上按状态盖遮罩（连接中 / 核对配对 / 失败 / 锁屏…）。
struct RemoteDesktopWindowView: View {
    let windowID: RemoteDesktopWindowID?

    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(\.dismiss) private var dismiss
    @State private var model: RemoteDesktopWindowModel?
    @State private var missing = false

    var body: some View {
        Group {
            if let model {
                RemoteDesktopContent(model: model)
            } else {
                VStack(spacing: 0) {
                    RemoteDesktopTitleBar { Text(missing ? "找不到这台 Mac" : "").foregroundStyle(.white) }
                    Color.black.overlay {
                        if missing {
                            Text("它可能已被忘记。在「我的 Mac」里重新配对。")
                                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .background(WorkspaceWindowChrome(serverName: "", background: .black))
        .background(WindowTitleBinding(title: model.map { String(localized: "\($0.client.macName) 的屏幕") }
            ?? String(localized: "屏幕")))
        // ⌘W 关这扇窗口，不发给那台 Mac（本机窗口的监听比画布先拿到按键）。
        .background(WorkspaceCloseShortcutInstaller { window in window.performClose(nil) })
        .frame(minWidth: 640, minHeight: 420)
        .task { await start() }
        .onDisappear {
            guard let model else { return }
            model.close()
            if let windowID { directory.releaseClient(macID: windowID.macID) }
        }
    }

    private func start() async {
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
        let model = RemoteDesktopWindowModel(client: directory.acquireClient(for: mac))
        self.model = model
        await model.start()
    }
}

/// 窗口顶上那条栏：黑底、可拖动窗口，左边让出红绿灯。
private struct RemoteDesktopTitleBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.leading, 80)
        .padding(.trailing, 10)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowDragHandle(fill: .black))
    }
}

struct RemoteDesktopContent: View {
    @Bindable var model: RemoteDesktopWindowModel

    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    @State private var showStats = false
    @State private var password = ""
    @State private var unlocking = false
    @State private var unlockError: String?

    private var session: RemoteDesktopSession { model.session }
    private var client: RemoteMacClient { model.client }

    var body: some View {
        VStack(spacing: 0) {
            RemoteDesktopTitleBar { toolbar }
            ZStack {
                RemoteDesktopMacCanvas(
                    session: session, scaleMode: model.scaleMode,
                    displaySize: session.info.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) },
                    onPasteNote: { show($0) })
                stateOverlay
                lockOverlay
            }
            .overlay(alignment: .top) { toast }
        }
        .onAppear {
            session.onClipboard = { content in show(RemoteDesktopMacPasteSource.receive(content)) }
        }
        .onChange(of: client.state) { _, _ in Task { await model.startStreamIfConnected() } }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(client.macName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(statusLine)
                    .font(UD.mono(10.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { showStats.toggle() }
            .help(String(localized: "点按显示 / 隐藏帧率与延迟"))
            Spacer(minLength: 8)
            if session.state == .streaming {
                UDSegmented(selection: $model.scaleMode, options: [
                    (RemoteDesktopScaleMode.fit, String(localized: "适配窗口")),
                    (RemoteDesktopScaleMode.actual, String(localized: "原始大小")),
                ])
                .fixedSize()
                if session.supportsUnlock, session.canControl, !session.screen.locked {
                    barButton(session.screen.curtained ? "eye.slash.fill" : "eye.slash",
                              active: session.screen.curtained,
                              help: session.screen.curtained ? String(localized: "关闭帘幕：那台 Mac 的屏幕恢复显示")
                                                             : String(localized: "帘幕：那台 Mac 的屏幕变黑，本机键鼠暂停")) {
                        session.setCurtain(!session.screen.curtained)
                    }
                }
            }
            barButton("arrow.up.left.and.arrow.down.right", active: false, help: String(localized: "全屏")) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
    }

    private func barButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? UD.accent : .white.opacity(0.85))
                .frame(width: 28, height: 24)
                .background(Color.white.opacity(active ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private var statusLine: String {
        switch client.state {
        case .connecting where session.state != .streaming: return String(localized: "正在连接…")
        case .awaitingApproval: return String(localized: "等待那台 Mac 确认配对")
        default: break
        }
        switch session.state {
        case .streaming:
            let base = session.canControl ? String(localized: "可以控制") : String(localized: "只能查看")
            guard showStats else { return base }
            let stats = session.stats
            let latency = session.latency.map { "延迟 \($0.p50Millis) ms（p95 \($0.p95Millis)）· " } ?? ""
            return base + " · " + latency + String(format: "%.0f fps · %.1f Mbps · 解码 %.1f ms", stats.framesPerSecond,
                                                   stats.megabitsPerSecond, stats.decodeMillis)
        case .idle, .connecting: return String(localized: "正在连接…")
        case .reconnecting: return String(localized: "连接中断，正在重连…")
        case .failed: return String(localized: "连接失败")
        case .ended: return String(localized: "已结束")
        case .unsupported: return String(localized: "那台 Mac 上的 uTerm 版本太旧")
        }
    }

    // MARK: - 遮罩

    @ViewBuilder private var stateOverlay: some View {
        if case .awaitingApproval(let code) = client.state {
            RemoteMacPairingCodeView(macName: client.macName, code: code).background(Color.black)
        } else if case .failed(let message) = client.state, session.state != .streaming {
            notice(spinner: false, title: String(localized: "无法连接 \(client.macName)"), message: message) {
                UDButton(title: "重试") { Task { await model.start() } }
            }
        } else {
            sessionOverlay
        }
    }

    @ViewBuilder private var sessionOverlay: some View {
        switch session.state {
        case .idle, .connecting:
            notice(spinner: true, title: String(localized: "正在连接 \(client.macName) 的屏幕…"), message: nil)
        case .reconnecting:
            notice(spinner: true, title: String(localized: "连接中断，正在重连…"),
                   message: String(localized: "接上后画面会自动恢复"), dim: true)
        case .streaming:
            if !session.canControl, let controlNote = session.info?.controlNote {
                VStack {
                    Spacer()
                    Text(controlNote)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.bottom, 20).padding(.horizontal, 20)
                }
                .allowsHitTesting(false)
            }
        case .failed(let message):
            notice(spinner: false, title: String(localized: "没能打开屏幕"), message: message) {
                UDButton(title: "重试") { Task { await session.start() } }
            }
        case .ended(let reason):
            notice(spinner: false, title: String(localized: "远程桌面已结束"), message: reason) {
                UDButton(title: "重新连接") { Task { await model.start() } }
            }
        case .unsupported:
            notice(spinner: false, title: String(localized: "请更新那台 Mac 上的 uTerm"),
                   message: RemoteDesktopError.macTooOld.localizedDescription)
        }
    }

    /// 那台 Mac 停在锁屏：在这里输登录密码解锁（不保存）。解锁后那台 Mac 进入帘幕，锁屏状态由它推来，这层自然消失。
    @ViewBuilder private var lockOverlay: some View {
        if session.supportsUnlock, session.screen.locked {
            notice(spinner: unlocking, title: String(localized: "\(client.macName) 已锁定"), message: lockMessage) {
                if session.screen.unlockAvailable, !unlocking {
                    HStack(spacing: 8) {
                        UDTextField(placeholder: String(localized: "登录密码"), text: $password, autoFocus: true,
                                    isSecure: true)
                            .frame(width: 220)
                            .onSubmit { submitUnlock() }
                        UDButton(title: "解锁") { submitUnlock() }
                            .disabled(password.isEmpty)
                    }
                }
            }
        }
    }

    private var lockMessage: String {
        if let unlockError { return unlockError }
        if !session.screen.unlockAvailable {
            return String(localized: "那台 Mac 没有开启远程解锁（设置 › 远程控制 › 允许远程解锁），或没有「辅助功能」授权。")
        }
        return String(localized: "输入那台 Mac 的登录密码。解锁后它的屏幕会变黑并暂停本机键鼠，密码不会保存。")
    }

    private func submitUnlock() {
        guard !password.isEmpty, !unlocking else { return }
        let secret = password
        password = ""
        unlocking = true
        unlockError = nil
        Task {
            let outcome = await session.unlock(password: secret)
            unlocking = false
            switch outcome {
            case .unlocked, .notLocked: unlockError = nil
            case .rejected: unlockError = String(localized: "密码不对，请重试。")
            case .timedOut: unlockError = String(localized: "解锁超时，请重试。")
            case .notAllowed: unlockError = String(localized: "那台 Mac 当前不允许远程解锁。")
            }
        }
    }

    private func notice(spinner: Bool, title: String, message: String?, dim: Bool = false) -> some View {
        notice(spinner: spinner, title: title, message: message, dim: dim) { EmptyView() }
    }

    private func notice<Buttons: View>(spinner: Bool, title: String, message: String?, dim: Bool = false,
                                       @ViewBuilder buttons: () -> Buttons) -> some View {
        ZStack {
            Color.black.opacity(dim ? 0.45 : 0.75)
            VStack(spacing: 12) {
                if spinner { UDIndeterminateBar().frame(width: 140) }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                HStack(spacing: 10) { buttons() }
                    .padding(.top, 4)
            }
            .padding(24)
        }
    }

    // MARK: - 提示

    @ViewBuilder private var toast: some View {
        if let note {
            Text(note)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(.black.opacity(0.75)))
                .padding(.top, 10)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func show(_ text: String) {
        noteTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { note = text }
        noteTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { note = nil }
        }
    }
}
