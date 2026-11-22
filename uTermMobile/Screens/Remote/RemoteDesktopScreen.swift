import PhotosUI
import SwiftUI
import UIKit

/// 远程桌面：全屏看 / 控制一台 Mac 的屏幕。从 Mac 面板的「屏幕」进入。
///
/// 画面与手势在 `RemoteDesktopCanvas`（UIKit）里；这里只管外壳：顶栏（关闭、状态、键盘、适配屏幕）、
/// 连接状态的遮罩（连接中 / 重连中 / 失败 / 已结束 / Mac 版本太旧）、键盘条、前后台切换。
struct RemoteDesktopScreen: View {
    let client: RemoteMacClient
    /// 用户点开屏幕的时刻（交给开屏时间线，见 `RemoteDesktopSession.openRequestedAt`）。
    var tappedAt: ContinuousClock.Instant?
    let onClose: () -> Void

    @State private var session: RemoteDesktopSession?
    /// 等画面尺寸稳住再记下来（`rememberRequestedSizeWhenSettled`）。
    @State private var sizeMemoryTask: Task<Void, Never>?

    /// 这一屏用的是点按钮时就开了流的会话（按记下的尺寸开的）。
    private let startedEarly: Bool
    /// 一进来就只看这个窗口（nil = 整个屏幕）。
    private let initialWindow: UInt32?
    @AppStorage(DefaultsKey.remoteDesktopFitWindow) private var fitsWindow = true

    /// `started`：点按钮时就开了流的会话（`RemoteDesktopRequestSizeMemory`），这一屏接着用，不另开。
    ///
    /// `initialWindow`：一进来就只看这个窗口（在 Mac 的面板里直接点了它），不先开整个屏幕。
    init(client: RemoteMacClient, tappedAt: ContinuousClock.Instant? = nil, started: RemoteDesktopSession? = nil,
         initialWindow: UInt32? = nil, onClose: @escaping () -> Void) {
        self.client = client
        self.tappedAt = tappedAt
        self.onClose = onClose
        self.initialWindow = initialWindow
        startedEarly = started != nil
        _session = State(initialValue: started)
    }
    @State private var keys = RemoteDesktopKeyState()
    /// 键盘条开着（顶栏的键盘按钮）。软键盘另算：键盘条上可以收起 / 弹出，面板开着时也收起。
    @State private var keyBarShown = false
    @State private var keyboardVisible = false
    @State private var fitToken = 0
    @State private var showStats = false
    @State private var pickingPhoto = false
    /// 正在选「只看哪一个窗口」。
    @State private var pickingWindow = false
    /// 只看一个窗口时工具栏默认收着，点角上的按钮才浮出来。
    @State private var windowBarShown = false
    /// 画布（顶栏下面那块）此刻的点尺寸：只看一个窗口时请 Mac 把窗口调成这么大。
    @State private var canvasSize = CGSize.zero
    @State private var refitTask: Task<Void, Never>?
    @AppStorage(DefaultsKey.remoteDesktopWindowTextScale) private var windowTextScale = RemoteDesktopWindowFit.defaultTextScale
    /// 窗口模式下用触摸屏的方式操作（点哪里就是哪里），不用触控板式的指针。
    @AppStorage(DefaultsKey.remoteDesktopWindowTouchMode) private var windowTouchMode = false
    /// 窗口模式下看着的时候请 Mac 把那个窗口保持在最前。
    @AppStorage(DefaultsKey.remoteDesktopWindowKeepFront) private var keepsWindowFront = false
    @AppStorage(DefaultsKey.remoteDesktopWindowIndependentInput) private var independentWindowInput = true
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
    /// 密码框是替 Mac 屏上的验证框填的（填完不解锁，只回应那个框）。关掉密码框时清掉。
    @State private var passwordSheetAuthPrompt: RemoteDesktopAuthPrompt?
    /// 回应 Mac 验证框的进行态（与锁屏解锁分开：两件事不会同时发生，但提示各管各的）。
    @State private var authPromptPhase: UnlockPhase = .idle
    /// 这台 Mac 存没存过解锁密码。查钥匙串有开销，不能每次重绘都查（顶栏每秒刷新统计）：
    /// 只在进页面、存、删之后刷新一次。
    @State private var hasSavedPassword = false
    /// 这一屏在显示中（控制屏幕常亮用，见 `keepsScreenAwake`）。
    @State private var onScreen = false
    /// 本机的生物识别名称（面容 ID / 触控 ID）。界面是中文时，以 ASCII 结尾的补一个空格，便于直接接中文；
    /// 别的语言不补，空格由译文自己写。
    private static let biometryLead: String = {
        let title = MobileBiometry.describe().title
        let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        return chinese && title.last?.isASCII == true ? title + " " : title
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
    /// 画布的位置量出来过没有。窗口模式下顶上那一行可以是 0 高（横握、状态栏藏着时安全区上沿就是屏幕顶边），
    /// 不能再拿「顶栏高度大于 0」当成「排过版了」。
    @State private var canvasMeasured = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.mAccent) private var accent

