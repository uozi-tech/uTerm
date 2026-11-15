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
    /// 粘贴的进度（读取 / 压缩 / 发送，带进度条）与结果（「已粘贴到 Mac」/「已复制到手机」/ 失败原因）；
    /// 结果几秒后自己消失。
    @State private var pasteNote: PasteNote?
    @State private var pasteNoteTask: Task<Void, Never>?
    /// 一次粘一份：上一份还在路上时再点不另起一次。
    @State private var pasting = false
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
    /// 整块屏幕的大小（和 `barInsets` 同一个探针读的）。
    @State private var screenSize: CGSize?
    /// 顶栏除去顶边距（`barInsets.top`）的高度：画布上沿离屏幕顶边的距离减顶边距。
    @State private var barRowHeight: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.mAccent) private var accent

    var body: some View {
        GeometryReader { geometry in
            // 顶栏、画面、键盘条自上而下排在安全区里：顶栏不进摄像头开孔 / 圆角，「适配屏幕」把整块
            // Mac 屏幕放在顶栏之下的可见区；软键盘弹起时安全区底边抬到键盘上方，画面跟着缩到键盘之上，
            // 不被挡住。只有黑底铺满整屏。
            VStack(spacing: 0) {
                topBar(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
                       - barInsets.leading - barInsets.trailing)
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
                // 整列从屏幕顶边排起：画布上沿离屏幕顶边多远，顶栏就多高。
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                    barRowHeight = max(0, top - barInsets.top)
                }
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
            .background(ScreenCornerInsetsReader(insets: $barInsets, screen: $screenSize).ignoresSafeArea())
            .photosPicker(isPresented: $pickingPhoto, selection: $pickedPhoto, matching: .images)
            .sheet(isPresented: $enteringPassword) {
                if let session { passwordSheet(session) }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                Task { await pastePhoto(item) }
            }
            // 等屏幕和顶栏量出来再开（第一次排版之后就有）：要多大的画面按画布算。
            .task(id: requestedSize != nil) {
                guard session == nil, let requestedSize else { return }
                let created = RemoteDesktopSession(client: client, maxWidth: requestedSize.width,
                                                   maxHeight: requestedSize.height, pointScale: displayScale)
                created.onClipboard = { content in copyFromMac(content) }
                session = created
                refreshVault()
                await created.start()
            }
        }
        .onChange(of: requestedSize) { _, size in
            // 状态栏藏起来后安全区才变、顶栏跟着变矮：还没开流就按新的要。已经在放（或正在重连）的
            // 不动，不然 Mac 上的虚拟屏跟着换尺寸、窗口来回搬。
            guard let size, let session else { return }
            switch session.state {
            case .idle, .connecting, .failed, .ended: session.setRequestedSize(width: size.width, height: size.height)
            case .streaming, .reconnecting, .unsupported: break
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
        .onChange(of: session?.audioState) { _, state in
            // Mac 上没开、采集停了、拔了耳机：按钮已经复位，这里说一声为什么。
            if case .unavailable(let reason) = state { showPasteNote(reason) }
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

    /// 向 Mac 要多大的画面：比例按顶栏下面的画布，大小不小于屏幕像素（见 `RemoteDesktopRequestSize`）。
    /// 屏幕或顶栏还没量出来时为 nil。
    private var requestedSize: RemoteDesktopRequestSize? {
        guard let screenSize, barRowHeight > 0 else { return nil }
        return .fitting(screen: screenSize, scale: displayScale, barHeight: barInsets.top + barRowHeight,
                        topInset: barInsets.top)
    }

    // MARK: - 顶栏

    private func topBar(width barWidth: CGFloat) -> some View {
        // 读数只在画面在传时有；宽屏放进这一行的空当，窄屏另起一行（按宽度定，不按内容定：
        // 读数每秒都在变宽变窄，按内容定会在两种排法之间来回跳，画面高度跟着抖）。
        let stats = showStats && session?.state == .streaming ? session?.statItems : nil
        let inline = barWidth >= Self.inlineStatsMinWidth
        return VStack(alignment: .leading, spacing: 6) {
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
                        .font(M.sans(10.5))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { showStats.toggle() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(showStats ? "隐藏延迟与帧率" : "显示延迟与帧率")
                if inline, let stats {
                    statsStrip(stats).padding(.leading, 16)
                }
                Spacer(minLength: 8)
                if let session, session.supportsAudio, session.state == .streaming {
                    barButton(audioOn ? "speaker.wave.2.fill" : "speaker.slash", active: audioOn) { session.toggleAudio() }
                        .accessibilityLabel(audioOn ? "关闭声音" : "打开声音")
                }
                barButton("arrow.down.right.and.arrow.up.left") { fitToken += 1 }
                    .accessibilityLabel("适配屏幕")
                if session?.canControl == true {
                    barButton(keyBarShown ? "keyboard.chevron.compact.down" : "keyboard", active: keyBarShown) {
                        keyBarShown.toggle()
                        keyboardVisible = keyBarShown
                    }
                    .accessibilityLabel(keyBarShown ? "收起键盘" : "弹出键盘")
                }
                // 不常用的（粘贴、帘幕、解锁密码）收进一个菜单，顶栏只留声音、适配屏幕和键盘。
                if hasMoreActions {
                    MMenu { moreActions } label: { barIcon("ellipsis") }
                        .accessibilityLabel("更多")
                }
            }
            if !inline, let stats {
                statsStrip(stats)
            }
        }
        // 上、左、右都是离屏幕边缘的绝对距离（整列已铺满屏幕），按安全区与屏幕圆角取大，
        // 见 `ScreenCornerInsetsReader`：全屏隐藏状态栏时有的机型安全区接近 0，两端按钮正落在圆角弧线里。
        .padding(.top, barInsets.top)
        .padding(.bottom, 6)
        .padding(.leading, barInsets.leading)
        .padding(.trailing, barInsets.trailing)
    }

    /// 顶栏够这么宽（已扣掉两侧让出的距离）时读数放进名字和按钮之间，不另起一行。
    static let inlineStatsMinWidth: CGFloat = 760

    private func statsStrip(_ items: [RemoteDesktopStat]) -> some View {
        RemoteDesktopStatsStrip(items: items)
            .contentShape(Rectangle())
            .onTapGesture { showStats.toggle() }
    }

    private var canPaste: Bool { session?.canPaste == true }

    private var canCurtain: Bool {
        guard let session else { return false }
        return session.screen.canToggleCurtain(supportsUnlock: session.supportsUnlock)
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

    // MARK: - 声音

    private var audioOn: Bool { session?.isAudioOn == true }

    private var statusLine: String {
        guard let session else { return String(localized: "正在连接…") }
        return session.statusText(controlling: String(localized: "触控板模式")) ?? ""
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
        await paste { try await RemoteDesktopPasteSource.clipboard() }
    }

    private func pastePhoto(_ item: PhotosPickerItem) async {
        await paste { try await RemoteDesktopPasteSource.photo(item) }
    }

    /// 读出内容、发给 Mac，等全部交给链路后报结果。读取、压缩、打包都不在主线程上做，进度画在顶上的提示里。
    private func paste(_ load: @MainActor () async throws -> RemoteDesktopPaste) async {
        guard let session, session.canPaste, !pasting else { return }
        pasting = true
        defer { pasting = false }
        showPasteNote(PasteProgress(.reading).note)
        let relay = PasteProgressRelay { progress in
            guard let current = pasteNote?.progress, progress.overall >= current else { return }
            pasteNote = progress.note
        }
        do {
            let content = try await PasteProgressReporter.$sink.withValue(relay.sink) {
                let content = try await load()
                try await session.pasteAndWait(content)
                return content
            }
            showPasteNote(RemoteDesktopPasteEncoding.sentNote(content))
        } catch {
            showPasteNote(error.localizedDescription)
        }
    }

    /// Mac 上拷贝的文字（⌘C / 右键「拷贝」）放进手机剪贴板。
    private func copyFromMac(_ content: RemoteDesktopClipboard) {
        if case .text(let text) = content { UIPasteboard.general.string = text }
        showPasteNote(RemoteDesktopPasteEncoding.receivedNote(content, source: "Mac", here: String(localized: "手机")))
    }

    private func showPasteNote(_ text: String) {
        showPasteNote(PasteNote(text: text))
    }

    /// 带进度的（进行中）一直留着，直到换成结果；结果几秒后自己消失。
    private func showPasteNote(_ note: PasteNote) {
        pasteNoteTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { pasteNote = note }
        guard note.progress == nil else { return }
        pasteNoteTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { pasteNote = nil }
        }
    }

    @ViewBuilder private var pasteToast: some View {
        if let pasteNote {
            VStack(spacing: 6) {
                Text(pasteNote.text)
                    .font(M.sans(13, weight: .medium))
                    .foregroundStyle(.white)
                if let progress = pasteNote.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 180)
                        .accessibilityLabel(pasteNote.text)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: pasteNote.progress == nil ? 100 : 14, style: .continuous)
                .fill(.black.opacity(0.75)))
            .padding(.top, 10)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 状态遮罩

    @ViewBuilder private func overlay(_ session: RemoteDesktopSession) -> some View {
        if let notice = session.notice(macName: client.macName, showsClose: true) {
            self.notice(spinner: notice.spinner, title: notice.title, message: notice.message, dim: notice.dim) {
                ForEach(Array(notice.actions.enumerated()), id: \.offset) { index, action in
                    MBtn(title: action.title, kind: index == 0 ? .primary : .secondary, height: 42) {
                        perform(action, session)
                    }.fixedSize()
                }
            }
        } else if let caption = session.controlCaption {
            bottomCaption(caption)
        }
    }

    private func perform(_ action: RemoteDesktopNotice.Action, _ session: RemoteDesktopSession) {
        switch action {
        case .retry, .reconnect: Task { await session.start() }
        case .close: onClose()
        }
    }

    /// 底部一句说明，不挡画面、不接触摸。
    private func bottomCaption(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(M.sans(12))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(.bottom, 24).padding(.horizontal, 20)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 锁屏解锁

    /// Mac 停在锁屏、且这台 Mac 支持远程解锁时盖在画面上：一个「解锁 Mac」入口。解锁成功后 Mac 进入帘幕，
    /// 锁屏状态由 Mac 推来的 `desktopScreenState` 翻转，这层自然消失。什么时候显示见 `lockPrompt`。
    @ViewBuilder private func lockOverlay(_ session: RemoteDesktopSession) -> some View {
        switch session.lockPrompt(macName: client.macName) {
        case .none:
            EmptyView()
        case .caption(let text):
            bottomCaption(text)
        case .unlock where !lockOverlayDismissed:
            let working = unlockPhase == .working
            notice(spinner: working, title: String(localized: "Mac 已锁定"), message: lockMessage(session)) {
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
        case .unlock:
            EmptyView()
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
        unlockPhase = outcome.failureMessage.map { .failed($0) } ?? .idle
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
///
/// 顺带报整块屏幕的大小：向 Mac 要多大的画面要用（`RemoteDesktopRequestSize`），SwiftUI 的排版框在状态栏
/// 藏起来之前少一条安全区，不是整块屏幕。
private struct ScreenCornerInsetsReader: UIViewRepresentable {
    static let cornerClearanceSide: CGFloat = 24
    static let cornerClearanceTop: CGFloat = 14

    @Binding var insets: EdgeInsets
    @Binding var screen: CGSize?

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.onChange = { insets = $0; screen = $1 }
        return probe
    }

    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        var onChange: ((EdgeInsets, CGSize) -> Void)?
        private var reported: (insets: EdgeInsets, screen: CGSize)?

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
            // 还没排版（安全区先变）时没有大小可报。
            guard bounds.width > 0, bounds.height > 0 else { return }
            let screen = bounds.size
            guard reported?.insets != value || reported?.screen != screen else { return }
            reported = (value, screen)
            // 布局回调里不直接改 SwiftUI 状态。
            DispatchQueue.main.async { [weak self] in self?.onChange?(value, screen) }
        }
    }
}
