import PhotosUI
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
    @State private var pickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    /// 粘贴的结果提示（「已粘贴到 Mac」/ 失败原因），几秒后自己消失。
    @State private var pasteNote: String?
    @State private var pasteNoteTask: Task<Void, Never>?
    /// 顶栏左右要让出的距离（按屏幕圆角算，见 `ScreenCornerInsetsReader`）。
    @State private var barInsets = EdgeInsets(top: 14, leading: 24, bottom: 0, trailing: 24)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.mAccent) private var accent

    var body: some View {
        GeometryReader { geometry in
            // 顶栏、画面、键盘条自上而下排在安全区里：顶栏不进摄像头开孔 / 圆角，「适配屏幕」把整块
            // Mac 屏幕放在顶栏之下的可见区；软键盘弹起时安全区底边抬到键盘上方，画面跟着缩到键盘之上，
            // 不被挡住。只有黑底铺满整屏。
            VStack(spacing: 0) {
                topBar
                ZStack {
                    if let session {
                        RemoteDesktopCanvas(session: session, keys: keys, keyboardVisible: $keyboardVisible, fitToken: fitToken,
                                            displaySize: session.info.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) })
                        overlay(session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { pasteToast }
                if keyboardVisible, let session, session.canControl {
                    RemoteDesktopKeyBar(keys: keys) { session.send($0) }
                }
            }
            // 整列铺满屏幕，顶栏的边距按离屏幕边缘的绝对距离给（`barInsets`），不与安全区混算。
            // 画面左右也就铺满：有的机型（Duo 外屏竖握）把一侧摄像头算成整条安全区，让出去就白白少两成宽度，
            // 开孔压住画面一角可以接受。只忽略容器安全区，软键盘弹起时整列照样缩到键盘上方。
            .ignoresSafeArea(.container)
            .background(Color.black.ignoresSafeArea())
            .background(ScreenCornerInsetsReader(insets: $barInsets).ignoresSafeArea())
            .photosPicker(isPresented: $pickingPhoto, selection: $pickedPhoto, matching: .images)
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                Task { await pastePhoto(item) }
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
        // 画布从屏幕边缘起手的操作优先：系统手势要再滑一次才触发。
        .defersSystemGestures(on: .all)
        // 这一屏永远是黑底：配色一律按深色解析。跟随系统时浅色模式下的次要按钮是深灰字，落在黑底上看不见。
        .environment(\.colorScheme, .dark)
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
            if session?.canPaste == true {
                Menu {
                    Button { Task { await pasteClipboard() } } label: {
                        Label("粘贴剪贴板内容", systemImage: "doc.on.clipboard")
                    }
                    Button { pickingPhoto = true } label: {
                        Label("从相册选择图片…", systemImage: "photo")
                    }
                } label: {
                    barIcon("doc.on.clipboard")
                }
                .accessibilityLabel("粘贴到 Mac")
            }
            barButton("arrow.down.right.and.arrow.up.left") { fitToken += 1 }
                .accessibilityLabel("适配屏幕")
            if session?.canControl == true {
                barButton(keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard", active: keyboardVisible) {
                    keyboardVisible.toggle()
                }
                .accessibilityLabel(keyboardVisible ? "收起键盘" : "键盘")
            }
        }
        // 上、左、右都是离屏幕边缘的绝对距离（整列已铺满屏幕），按安全区与屏幕圆角取大，
        // 见 `ScreenCornerInsetsReader`：全屏隐藏状态栏时有的机型安全区接近 0，两端按钮正落在圆角弧线里。
        .padding(.top, barInsets.top)
        .padding(.bottom, 6)
        .padding(.leading, barInsets.leading)
        .padding(.trailing, barInsets.trailing)
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
        Button(action: action) { barIcon(symbol, active: active) }
            .buttonStyle(MPressStyle())
    }

    private func barIcon(_ symbol: String, active: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(active ? accent : .white)
            .frame(width: 36, height: 32)
            .background(Color.white.opacity(active ? 0.18 : 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 粘贴到 Mac

    private func pasteClipboard() async {
        do {
            send(try await RemoteDesktopPasteSource.clipboard())
        } catch {
            showPasteNote(error.localizedDescription)
        }
    }

    private func pastePhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw RemoteDesktopPasteSource.Failure.unreadableImage
            }
            send(try await RemoteDesktopPasteSource.image(data: data))
        } catch {
            showPasteNote(error.localizedDescription)
        }
    }

    private func send(_ content: RemoteDesktopPaste) {
        guard let session, session.canPaste else { return }
        session.paste(content)
        switch content {
        case .text: showPasteNote("已把文字粘贴到 Mac")
        case .png, .jpeg: showPasteNote("已把图片粘贴到 Mac")
        }
    }

    private func showPasteNote(_ note: String) {
        pasteNoteTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { pasteNote = note }
        pasteNoteTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { pasteNote = nil }
        }
    }

    @ViewBuilder private var pasteToast: some View {
        if let pasteNote {
            Text(pasteNote)
                .font(M.sans(13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.75)))
                .padding(.top, 10)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
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

/// 读出贴着屏幕顶边的栏要让出多少，才不被屏幕圆角切掉（都是离屏幕边缘的绝对距离）。
///
/// 全屏隐藏状态栏时，有的机型顶边与两侧的安全区都是 0（Duo 内屏实测：上 0、左右 0），两端按钮
/// 正落在圆角弧线里。iOS 26 起系统按这块屏幕的圆角给两组安全区：`cornerAdaptation: .horizontal`
///（同机左右各 16）与 `.vertical`（顶 16）。贴顶又贴边的按钮两组都要满足。
/// 更早的系统没有这两个接口，用固定的 `cornerClearanceSide` / `cornerClearanceTop`：
/// (R − 24)² + (R − 14)² ≤ R² 对 R ≤ 62pt（现有 iPhone 的上限）都成立。
/// 安全区本来就更大（刘海屏竖握、横握的灵动岛那侧）时取安全区。
/// 铺满全屏、不接触摸，只在布局 / 安全区变化时回报。
private struct ScreenCornerInsetsReader: UIViewRepresentable {
    static let cornerClearanceSide: CGFloat = 24
    static let cornerClearanceTop: CGFloat = 14

    @Binding var insets: EdgeInsets

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.onChange = { insets = $0 }
        return probe
    }

    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        var onChange: ((EdgeInsets) -> Void)?
        private var reported: EdgeInsets?

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            let safe = safeAreaInsets
            let value: EdgeInsets
            if #available(iOS 26.0, *) {
                // 系统按这块屏幕的圆角给的两组安全区：内容离两侧 h、或离顶 v 就避开了圆角。
                // 栏的两端按钮既贴顶又贴边，所以顶取 v、两侧取 h 再加按钮自身的圆角（8pt）。
                let h = edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
                let v = edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
                let buttonCorner: CGFloat = 8
                value = EdgeInsets(top: max(safe.top, v.top),
                                   leading: max(safe.left, h.left + buttonCorner),
                                   bottom: 0,
                                   trailing: max(safe.right, h.right + buttonCorner))
            } else {
                let side = ScreenCornerInsetsReader.cornerClearanceSide
                value = EdgeInsets(top: max(safe.top, ScreenCornerInsetsReader.cornerClearanceTop),
                                   leading: max(safe.left, side), bottom: 0, trailing: max(safe.right, side))
            }
            guard value != reported else { return }
            reported = value
            // 布局回调里不直接改 SwiftUI 状态。
            DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
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
