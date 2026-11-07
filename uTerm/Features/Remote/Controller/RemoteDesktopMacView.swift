import AppKit
import SwiftUI
import UDesignKit

/// 远程 Mac 窗口里的「屏幕」标签：顶上一条工具栏（状态、适配 / 原始大小、帘幕、全屏），下面是画面。
/// 画面上按连接状态盖遮罩（连接中 / 重连中 / 失败 / 已结束 / 版本太旧 / 锁屏）。
struct RemoteDesktopMacView: View {
    @Bindable var pane: RemoteDesktopPane
    let macName: String

    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    @State private var showStats = false
    @State private var password = ""
    @State private var unlocking = false
    @State private var unlockError: String?

    private var session: RemoteDesktopSession { pane.session }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(UD.border).frame(height: 1)
            ZStack {
                RemoteDesktopMacCanvas(
                    session: session, scaleMode: pane.scaleMode,
                    displaySize: session.info.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) },
                    onPasteNote: { show($0) })
                stateOverlay
                lockOverlay
            }
            .overlay(alignment: .top) { toast }
            .environment(\.colorScheme, .dark)
        }
        .onAppear {
            session.onClipboard = { content in show(RemoteDesktopMacPasteSource.receive(content)) }
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Circle().fill(statusDot).frame(width: 7, height: 7)
            Text(statusLine)
                .font(UD.mono(11.5))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
                .onTapGesture { showStats.toggle() }
                .help(String(localized: "点按显示 / 隐藏帧率与延迟"))
            Spacer(minLength: 8)
            UDSegmented(selection: $pane.scaleMode, options: [
                (RemoteDesktopScaleMode.fit, String(localized: "适配窗口")),
                (RemoteDesktopScaleMode.actual, String(localized: "原始大小")),
            ])
            .fixedSize()
            if session.supportsUnlock, session.canControl, !session.screen.locked {
                toolButton(session.screen.curtained ? "eye.slash.fill" : "eye.slash",
                           active: session.screen.curtained,
                           help: session.screen.curtained ? String(localized: "关闭帘幕：那台 Mac 的屏幕恢复显示")
                                                          : String(localized: "帘幕：那台 Mac 的屏幕变黑，本机键鼠暂停")) {
                    session.setCurtain(!session.screen.curtained)
                }
            }
            toolButton("arrow.up.left.and.arrow.down.right", active: false, help: String(localized: "全屏")) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func toolButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? UD.accent : UD.text2)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .iconButtonHover(cornerRadius: 6)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private var statusDot: Color {
        switch session.state {
        case .streaming: return session.canControl ? UD.success : UD.warning
        case .idle, .connecting, .reconnecting: return UD.text4
        case .failed, .ended, .unsupported: return UD.danger
        }
    }

    private var statusLine: String {
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
        switch session.state {
        case .idle, .connecting:
            notice(spinner: true, title: String(localized: "正在连接 \(macName) 的屏幕…"), message: nil)
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
                UDButton(title: "重新连接") { Task { await session.start() } }
            }
        case .unsupported:
            notice(spinner: false, title: String(localized: "请更新那台 Mac 上的 uTerm"),
                   message: RemoteDesktopError.macTooOld.localizedDescription)
        }
    }

    /// 那台 Mac 停在锁屏：在这里输登录密码解锁（不保存）。解锁后那台 Mac 进入帘幕，锁屏状态由它推来，这层自然消失。
    @ViewBuilder private var lockOverlay: some View {
        if session.supportsUnlock, session.screen.locked {
            notice(spinner: unlocking, title: String(localized: "\(macName) 已锁定"), message: lockMessage) {
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