    var body: some View {
        GeometryReader { geometry in
            // 顶栏、画面、键盘条自上而下排在安全区里：顶栏不进摄像头开孔 / 圆角，「适配屏幕」把整块
            // Mac 屏幕放在顶栏之下的可见区；软键盘弹起时安全区底边抬到键盘上方，画面跟着缩到键盘之上，
            // 不被挡住。只有黑底铺满整屏。
            let barWidth = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
                - barInsets.leading - barInsets.trailing
            VStack(spacing: 0) {
                if windowMode {
                    // 只看一个窗口：顶栏不占一行（Mac 窗口自己的标题栏就在最上面），画面顶到安全区上沿；
                    // 工具栏收成角上的小按钮，点开时浮在画面上（见 `windowBar`）。
                    Color.clear.frame(height: geometry.safeAreaInsets.top)
                } else {
                    topBar(width: barWidth)
                }
                ZStack {
                    if let session {
                        RemoteDesktopCanvas(session: session, keys: keys, keyboardVisible: $keyboardVisible,
                                            onSystemPaste: { Task { await pasteClipboard() } }, fitToken: fitToken,
                                            displaySize: session.info.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) },
                                            contentFraction: session.contentFraction, touchMode: touchMode,
                                            streamPixels: session.info.map { CGSize(width: $0.streamWidth, height: $0.streamHeight) })
                        overlay(session)
                        lockOverlay(session)
                        authPromptOverlay(session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
                .overlay(alignment: .top) { pasteToast }
                // 整列从屏幕顶边排起：画布上沿离屏幕顶边多远，顶栏就多高。
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                    barRowHeight = max(0, top - barInsets.top)
                    canvasMeasured = true
                }
                if keyBarShown, let session, session.canControl {
                    RemoteDesktopKeyBar(keys: keys, keyboardShown: $keyboardVisible, paste: pasteActions(session)) {
                        session.send($0)
                    }
                }
            }
            .overlay(alignment: .top) {
                if windowMode { windowBar(width: barWidth) }
            }
            .onChange(of: windowMode) { _, _ in windowBarShown = false }
            // 整列铺满屏幕，顶栏的边距按离屏幕边缘的绝对距离给（`barInsets`），不与安全区混算。
            // 画面左右也就铺满：有的机型（Duo 外屏竖握）把一侧摄像头算成整条安全区，让出去就白白少两成宽度，
            // 开孔压住画面一角可以接受。只忽略容器安全区，软键盘弹起时整列照样缩到键盘上方。
            // 键盘条开着时底边不忽略：键盘收起后键盘条要让开 Home 条（它自己的底色照样铺到屏幕底边）。
            .ignoresSafeArea(.container, edges: keyBarShown ? [.top, .horizontal] : .all)
            .background(Color.black.ignoresSafeArea())
            .background(ScreenCornerInsetsReader(insets: $barInsets, screen: $screenSize).ignoresSafeArea())
            // Mac 收得了文件时相册里也能选视频。
            .photosPicker(isPresented: $pickingPhoto, selection: $pickedPhoto,
                          matching: session?.canPasteFiles == true ? .any(of: [.images, .videos]) : .images)
            .sheet(isPresented: $enteringPassword, onDismiss: { passwordSheetAuthPrompt = nil }) {
                if let session { passwordSheet(session) }
            }
            .sheet(isPresented: $pickingWindow) {
                // 画布按窗口模式的排版算（顶栏不占行）：从整个屏幕换过去时，窗口一次就调成排版换完之后的大小，
                // 不用等排版变了再调第二次。
                if let session {
                    RemoteDesktopWindowPicker(session: session, canvasSize: windowCanvasSize(safeTop: geometry.safeAreaInsets.top))
                }
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
                                                   maxHeight: requestedSize.height,
                                                   pointScale: RemoteDesktopRequestSize.pointScale(displayScale: displayScale))
                created.onClipboard = { content in copyFromMac(content) }
                created.openRequestedAt = tappedAt
                session = created
                refreshVault()
                // 开流不放在这个 task 里跑：它跟着「要多大量出来没有」重启，排版途中那个值一变，开到一半的流就被取消。
                Task { await openFirst(created) }
            }
        }
        .onChange(of: canvasSize) { _, size in refitWindowWhenSettled(size) }
        .onChange(of: requestedSize) { _, size in
            rememberRequestedSizeWhenSettled(size)
            // 状态栏藏起来后安全区才变、顶栏跟着变矮：还没开流就按新的要。已经在放（或正在重连）的
            // 不动，不然 Mac 上的虚拟屏跟着换尺寸、窗口来回搬。
            // 点按钮时就开了流的（`startedEarly`）用的是上次量好的最终尺寸，不跟着排版途中的中间值改：
            // 中间值（状态栏还在时顶栏更高）一发过去，Mac 就把虚拟屏换成别的比例（2026-11-16 Duo：
            // 1280×828 → 1280×900，多等 342 ms，画面上下留黑边）。
            guard let size, let session, !startedEarly else { return }
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
            // 点按钮时就开了流的会话：补上这一屏的回调。
            if let session, session.onClipboard == nil {
                session.onClipboard = { content in copyFromMac(content) }
                refreshVault()
            }
        }
        .onDisappear {
            onScreen = false
            UIApplication.shared.isIdleTimerDisabled = false
            sizeMemoryTask?.cancel()
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
        .onChange(of: session?.screen.authPrompt?.id) { _, _ in
            // 框换了 / 关了：上一个框的失败提示不再适用。
            if authPromptPhase != .working { authPromptPhase = .idle }
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

    /// 新建的会话第一次开流：整个屏幕直接开；窗口模式先等画布停稳，按它的大小请 Mac 调窗口。
    private func openFirst(_ created: RemoteDesktopSession) async {
        guard let initialWindow else {
            await created.start()
            return
        }
        let canvas = await settledCanvasSize()
        // 等的时候页面已经关了：别再开流。
        guard onScreen, session === created else { return }
        let fit = fitsWindow
            ? RemoteDesktopWindowFit.size(canvas: canvas, textScale: windowTextScale, displayScale: displayScale) : nil
        await created.switchWindow(to: initialWindow, fit: fit, keepFront: keepsWindowFront,
                                   independentInput: independentWindowInput)
    }

    /// 等画布量出来并停稳（状态栏藏起来之后安全区会再变一次）：连续 160 ms 没变就算稳，最多等 1 秒。
    /// 不等的话窗口先按中间值调一次，几百毫秒后又按最终值调一次，流跟着重开。
    private func settledCanvasSize() async -> CGSize {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        var last = canvasSize
        var since = clock.now
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
            if canvasSize != last {
                last = canvasSize
                since = clock.now
            } else if last.width > 0, last.height > 0, clock.now - since >= .milliseconds(160) {
                break
            }
        }
        return canvasSize
    }

    /// 窗口模式下画布有多大：现在就是窗口模式时即 `canvasSize`；还在看整个屏幕时，把顶栏那一行换成窗口模式的
    /// 那一行（只让出安全区）算出来。
    private func windowCanvasSize(safeTop: CGFloat) -> CGSize {
        guard !windowMode, canvasSize.width > 0, canvasSize.height > 0 else { return canvasSize }
        let barRow = barInsets.top + barRowHeight
        return CGSize(width: canvasSize.width, height: canvasSize.height + max(0, barRow - safeTop))
    }

    /// 画布大小变了（转屏、折叠屏开合）：正在看一个调过大小的窗口时，等它稳住再请 Mac 按新的画布调一次。
    /// 键盘条、软键盘弹起收起也照调：窗口跟着缩到键盘上面那块画布里，整扇窗都看得见（2026-11-18 user 定；
    /// 原先键盘条开着时不调，开着键盘转到竖屏、或者弹出软键盘之后，窗口还是原来那么大，只露出一截）。
    private func refitWindowWhenSettled(_ size: CGSize) {
        refitTask?.cancel()
        guard let session, session.windowID != nil, session.windowFit != nil else { return }
        refitTask = Task {
            // 画布停稳这么久就发（每变一次重新计）。原先固定等 600 ms，占了调一次大小的一半时间；键盘弹出、转屏时
            // 画布的大小只变一两次，停稳 250 ms 足够认出是最终的大小。Mac 那头还原窗口有 600 ms 的宽限，
            // 在它之内到的重调不会和还原撞上。
            try? await Task.sleep(for: Self.refitSettle)
            guard !Task.isCancelled, canvasSize == size,
                  let fit = RemoteDesktopWindowFit.size(canvas: size, textScale: windowTextScale,
                                                        displayScale: displayScale) else { return }
            await session.refitWindow(to: fit)
        }
    }

    /// 记下这块屏幕要多大，下次点按钮时就能开流（`RemoteDesktopRequestSizeMemory`）。等它在屏幕上稳住
    /// `sizeMemorySettle` 才记：排版途中会先量出中间值（状态栏还在、顶栏更高），关页时状态栏回来又量出一个，
    /// 都只停几百毫秒。每量一次就记、或离开时才记，记下的都可能是这种值（2026-11-16 Duo：横屏记成 2853×2007，
    /// 也就是整块屏幕的比例，Mac 按它建出 1280×900 的屏，左右留黑边）。
    private func rememberRequestedSizeWhenSettled(_ size: RemoteDesktopRequestSize?) {
        sizeMemoryTask?.cancel()
        guard let size, let screenSize else { return }
        let scale = displayScale
        sizeMemoryTask = Task { @MainActor in
            try? await Task.sleep(for: Self.sizeMemorySettle)
            guard !Task.isCancelled, onScreen, requestedSize == size, self.screenSize == screenSize else { return }
            RemoteDesktopRequestSizeMemory.save(size, screen: screenSize, scale: scale)
        }
    }

    private static let sizeMemorySettle: Duration = .seconds(1)
    static let refitSettle: Duration = .milliseconds(250)

    /// 向 Mac 要多大的画面：顶栏下面那块画布的像素数（见 `RemoteDesktopRequestSize`）。
    /// 屏幕或顶栏还没量出来时为 nil。窗口模式下顶栏不占行，量出过画布的位置就算数。
    private var requestedSize: RemoteDesktopRequestSize? {
        guard let screenSize, windowMode ? canvasMeasured : barRowHeight > 0 else { return nil }
        return .fitting(screen: screenSize, scale: displayScale, barHeight: barInsets.top + barRowHeight,
                        topInset: barInsets.top, pixelExact: client.supportsDesktopRegion)
    }

    // MARK: - 顶栏

    /// 正在（或正要）只看一个窗口：排版换成画面顶到上沿、工具栏收起来的那一种。
    private var windowMode: Bool {
        if let session, session.windowID != nil { return true }
        // 从 Mac 的面板直接点了某个窗口进来、流还没开起来的那一小会儿。
        return initialWindow != nil && session?.state != .streaming && session?.info == nil
    }

    /// 此刻是不是触摸屏模式：只在窗口模式下有（整个屏幕太大，手指点不准，放大后单指还要用来挪指针）。
    private var touchMode: Bool { windowMode && windowTouchMode }

    /// 只看一个窗口时的工具栏：收着时是右上角一个小按钮；点开后整条浮在画面上沿（不占排版的地方，画布大小不变，
    /// Mac 上的窗口也就不用跟着重调）。
    @ViewBuilder private func windowBar(width barWidth: CGFloat) -> some View {
        if windowBarShown {
            // 底色不透明：半透明时下面亮的 Mac 画面透上来，整条发灰，按钮的浅色底和它混在一起分不出来
            // （2026-11-18 user：「按钮的配色很灾难」）。和看整个屏幕时的顶栏同一个黑底。
            topBar(width: barWidth)
                .background(Color.black.ignoresSafeArea(edges: .top))
                .overlay(alignment: .bottom) { Color.white.opacity(0.12).frame(height: 0.5) }
                .transition(.opacity)
        } else {
            HStack {
                Spacer()
                Button { windowBarShown = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 24)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        // 看着小，点得到：四周多给一圈可点的范围。
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MPressStyle())
                .accessibilityLabel("显示工具栏")
            }
            .padding(.top, max(0, barInsets.top - 8))
            .padding(.trailing, max(0, barInsets.trailing - 8))
        }
    }

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
                // 不常用的（帘幕、解锁密码）收进一个菜单，顶栏只留声音、适配屏幕和键盘；粘贴在键盘条上。
                if hasMoreActions {
                    MMenu { moreActions } label: { barIcon("ellipsis") }
                        .accessibilityLabel("更多")
                }
                if windowMode {
                    barButton("chevron.up") { windowBarShown = false }
                        .accessibilityLabel("收起工具栏")
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

    /// 键盘条上的粘贴键（粘贴要能控制，键盘条也只在能控制时出现）。
    private func pasteActions(_ session: RemoteDesktopSession) -> RemoteDesktopKeyBar.PasteActions? {
        guard session.canPaste else { return nil }
        return .init(allowsFiles: session.canPasteFiles,
                     pasteClipboard: { Task { await pasteClipboard() } },
                     pickPhoto: { pickingPhoto = true })
    }

    private var canCurtain: Bool {
        guard let session else { return false }
        return session.screen.canToggleCurtain(supportsUnlock: session.supportsUnlock)
    }

    private var canManagePassword: Bool { session?.supportsUnlock == true && client.macDeviceID != nil }

    /// 那台 Mac 接着几块显示器时才有「切换显示器」（老 Mac 不报列表）。
    private var displays: [RemoteDesktopDisplaySummary] {
        guard let displays = session?.info?.displays, displays.count > 1 else { return [] }
        return displays
    }

    /// 那台 Mac 的 uTerm 能不能只看一个窗口（老版本不能）。
    private var canPickWindow: Bool { session?.supportsWindows == true }

    private var hasMoreActions: Bool { !displays.isEmpty || canPickWindow || canCurtain || canManagePassword }

    /// 「更多」菜单。**要矮**：横握时屏幕只有六百多点高，以前十行（两块显示器各占两行、操作方式两行、密码两行）
    /// 比屏幕还高，系统把菜单顶出屏幕外，上下都点不全（2026-11-18 Duo 录屏）。所以成组的选项收进子菜单，
    /// 两选一的做成一个带勾的开关，最多七行。
    @ViewBuilder private var moreActions: some View {
        Section {
            if let session, !displays.isEmpty {
                // 子菜单里用系统的选择器：勾单独占一列，几块屏的名字左边对齐。
                Picker(selection: Binding(
                    get: { session.info?.displayID ?? 0 },
                    set: { id in Task { await session.switchDisplay(to: id) } }
                )) {
                    ForEach(displays, id: \.id) { display in
                        Button {} label: {
                            Text(display.name)
                            Text(display.menuDetail)
                        }
                        .tag(display.id)
                    }
                } label: {
                    Label("切换显示器", systemImage: "display.2")
                }
                .pickerStyle(.menu)
            }
            if canPickWindow {
                Button { pickingWindow = true } label: {
                    Label("窗口模式…", systemImage: "macwindow")
                }
            }
            if windowMode, session?.canControl == true {
                // 开着是触摸屏模式（点哪里就是哪里），关着是触控板模式。
                Toggle(isOn: $windowTouchMode) {
                    Label("触摸屏模式", systemImage: "hand.tap")
                }
            }
        }
        Section {
            if canCurtain, let session {
                let curtained = session.screen.curtained
                Button { session.setCurtain(!curtained) } label: {
                    Label(curtained ? "关闭帘幕" : "开启帘幕", systemImage: curtained ? "eye" : "eye.slash")
                }
            }
            if canManagePassword {
                if vaultHasPassword {
                    MMenu {
                        Button { editUnlockPassword() } label: {
                            Label("修改解锁密码…", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            if let macID = client.macDeviceID { vault.remove(forMac: macID) }
                            refreshVault()
                        } label: {
                            Label("删除已保存的密码", systemImage: "trash")
                        }
                    } label: {
                        Label("解锁密码", systemImage: "key")
                    }
                } else {
                    Button { editUnlockPassword() } label: {
                        Label("设置解锁密码…", systemImage: "key")
                    }
                }
            }
        }
    }

    private func editUnlockPassword() {
        passwordDraft = ""
        passwordSheetSavesOnly = true
        enteringPassword = true
    }

    // MARK: - 声音

    private var audioOn: Bool { session?.isAudioOn == true }

    private var statusLine: String {
        guard let session else { return String(localized: "正在连接…") }
        return session.statusText(controlling: touchMode ? String(localized: "触摸屏模式") : String(localized: "触控板模式")) ?? ""
    }

    private func barButton(_ symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { barIcon(symbol, active: active) }
            .buttonStyle(MPressStyle())
    }

    private func barIcon(_ symbol: String, active: Bool = false) -> some View {
        // 开着的（键盘、声音）：强调色实底配白图标，一眼看得出是开着。原先是灰底上放强调色图标，
        // 蓝字压在灰上对比度不够，和没开的也分不大出来。
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 32)
            .background(active ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.14)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 粘贴到 Mac

    private func pasteClipboard() async {
        let files = session?.canPasteFiles == true
        await paste { try await RemoteDesktopPasteSource.clipboardItem(allowsFiles: files) }
    }

    private func pastePhoto(_ item: PhotosPickerItem) async {
        await paste { try await RemoteDesktopPasteSource.picked(item) }
    }

    /// 读出内容、发给 Mac，等全部交给链路后报结果。读取、压缩、打包都不在主线程上做，进度画在顶上的提示里。
    /// 视频是先拷到临时目录再边读边传的，发完（或没发成）把那份删掉。
    private func paste(_ load: @MainActor () async throws -> RemoteDesktopPasteItem) async {
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
                defer { RemoteDesktopPasteSource.discard(content) }
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
                    MBtn(title: vaultHasPassword ? String(localized: "解锁 Mac") : String(localized: "输入密码解锁"), kind: .primary, height: 42) {
                        beginUnlock(session)
                    }.fixedSize()
                    if vaultHasPassword {
                        MBtn(title: String(localized: "改用其他密码"), kind: .secondary, height: 42) {
                            passwordDraft = ""
                            passwordSheetSavesOnly = false
                            enteringPassword = true
                        }.fixedSize()
                    }
                    // 关掉这层，直接在锁屏画面上用键盘输密码（这样解开的不会进帘幕）。
                    MBtn(title: String(localized: "在锁屏上输入"), kind: .secondary, height: 42) { lockOverlayDismissed = true }.fixedSize()
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
            ? String(localized: "用\(Self.biometryLead)取出已保存的密码解锁。解锁后 Mac 屏幕会变黑，Mac 本机的键盘和鼠标暂停使用。",
                     comment: "%@ 是面容 ID / 触控 ID 等名称（中文界面下末尾自带空格，其他语言不带，译文自己留空格）")
            : String(localized: "输入这台 Mac 的登录密码。解锁后 Mac 屏幕会变黑，Mac 本机的键盘和鼠标暂停使用。密码只保存在这台手机上。")
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
                    Text("密码只保存在这台手机的钥匙串里，不会同步到 iCloud，取用时需要\(Self.biometryLead)验证。",
                         comment: "%@ 是面容 ID / 触控 ID 等名称（中文界面下末尾自带空格，其他语言不带，译文自己留空格）")
                }
                .listRowBackground(M.card)
            }
            // 盖在 Mac 的画面上：用不透明的底色，不让下面的画面透上来（同 `RemoteDesktopWindowPicker`）。
            .scrollContentBackground(.hidden)
            .background(M.canvas)
            .navigationTitle(passwordSheetAuthPrompt != nil ? "替 \(client.macName) 填写密码"
                             : passwordSheetSavesOnly ? "\(client.macName) 的解锁密码" : "解锁 \(client.macName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { enteringPassword = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(passwordSheetAuthPrompt != nil ? "填入" : passwordSheetSavesOnly ? "保存" : "解锁") {
                        let password = passwordDraft
                        let authPrompt = passwordSheetAuthPrompt
                        passwordDraft = ""
                        enteringPassword = false
                        if let macID = client.macDeviceID {
                            do {
                                try vault.save(password, forMac: macID)
                                if passwordSheetSavesOnly { showPasteNote(String(localized: "已保存解锁密码")) }
                            } catch {
                                showPasteNote(String(localized: "无法把密码保存到钥匙串：\(RemoteUnlockVaultError.describe(error))"))
                            }
                        }
                        refreshVault()
                        if let authPrompt {
                            Task { await submitAuthPrompt(session, prompt: authPrompt, action: .fill, password: password) }
                        } else if !passwordSheetSavesOnly {
                            // 只保存时不发解锁：Mac 可能根本没锁，用户只是先把密码存好。
                            Task { await submitUnlock(session, password: password) }
                        }
                    }.disabled(passwordDraft.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(M.canvas)
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
                guard let password = try await vault.password(forMac: macID, reason: String(localized: "解锁 \(client.macName)")) else {
                    unlockPhase = .idle
                    passwordSheetSavesOnly = false
                    enteringPassword = true
                    return
                }
                await submitUnlock(session, password: password)
            } catch {
                unlockPhase = .failed(String(localized: "\(Self.biometryLead)验证未通过。", comment: "%@ 是面容 ID / 触控 ID 等名称（中文界面下末尾自带空格，其他语言不带，译文自己留空格）"))
            }
        }
    }

    private func submitUnlock(_ session: RemoteDesktopSession, password: String) async {
        unlockPhase = .working
        let outcome = await session.unlock(password: password)
        unlockPhase = outcome.failureMessage.map { .failed($0) } ?? .idle
    }

    // MARK: - Mac 屏上的验证框

    /// Mac 屏上有要 Touch ID / 密码的系统框：底部一张卡片，用已存的解锁密码（面容 ID / 触控 ID 取出）或现输的密码替它填，
    /// 或取消那个请求。不盖住画面：框本身还要看得见。什么时候显示见 `authPromptBanner`。
    @ViewBuilder private func authPromptOverlay(_ session: RemoteDesktopSession) -> some View {
        switch session.authPromptBanner(macName: client.macName) {
        case .none:
            EmptyView()
        case .caption(let text):
            bottomCaption(text)
        case .actionable(let prompt, let title, let message):
            let working = authPromptPhase == .working
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    Text(title)
                        .font(M.sans(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(authPromptMessage(default: message))
                        .font(M.sans(12.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                    if working {
                        ProgressView().tint(.white)
                    } else {
                        HStack(spacing: 8) {
                            MBtn(title: vaultHasPassword
                                    ? String(localized: "用\(Self.biometryLead)填入密码", comment: "%@ 是面容 ID / 触控 ID 等名称（中文界面下末尾自带空格，其他语言不带，译文自己留空格）")
                                    : String(localized: "输入密码"), kind: .primary,
                                 height: 40) {
                                beginAuthPromptFill(session, prompt: prompt)
                            }.fixedSize()
                            MBtn(title: String(localized: "取消请求"), kind: .secondary, height: 40) {
                                Task { await submitAuthPrompt(session, prompt: prompt, action: .cancel, password: nil) }
                            }.fixedSize()
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 420)
                .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.8)))
                .padding(.bottom, 24).padding(.horizontal, 16)
            }
        }
    }

    private func authPromptMessage(default message: String) -> String {
        if case .failed(let reason) = authPromptPhase { return reason }
        return message
    }

    /// 有存过的解锁密码就用面容 ID / 触控 ID 取出来填；没有（或取不出）就弹密码框现输，现输的顺手存下来。
    private func beginAuthPromptFill(_ session: RemoteDesktopSession, prompt: RemoteDesktopAuthPrompt) {
        func askForPassword() {
            passwordDraft = ""
            passwordSheetSavesOnly = false
            passwordSheetAuthPrompt = prompt
            enteringPassword = true
        }
        guard let macID = client.macDeviceID, vault.hasPassword(forMac: macID) else { return askForPassword() }
        authPromptPhase = .working
        Task {
            do {
                guard let password = try await vault.password(forMac: macID, reason: String(localized: "替 \(client.macName) 填写密码")) else {
                    authPromptPhase = .idle
                    return askForPassword()
                }
                await submitAuthPrompt(session, prompt: prompt, action: .fill, password: password)
            } catch {
                authPromptPhase = .failed(String(localized: "\(Self.biometryLead)验证未通过。", comment: "%@ 是面容 ID / 触控 ID 等名称（中文界面下末尾自带空格，其他语言不带，译文自己留空格）"))
            }
        }
    }

    private func submitAuthPrompt(_ session: RemoteDesktopSession, prompt: RemoteDesktopAuthPrompt,
                                  action: RemoteDesktopAuthPromptRequest.Action, password: String?) async {
        authPromptPhase = .working
        let outcome = await session.answerAuthPrompt(prompt, action: action, password: password)
        authPromptPhase = outcome.failureMessage.map { .failed($0) } ?? .idle
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
