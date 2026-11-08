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
    /// 键盘条开着（顶栏的键盘按钮）。软键盘另算：键盘条上可以收起 / 弹出，面板开着时也收起。
    @State private var keyBarShown = false
    @State private var keyboardVisible = false
    @State private var fitToken = 0
    @State private var showStats = false
    @State private var pickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    /// 粘贴的结果提示（「已粘贴到 Mac」/「已复制到手机」/ 失败原因），几秒后自己消失。
    @State private var pasteNote: String?
    @State private var pasteNoteTask: Task<Void, Never>?
    /// 远程解锁的进行态与密码输入。
    @State private var unlockPhase: UnlockPhase = .idle
    @State private var enteringPassword = false
    @State private var passwordDraft = ""
    @State private var vault: RemoteUnlockPasswordStore = KeychainRemoteUnlockStore()
    /// 这次锁屏里用户点了「自己输入」：先不再盖遮罩，Mac 解锁后（再锁时）重置。
    @State private var lockOverlayDismissed = false
    /// 密码框只保存（顶栏「设置解锁密码」）还是保存后立即解锁（锁屏遮罩）。
    @State private var passwordSheetSavesOnly = false
    /// 这台 Mac 存没存过解锁密码。查钥匙串有开销，不能每次重绘都查（顶栏每秒刷新统计）：
    /// 只在进页面、存、删之后刷新一次。
    @State private var hasSavedPassword = false
    /// 这一屏在显示中（控制屏幕常亮用，见 `keepsScreenAwake`）。
    @State private var onScreen = false
    /// 本机的生物识别名称（面容 ID / 触控 ID）；以 ASCII 结尾时补一个空格，便于直接接中文。
    private static let biometryLead: String = {
        let title = MobileBiometry.describe().title
        return title.last?.isASCII == true ? title + " " : title
    }()

    enum UnlockPhase: Equatable {
        case idle
        case working
        case failed(String)
    }
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
                        lockOverlay(session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { pasteToast }
                if keyBarShown, let session, session.canControl {
                    RemoteDesktopKeyBar(keys: keys, keyboardShown: $keyboardVisible) { session.send($0) }
                }
            }
            // 整列铺满屏幕，顶栏的边距按离屏幕边缘的绝对距离给（`barInsets`），不与安全区混算。
            // 画面左右也就铺满：有的机型（Duo 外屏竖握）把一侧摄像头算成整条安全区，让出去就白白少两成宽度，
            // 开孔压住画面一角可以接受。只忽略容器安全区，软键盘弹起时整列照样缩到键盘上方。
            // 键盘条开着时底边不忽略：键盘收起后键盘条要让开 Home 条（它自己的底色照样铺到屏幕底边）。
            .ignoresSafeArea(.container, edges: keyBarShown ? [.top, .horizontal] : .all)
            .background(Color.black.ignoresSafeArea())
            .background(ScreenCornerInsetsReader(insets: $barInsets).ignoresSafeArea())
            .photosPicker(isPresented: $pickingPhoto, selection: $pickedPhoto, matching: .images)
            .sheet(isPresented: $enteringPassword) {
                if let session { passwordSheet(session) }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                Task { await pastePhoto(item) }
            }
            .task {
                guard session == nil else { return }
                let created = makeSession(size: geometry.size)
                created.onClipboard = { content in copyFromMac(content) }
                session = created
                refreshVault()
                await created.start()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // 画布从屏幕边缘起手的操作优先：系统手势要再滑一次才触发。
        .defersSystemGestures(on: .all)
        // 这一屏永远是黑底：配色一律按深色解析。跟随系统时浅色模式下的次要按钮是深灰字，落在黑底上看不见。
        .environment(\.colorScheme, .dark)
        // 看画面时不自动锁屏；停在失败 / 已结束这类要人处理的页面上就交还系统，不然手机放着屏幕一直亮。
        // 重连中照样不锁：短暂断一下就恢复，静静看着的人不该在这几秒里被锁屏。
        .onChange(of: Self.keepsScreenAwake(session?.state)) { _, awake in
            // 离开后（`stop()` 把状态改回 idle 也会触发这里）不能再把常亮打开。
            guard onScreen else { return }
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onAppear {
            onScreen = true
            UIApplication.shared.isIdleTimerDisabled = Self.keepsScreenAwake(session?.state)
        }
        .onDisappear {
            onScreen = false
            UIApplication.shared.isIdleTimerDisabled = false
            session?.stop()
        }
        .onChange(of: session?.screen.locked ?? false) { _, locked in
            refreshVault()
            // Mac 解开了：清掉这次锁屏的「自己输入」与失败提示，下次锁屏重新显示解锁入口。
            if !locked {
                lockOverlayDismissed = false
                unlockPhase = .idle
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // 看不见画面了（切走 / 锁屏）：请 Mac 暂停推流（老 Mac 不认得就照旧推流），本机停掉解码和渲染、只回确认。
                session?.setBackgrounded(true)
            case .active:
                // 回到前台：恢复推流并从关键帧接上（后台期间跳过了帧、硬解会话也可能被收走）——会话自己要关键帧，
                // 新 Mac 靠「恢复」、老 Mac 靠关键帧请求；断了的由会话自己重连。
                session?.setBackgrounded(false)
            default:
                // inactive（拉下控制中心、来电横幅）画面还看得见，照常解。
                break
            }
        }
    }

    /// 什么时候让屏幕常亮：还没开流、连接中、看画面中、重连中。
    static func keepsScreenAwake(_ state: RemoteDesktopSession.State?) -> Bool {
        guard let state else { return true }
        return !state.isTerminal
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
                barButton(keyBarShown ? "keyboard.chevron.compact.down" : "keyboard", active: keyBarShown) {
                    keyBarShown.toggle()
                    keyboardVisible = keyBarShown
                }
                .accessibilityLabel(keyBarShown ? "收起键盘" : "弹出键盘")
            }
            // 不常用的（粘贴、帘幕、解锁密码）收进一个菜单，顶栏只留适配屏幕和键盘。
            if hasMoreActions {
                MMenu { moreActions } label: { barIcon("ellipsis") }
                    .accessibilityLabel("更多")
            }
        }
        // 上、左、右都是离屏幕边缘的绝对距离（整列已铺满屏幕），按安全区与屏幕圆角取大，
        // 见 `ScreenCornerInsetsReader`：全屏隐藏状态栏时有的机型安全区接近 0，两端按钮正落在圆角弧线里。
        .padding(.top, barInsets.top)
        .padding(.bottom, 6)
        .padding(.leading, barInsets.leading)
        .padding(.trailing, barInsets.trailing)
    }

    private var canPaste: Bool { session?.canPaste == true }

    /// 帘幕只在 Mac 开了远程解锁、且没锁屏时能切（锁着时开帘幕没有意义）。
    private var canCurtain: Bool {
        guard let session else { return false }
        return session.supportsUnlock && session.screen.unlockAvailable && !session.screen.locked
    }

    private var canManagePassword: Bool { session?.supportsUnlock == true && client.macDeviceID != nil }

    private var hasMoreActions: Bool { canPaste || canCurtain || canManagePassword }

    @ViewBuilder private var moreActions: some View {
        if canPaste {
            Section {
                Button { Task { await pasteClipboard() } } label: {
                    Label("粘贴到 Mac", systemImage: "doc.on.clipboard")
                }
                Button { pickingPhoto = true } label: {
                    Label("从相册选择图片…", systemImage: "photo")
                }
            }
        }
        if canCurtain, let session {
            let curtained = session.screen.curtained
            Section {
                Button { session.setCurtain(!curtained) } label: {
                    Label(curtained ? "关闭帘幕" : "开启帘幕", systemImage: curtained ? "eye" : "eye.slash")
                }
            }
        }
        if canManagePassword {
            Section {
                Button {
                    passwordDraft = ""
                    passwordSheetSavesOnly = true
                    enteringPassword = true
                } label: {
                    Label(vaultHasPassword ? "修改解锁密码…" : "设置解锁密码…", systemImage: "key")
                }
                if vaultHasPassword {
                    Button(role: .destructive) {
                        if let macID = client.macDeviceID { vault.remove(forMac: macID) }
                        refreshVault()
                    } label: {
                        Label("删除已保存的密码", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var statusLine: String {
        guard let session else { return "正在连接…" }
        switch session.state {
        case .streaming:
            let mode = session.canControl ? "触控板模式" : "仅查看"
            let base = session.screen.curtained ? mode + " · 帘幕已开" : mode
            guard showStats else { return base }
            let stats = session.stats
            // 延迟放最前：最先要看的是「点一下多久见到结果」，其余是排查用的分项。
            let latency = session.latency.map { "延迟 \($0.p50Millis) ms（p95 \($0.p95Millis)）· " } ?? ""
            return base + " · " + latency + String(format: "%.0f fps · %.1f Mbps · 解码 %.1f ms", stats.framesPerSecond,
                                                   stats.megabitsPerSecond, stats.decodeMillis)
        case .idle, .connecting: return "正在连接…"
        case .reconnecting: return "连接已断开，正在重新连接…"
        case .failed: return "连接失败"
        case .ended: return "已结束"
        case .unsupported: return "Mac 上的 uTerm 版本过旧"
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

    /// Mac 上拷贝的文字（⌘C / 右键「拷贝」）放进手机剪贴板。
    private func copyFromMac(_ content: RemoteDesktopClipboard) {
        switch content {
        case .text(let text):
            UIPasteboard.general.string = text
            showPasteNote("已拷贝到手机")
        case .tooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            showPasteNote("Mac 上拷贝的内容过大（\(size)），没有拷贝到手机")
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
            notice(spinner: true, title: "连接已断开，正在重新连接…", message: "重新连接后画面自动恢复", dim: true)
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
            notice(spinner: false, title: "无法打开屏幕", message: message) {
                MBtn(title: "重试", kind: .primary, height: 42) { Task { await session.start() } }.fixedSize()
                MBtn(title: "关闭", kind: .secondary, height: 42, action: onClose).fixedSize()
            }
        case .ended(let reason):
            notice(spinner: false, title: "远程桌面已结束", message: reason) {
                MBtn(title: "重新连接", kind: .primary, height: 42) { Task { await session.start() } }.fixedSize()
                MBtn(title: "关闭", kind: .secondary, height: 42, action: onClose).fixedSize()
            }
        case .unsupported:
            notice(spinner: false, title: "Mac 上的 uTerm 需要更新",
                   message: RemoteDesktopError.macTooOld.localizedDescription) {
                MBtn(title: "关闭", kind: .primary, height: 42, action: onClose).fixedSize()
            }
        }
    }

    // MARK: - 锁屏解锁

    /// Mac 停在锁屏、且这台 Mac 支持远程解锁时盖在画面上：一个「解锁 Mac」入口。解锁成功后 Mac 进入帘幕，
    /// 锁屏状态由 Mac 推来的 `desktopScreenState` 翻转，这层自然消失。
    @ViewBuilder private func lockOverlay(_ session: RemoteDesktopSession) -> some View {
        if session.supportsUnlock, session.screen.locked {
            if session.screen.unlockAvailable, !lockOverlayDismissed {
                let working = unlockPhase == .working
                notice(spinner: working, title: "Mac 已锁定",
                       message: lockMessage(session)) {
                    if !working {
                        MBtn(title: vaultHasPassword ? "解锁 Mac" : "输入密码解锁", kind: .primary, height: 42) {
                            beginUnlock(session)
                        }.fixedSize()
                        if vaultHasPassword {
                            MBtn(title: "改用其他密码", kind: .secondary, height: 42) {
                                passwordDraft = ""
                                passwordSheetSavesOnly = false
                                enteringPassword = true
                            }.fixedSize()
                        }
                        // 关掉这层，直接在锁屏画面上用键盘输密码（这样解开的不会进帘幕）。
                        MBtn(title: "在锁屏上输入", kind: .secondary, height: 42) { lockOverlayDismissed = true }.fixedSize()
                    }
                }
            } else if !session.screen.unlockAvailable {
                // 没开远程解锁：不挡画面（仍可在锁屏上手动输密码），只在底部提示一句。
                VStack {
                    Spacer()
                    Text("Mac 已锁定。在 Mac 的「设置 › 远程控制」中打开「允许远程解锁」后，可以在这里一键解锁。")
                        .font(M.sans(12))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.bottom, 24).padding(.horizontal, 20)
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// 只在 `unlockAvailable` 为真时由 `lockOverlay` 调用。
    private func lockMessage(_ session: RemoteDesktopSession) -> String {
        if case .failed(let reason) = unlockPhase { return reason }
        return vaultHasPassword
            ? "用\(Self.biometryLead)取出已保存的密码解锁。解锁后 Mac 屏幕会变黑，Mac 本机的键盘和鼠标暂停使用。"
            : "输入这台 Mac 的登录密码。解锁后 Mac 屏幕会变黑，Mac 本机的键盘和鼠标暂停使用。密码只保存在这台手机上。"
    }

    private var vaultHasPassword: Bool { hasSavedPassword }

    private func refreshVault() {
        hasSavedPassword = client.macDeviceID.map { vault.hasPassword(forMac: $0) } ?? false
    }

    private func passwordSheet(_ session: RemoteDesktopSession) -> some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("登录密码", text: $passwordDraft)
                        .textContentType(.password)
                } footer: {
                    Text("密码只保存在这台手机的钥匙串里，不会同步到 iCloud，取用时需要\(Self.biometryLead)验证。")
                }
            }
            .navigationTitle(passwordSheetSavesOnly ? "\(client.macName) 的解锁密码" : "解锁 \(client.macName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { enteringPassword = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(passwordSheetSavesOnly ? "保存" : "解锁") {
                        let password = passwordDraft
                        passwordDraft = ""
                        enteringPassword = false
                        if let macID = client.macDeviceID {
                            do {
                                try vault.save(password, forMac: macID)
                                if passwordSheetSavesOnly { showPasteNote("已保存解锁密码") }
                            } catch {
                                showPasteNote("无法把密码保存到钥匙串：\(RemoteUnlockVaultError.describe(error))")
                            }
                        }
                        refreshVault()
                        // 只保存时不发解锁：Mac 可能根本没锁，用户只是先把密码存好。
                        if !passwordSheetSavesOnly { Task { await submitUnlock(session, password: password) } }
                    }.disabled(passwordDraft.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func beginUnlock(_ session: RemoteDesktopSession) {
        guard let macID = client.macDeviceID, vault.hasPassword(forMac: macID) else {
            passwordDraft = ""
            passwordSheetSavesOnly = false
            enteringPassword = true
            return
        }
        unlockPhase = .working
        Task {
            do {
                guard let password = try await vault.password(forMac: macID, reason: "解锁 \(client.macName)") else {
                    unlockPhase = .idle
                    passwordSheetSavesOnly = false
                    enteringPassword = true
                    return
                }
                await submitUnlock(session, password: password)
            } catch {
                unlockPhase = .failed("\(Self.biometryLead)验证未通过。")
            }
        }
    }

    private func submitUnlock(_ session: RemoteDesktopSession, password: String) async {
        unlockPhase = .working
        let outcome = await session.unlock(password: password)
        switch outcome {
        case .unlocked, .notLocked:
            unlockPhase = .idle
        case .rejected:
            unlockPhase = .failed("密码不正确。可以重试，或改用其他密码。")
        case .timedOut:
            unlockPhase = .failed("解锁超时，可以重试。")
        case .notAllowed:
            unlockPhase = .failed("这台 Mac 不允许远程解锁。")
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
