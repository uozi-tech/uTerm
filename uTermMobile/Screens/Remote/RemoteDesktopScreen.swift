import SwiftUI
import UIKit

/// 远程桌面：全屏看 / 控制一台 Mac 的屏幕。从 Mac 面板的「屏幕」进入。
///
/// 画面与手势在 `RemoteDesktopCanvas`（UIKit）里；这里只管外壳：顶栏（关闭、状态、键盘、适配屏幕）、
/// 连接状态的遮罩（连接中 / 重连中 / 失败 / 已结束 / Mac 版本太旧）、键盘条、前后台切换。
struct RemoteDesktopScreen: View {
    let client: RemoteMacClient
    let onClose: () -> Void

    @State private var session: RemoteDesktopSession?
    @State private var keys = RemoteDesktopKeyState()
    @State private var keyboardVisible = false
    @State private var fitToken = 0
    @State private var showStats = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.mAccent) private var accent

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if let session {
                    RemoteDesktopCanvas(session: session, keys: keys, keyboardVisible: $keyboardVisible, fitToken: fitToken,
                                        displaySize: session.info.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) })
                        .ignoresSafeArea()
                    overlay(session)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboardVisible, let session, session.canControl {
                    RemoteDesktopKeyBar(keys: keys) { session.send($0) }
                }
            }
            .task {
                guard session == nil else { return }
                let created = makeSession(size: geometry.size)
                session = created
                await created.start()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session?.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台：连接还在就要一个关键帧（后台期间可能丢了解码状态）；断了的由会话自己重连。
            if phase == .active { session?.requestKeyframe() }
        }
    }

    /// 视频尺寸按这台设备的屏幕像素要（与方向无关），至少 1080p：放大看细节时还有余量。
    private func makeSession(size: CGSize) -> RemoteDesktopSession {
        let long = Int(max(size.width, size.height) * displayScale)
        let short = Int(min(size.width, size.height) * displayScale)
        return RemoteDesktopSession(client: client, maxWidth: max(long, 1920), maxHeight: max(short, 1080))
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 8) {
            barButton("xmark") {
                session?.stop()
                onClose()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(client.macName)
                    .font(M.sans(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(statusLine)
                    .font(M.mono(10.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .onTapGesture { showStats.toggle() }
            Spacer(minLength: 8)
            barButton("arrow.down.right.and.arrow.up.left") { fitToken += 1 }
                .accessibilityLabel("适配屏幕")
            if session?.canControl == true {
                barButton(keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard", active: keyboardVisible) {
                    keyboardVisible.toggle()
                }
                .accessibilityLabel(keyboardVisible ? "收起键盘" : "键盘")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55))
    }

    private var statusLine: String {
        guard let session else { return "正在连接…" }
        switch session.state {
        case .streaming:
            let base = session.canControl ? "触控板模式" : "只能查看"
            guard showStats else { return base }
            let stats = session.stats
            return String(format: "%@ · %.0f fps · %.1f Mbps · 解码 %.1f ms", base, stats.framesPerSecond,
                          stats.megabitsPerSecond, stats.decodeMillis)
        case .idle, .connecting: return "正在连接…"
        case .reconnecting: return "连接中断，正在重连…"
        case .failed: return "连接失败"
        case .ended: return "已结束"
        case .unsupported: return "Mac 版本太旧"
        }
    }

    private func barButton(_ symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? accent : .white)
                .frame(width: 36, height: 32)
                .background(Color.white.opacity(active ? 0.18 : 0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(MPressStyle())
    }

    // MARK: - 状态遮罩

    @ViewBuilder private func overlay(_ session: RemoteDesktopSession) -> some View {
        switch session.state {
        case .idle, .connecting:
            notice(spinner: true, title: "正在连接 \(client.macName) 的屏幕…", message: nil)
        case .reconnecting:
            notice(spinner: true, title: "连接中断，正在重连…", message: "接上后画面会自动恢复", dim: true)
        case .streaming:
            if !session.canControl, let note = session.info?.controlNote {
                VStack {
                    Spacer()
                    Text(note)
                        .font(M.sans(12))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.bottom, 24).padding(.horizontal, 20)
                }
                .allowsHitTesting(false)
            }
        case .failed(let message):
            notice(spinner: false, title: "没能打开屏幕", message: message) {
                MBtn(title: "重试", kind: .primary, height: 42) { Task { await session.start() } }.fixedSize()
                MBtn(title: "关闭", kind: .secondary, height: 42, action: onClose).fixedSize()
            }
        case .ended(let reason):
            notice(spinner: false, title: "远程桌面已结束", message: reason) {
                MBtn(title: "重新连接", kind: .primary, height: 42) { Task { await session.start() } }.fixedSize()
                MBtn(title: "关闭", kind: .secondary, height: 42, action: onClose).fixedSize()
            }
        case .unsupported:
            notice(spinner: false, title: "请更新 Mac 上的 uTerm",
                   message: RemoteDesktopError.macTooOld.localizedDescription) {
                MBtn(title: "关闭", kind: .primary, height: 42, action: onClose).fixedSize()
            }
        }
    }

    private func notice(spinner: Bool, title: String, message: String?, dim: Bool = false) -> some View {
        notice(spinner: spinner, title: title, message: message, dim: dim) { EmptyView() }
    }

    private func notice<Buttons: View>(spinner: Bool, title: String, message: String?, dim: Bool = false,
                                       @ViewBuilder buttons: () -> Buttons) -> some View {
        ZStack {
            Color.black.opacity(dim ? 0.45 : 0.75).ignoresSafeArea()
            VStack(spacing: 12) {
                if spinner { ProgressView().tint(.white) }
                Text(title)
                    .font(M.sans(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(M.sans(13))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                HStack(spacing: 10) { buttons() }
                    .padding(.top, 4)
            }
            .padding(24)
        }
    }
}

/// 远程桌面的键盘条：粘滞修饰（⌃⌥⇧⌘）+ 常用特殊键，展开后有导航键与 F1–F12。
/// 与终端的增强键盘条同一套外观；区别是这里发的是 Mac 键码，不是终端转义序列。
struct RemoteDesktopKeyBar: View {
    let keys: RemoteDesktopKeyState
    let send: (RemoteDesktopInput) -> Void
    @Environment(\.mAccent) private var accent
    @State private var expanded = false

    private struct Key: Identifiable {
        let label: String
        let code: UInt16
        var id: String { label }
    }

    private let modifierKeys: [(String, RemoteKeyModifiers)] = [
        ("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command),
    ]
    private let quickKeys: [Key] = [
        .init(label: "esc", code: RemoteKeyMap.Key.escape), .init(label: "tab", code: RemoteKeyMap.Key.tab),
        .init(label: "←", code: RemoteKeyMap.Key.left), .init(label: "↑", code: RemoteKeyMap.Key.up),
        .init(label: "↓", code: RemoteKeyMap.Key.down), .init(label: "→", code: RemoteKeyMap.Key.right),
        .init(label: "⌫", code: RemoteKeyMap.Key.delete), .init(label: "⌦", code: RemoteKeyMap.Key.forwardDelete),
        .init(label: "↩", code: RemoteKeyMap.Key.returnKey), .init(label: "space", code: RemoteKeyMap.Key.space),
    ]
    private let navKeys: [Key] = [
        .init(label: "home", code: RemoteKeyMap.Key.home), .init(label: "end", code: RemoteKeyMap.Key.end),
        .init(label: "pgUp", code: RemoteKeyMap.Key.pageUp), .init(label: "pgDn", code: RemoteKeyMap.Key.pageDown),
    ]
    private var functionKeys: [Key] {
        RemoteKeyMap.Key.function.enumerated().map { Key(label: "F\($0.offset + 1)", code: $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    grid(navKeys)
                    grid(functionKeys)
                }
                .padding(10)
                Rectangle().fill(M.divider).frame(height: 1)
            }
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: { cap(expanded ? "∨" : "∧", active: expanded) }
                    .buttonStyle(MPressStyle())
                ForEach(modifierKeys, id: \.0) { label, modifier in
                    Button { keys.toggle(modifier) } label: { cap(label, active: keys.modifiers.contains(modifier)) }
                        .buttonStyle(MPressStyle())
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickKeys) { key in
                            Button { tap(key) } label: { cap(key.label, active: false) }
                                .buttonStyle(MPressStyle())
                        }
                    }
                    .padding(.trailing, 10)
                }
            }
            .padding(.leading, 10).padding(.vertical, 7)
        }
        .background(M.surface)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
        .animation(.easeOut(duration: 0.18), value: expanded)
    }

    private func grid(_ keys: [Key]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], spacing: 6) {
            ForEach(keys) { key in
                Button { tap(key) } label: { cap(key.label, active: false, expand: true) }
                    .buttonStyle(MPressStyle())
            }
        }
    }

    /// 按一下特殊键：带上上膛的修饰（然后熄灭），按下再抬起。
    private func tap(_ key: Key) {
        let modifiers = keys.consume()
        send(.key(code: key.code, down: true, modifiers: modifiers))
        send(.key(code: key.code, down: false, modifiers: modifiers))
    }

    private func cap(_ text: String, active: Bool, expand: Bool = false) -> some View {
        Text(text)
            .font(M.mono(13, weight: .medium))
            .foregroundStyle(active ? accent : M.text)
            .lineLimit(1)
            .padding(.horizontal, expand ? 4 : 12)
            .frame(maxWidth: expand ? .infinity : nil, minHeight: 34, maxHeight: 34)
            .background(active ? accent.opacity(0.14) : M.button)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
