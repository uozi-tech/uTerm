import Foundation
import GhosttyKit
import GhosttyTerminal
import UIKit

// 命名：GhosttyTerminal 也导出了 `TerminalKey` / `TerminalColorScheme` / `TerminalController` / `TerminalTheme`，
// 本模块里同名的 uTerm 类型优先，所以 GhosttyKit 的一律写全 `GhosttyTerminal.`。

/// 一条终端：GhosttyKit 的视图（画面）+ host-managed 会话 + 影子终端（读状态）+ uTerm 的输入通道。
/// `MobileTerminalController` 每个会话持有一个，视图跨外壳切换复用。
///
/// 字节流方向：
/// - 远端 → 终端：`bind(_:)` / `feed(_:)` 经 `router` 分流：先进影子终端（同步解析），画面吃得了的时候再 `session.receive`。
///   GhosttyKit 在自己的串行队列上解析，按 vsync 画，主线程不参与解析。
///   画面吃不了的三种情况——App 在后台（GhosttyKit 不 tick，标题这类消息会把解析卡死）、surface 还没建（标签没露出过）、
///   surface 被放掉了（标签隐藏久了）——只喂影子；画面回来时把影子的快照回放进 surface，再接实时字节。
/// - 终端 → 远端：键盘 / 粘贴 / 查询应答从 `InMemoryTerminalSession` 的 write 回调出来（可能在任意线程），
///   跳回主线程进 `TerminalInputChannel`；网格尺寸走 resize 回调进同一个通道（同轮合并、相同不重发）。
///   应答只有一个来源：画面在吃字节时由 surface 答，其余时候由影子答（`GhosttyOutputRouter` 切换）。
@MainActor
final class GhosttyTerminalBridge {
    let view: MGhosttyTerminalView
    let session: InMemoryTerminalSession
    /// 影子终端：和 surface 吃同一份字节，surface 不在时只有它在吃。读状态、拍快照都找它。
    let shadow: ShadowTerminal
    /// 输出分流（影子永远收、surface 只在能吃时收）与入站的闸门。
    let router: GhosttyOutputRouter
    /// 击键、粘贴、应答与网格尺寸共用的一条 FIFO。
    let input = TerminalInputChannel()
    /// 影子终端在解析中碰到的事：程序状态（OSC 7501 / 133）、标题、通知……都从这里出来，主线程上、按字节流的先后到。
    /// 读状态只认影子：它永远在吃字节，surface 不在（后台、标签没露出、surface 放掉了）时也不漏。
    var onEvent: ((ShadowTerminal.Event) -> Void)?
    /// 最近一次 resize 回调报来的网格（探针读它）。
    private(set) var grid: (cols: Int, rows: Int)?
    /// 最近一次 resize 回调报来的格子像素尺寸（探针读它，核字体）。
    private(set) var cellPixels: (width: UInt32, height: UInt32)?
    /// resize 回调次数（探针读它，看转屏时远端会收到几次 SIGWINCH）。
    private(set) var resizeReports = 0
    /// 每一块 write 回调给出的字节（探针读它，核按键编码）。nil = 不记。
    var inputLog: [Data]?
    private var ingress: Task<Void, Never>?
    /// App 在不在后台（`didEnterBackground` → `willEnterForeground`，和 `MobileTerminalController` 同一对通知）。
    private(set) var isAppInBackground = false
    /// surface 建好了、它的终端也报过尺寸了：可以往里灌字节。
    private(set) var isSurfaceReady = false
    /// surface 刚建好，在等它的终端到位（见 `surfaceAttached`）：视图算出来的网格、终端自己报来的网格，以及兜底的计时。
    private var expectedGrid: (cols: Int, rows: Int)?
    private var reportedGridSinceAttach: (cols: Int, rows: Int)?
    private var surfaceSizeTimeout: Task<Void, Never>?
    /// 这片终端在不在屏上（所在格的前台标签、终端模式）。
    private(set) var isOnScreen = true
    /// 不在屏上这么久之后放掉 surface（交换链、网格、回滚都还），再露出来时重建并从影子回放。
    /// 每个 surface 的帧缓冲约 14.5 MB，`setSurfaceVisible(false)` 不还（M2）。
    var hiddenReleaseDelay: Duration = GhosttyTerminalBridge.defaultHiddenReleaseDelay
    nonisolated static let defaultHiddenReleaseDelay: Duration = .seconds(60)
    private var releaseTask: Task<Void, Never>?
    private let delegateProxy: SurfaceDelegate
    // nonisolated(unsafe)：只在主线程设，deinit 里读。
    private nonisolated(unsafe) var lifecycleObservers: [NSObjectProtocol] = []

    /// 回滚上限，surface 与影子用同一份（两端共用的 `TerminalScrollbackLimits` 按行数算出两边的值；不一样的话回放进
    /// surface 的历史长度和它自己攒的不同，M4 的前提）。iOS 固定 1 万行。
    /// 另一个作用是给回放封顶：1 万行回滚拍快照 + 出回放流 + 自查，Duo 上热着跑约 3 ms，回前台那一下（冷）约 15 ms。
    nonisolated static let scrollback = TerminalScrollbackLimits(lines: 10_000)
    nonisolated static var scrollbackLines: Int { scrollback.lines }
    nonisolated static var scrollbackBytes: Int { scrollback.bytes }

    /// 见 `MGhosttyTerminalView.ghosttyFontSize(points:)`。
    nonisolated static func ghosttyFontSize(points: CGFloat) -> Float {
        MGhosttyTerminalView.ghosttyFontSize(points: points)
    }

    // MARK: 配置

    /// 整个 App 共用一个 ghostty app：一个 app 一份字体 / 图集缓存，深 / 浅两套配色都在里面，随视图的日夜自己切。
    static let sharedController = makeController(fontSize: ghosttyFontSize(points: MGhosttyTerminalView.defaultFontSize),
                                                 cursor: appliedCursor)

    /// 上次装进共享 controller 的光标样式。
    private static var appliedCursor = TerminalCursorPreference.read()

    /// 设置里改了光标形状 / 闪烁（或从 Mac 同步过来）。对已经开着的终端也生效；程序自己设的光标（vim 插入模式的竖线）
    /// 会被盖掉，同换引擎之前的取舍——所以只在和上次装的不同才装，不能每次视图更新都装。
    /// 叠在基础配置上面的一层，只有光标两项（同一个键后写的生效）。
    static func applyCursorIfNeeded(_ look: TerminalCursorLook) {
        guard look != appliedCursor else { return }
        appliedCursor = look
        sharedController.setTerminalConfiguration(GhosttyTerminal.TerminalConfiguration { builder in
            builder.withCursorStyle(cursorStyle(look.shape))
            builder.withCursorStyleBlink(look.blink)
        })
    }

    /// 配置在这里定：字体、字号、光标、留白、最低对比度、着色规则、回滚上限；配色作为 `theme` 传（深 / 浅两份都来自
    /// uTerm 的 `TerminalColorScheme`），GhosttyKit 按视图的日夜自己切。
    ///
    /// 配色必须走 `theme`：controller 先装基础配置、再把 theme 叠上去；不传 theme 时用的是 GhosttyKit 自带的
    /// Alabaster / Afterglow，会把 background / foreground / palette / cursor-color 全部盖掉（实机：浅色底成了 #F7F7F7、
    /// 深色 #212121、光标蓝块，和外面 uTerm 的终端底色对不上，左右露出两条）。
    static func makeController(
        fontSize: Float,
        cursor: TerminalCursorLook = TerminalCursorLook(shape: TerminalCursorPreference.defaultShape,
                                                        blink: TerminalCursorPreference.defaultBlink)
    ) -> GhosttyTerminal.TerminalController {
        let theme = GhosttyTerminal.TerminalTheme(light: GhosttyPalette.colors(TerminalColorScheme.resolve(dark: false)),
                                                  dark: GhosttyPalette.colors(TerminalColorScheme.resolve(dark: true)))
        return GhosttyTerminal.TerminalController(theme: theme) { builder in
            // 系统等宽字体在 iOS 上只认这个私有 family 名（`.AppleSystemUIFontMonospaced`；"SF Mono" 等名字都会静默退回
            // 内置的 JetBrains Mono，M12）。font-family 可以重复写，按顺序作为回退链：取不到再用 Menlo。
            builder.withFontFamily(UIFont.monospacedSystemFont(ofSize: 11, weight: .regular).familyName)
            builder.withFontFamily("Menlo")
            builder.withFontSize(fontSize)
            builder.withCursorStyle(cursorStyle(cursor.shape))
            builder.withCursorStyleBlink(cursor.blink)
            builder.withBackgroundOpacity(1)
            // 不要内留白：网格从左上角排起，余下的不到一格留在右 / 下边，由外层 8pt 边距同色铺底。
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
            builder.withCustom("window-padding-color", "extend")
            // 最低对比度（WCAG 比值）。上游 Ghostty 判不过就直接换成黑 / 白；我们编的 GhosttyKit（补丁 0022）
            // 保色相、只调明度。
            builder.withMinimumContrast(Double(TerminalColorScheme.minimumContrastRatio))
            // 着色规则（M16 第二轮逐格对比定下来的）：
            // - 256 色的 16–255 由 16 色 + 底色 / 前景按 CIELAB 生成；不开的话 Ghostty 用固定的 xterm 表，
            //   p10k 的 38;5;103 等颜色对不上，浅色下灰阶还是反的。
            builder.withCustom("palette-generate", "true")
            // - 粗体的 0–7 号色用亮色。
            builder.withCustom("bold-color", "bright")
            // - dim 按 sRGB（伽马空间）和底色五五开混合；iOS 默认的 linear-corrected 在线性空间混合，dim 字会亮一截。
            builder.withCustom("alpha-blending", "native")
            builder.withCustom("faint-opacity", "0.5")
            // 回滚上限：与影子终端同一份（见 `scrollback`）。不设的话是 Ghostty 的默认 50 MB、不限行数。
            for item in scrollback.ghosttyConfiguration { builder.withCustom(item.key, item.value) }
        }
    }

    private static func cursorStyle(_ shape: TerminalCursorShape) -> GhosttyTerminal.TerminalCursorStyle {
        switch shape {
        case .block: .block
        case .bar: .bar
        case .underline: .underline
        }
    }

    /// 影子终端的配置：和 `makeController` 给 surface 的配置对得上的那几项。
    private static func shadowOptions() -> ShadowTerminal.Options {
        var options = scrollback.shadowOptions
        options.cursorBlink = TerminalCursorPreference.read().blink
        // 影子替 surface 答 XTVERSION 时要答得一样；surface 答的是「ghostty <版本>」。
        let info = ghostty_info()
        if let version = info.version, info.version_len > 0 {
            let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(version).assumingMemoryBound(to: UInt8.self),
                                            count: Int(info.version_len))
            options.versionReport = "ghostty " + String(decoding: bytes, as: UTF8.self)
        }
        return options
    }

    // MARK: 建立

    init(controller: GhosttyTerminal.TerminalController = GhosttyTerminalBridge.sharedController, frame: CGRect = .zero) {
        let box = WeakBridgeBox()
        // 先按 80×24 建，surface 的终端报出真实网格后跟着改（见下面的 resize 回调）。
        let shadow = ShadowTerminal(cols: 80, rows: 24, options: Self.shadowOptions())
        let session = InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in box.bridge?.userInput(data) }
            },
            resize: { viewport in
                // 影子跟着 surface 的终端自己报的尺寸走，而且就在这个回调里改、不绕主线程（M4 的前提：按视图尺寸算或者
                // 晚一拍改，两边会在不同的字节位置换宽度，折行就对不上了）。
                shadow.resize(cols: viewport.columns, rows: viewport.rows,
                              cellWidth: viewport.cellWidthPixels, cellHeight: viewport.cellHeightPixels)
                Task { @MainActor in
                    box.bridge?.cellPixels = (viewport.cellWidthPixels, viewport.cellHeightPixels)
                    box.bridge?.gridChanged(cols: Int(viewport.columns), rows: Int(viewport.rows))
                }
            },
            // uTerm 只消费行列数；像素级的尺寸变化（拖分隔条时绝大多数）不必让远端重绘。
            suppressesPixelOnlyResizes: true)
        self.session = session
        self.shadow = shadow
        router = GhosttyOutputRouter(session: session, shadow: shadow)
        delegateProxy = SurfaceDelegate()
        view = MGhosttyTerminalView(frame: frame)
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: Self.ghosttyFontSize(points: MGhosttyTerminalView.defaultFontSize))
        box.bridge = self
        view.delegate = delegateProxy
        view.uTermOnSurfaceAttached = { [weak self] in self?.surfaceAttached() }
        view.uTermOnSurfaceDetached = { [weak self] in self?.surfaceDetached() }
        view.uTermSetGridExpectedHandler { [weak self] cols, rows in self?.surfaceGridExpected(cols: cols, rows: rows) }
        // surface 不吃字节时查询由影子答（DA、DSR、光标位置、颜色查询……），和 surface 的应答走同一条路回后端。
        shadow.setReplyHandler { data in
            Task { @MainActor in box.bridge?.userInput(data) }
        }
        shadow.setEventHandler { event in
            // 在 `feed` 里同步回调。主线程上喂的（测试、探针）当场交出去；入站任务喂的跳回主线程，先后不变。
            if Thread.isMainThread {
                MainActor.assumeIsolated { box.bridge?.onEvent?(event) }
            } else {
                Task { @MainActor in box.bridge?.onEvent?(event) }
            }
        }
        // 还没有 surface：先只喂影子（它也负责应答），surface 建好、报过尺寸后回放接上。
        router.setSurfaceFeeding(false)
        installLifecycleObservers()
        if UIApplication.shared.applicationState == .background { setAppInBackground(true) }
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        releaseTask?.cancel()
        surfaceSizeTimeout?.cancel()
        ingress?.cancel()
    }

    // MARK: 输出

    /// 喂远端输出。线程安全；影子当场解析，surface 的解析在 GhosttyKit 的串行队列上。不过闸门（测试与探针直接喂用）。
    nonisolated func feed(_ data: Data) {
        router.route(data)
    }

    /// 接到一个后端：输出经分流进影子与 surface，输入 / 尺寸走共享通道（尺寸可能早于传输就绪，接上时先补发）。
    ///
    /// 背压：surface 没解析完的字节到 `GhosttyOutputRouter.highWater`（1 MiB）时入站任务不再取下一块，落回低水位再取。
    /// 取不动的字节留在后端的 `outputStream` 里——那条流（以及 Citadel 的 PTY 输出流）现在是不限长的，所以这还不是
    /// 真正压到 SSH 窗口上的背压，只保证终端这一层有上界；要压到远端得改 Citadel（见 measure-ios.md 的 M10）。
    func bind(_ backend: any TerminalBackend) {
        input.bind(to: backend, sendingLatestSize: true)
        ingress?.cancel()
        router.reopen()
        let router = router
        let output = backend.outputStream
        ingress = Task.detached(priority: .userInitiated) {
            for await chunk in output {
                if Task.isCancelled { break }
                await router.ingest(chunk)
            }
        }
    }

    func unbind() {
        ingress?.cancel()
        ingress = nil
        router.close()
        input.unbind()
    }

    // MARK: 画面吃不吃字节

    /// 画面能吃字节的条件：App 在前台，且 surface 建好并报过尺寸。任何一条不成立就只喂影子；重新成立时
    /// `GhosttyOutputRouter` 把影子的快照回放进 surface 再接实时字节。重复调用无害。
    private func syncSurfaceFeeding() {
        let feeds = !isAppInBackground && isSurfaceReady
        router.setSurfaceFeeding(feeds)
    }

    /// 用 didEnterBackground / willEnterForeground，不用 resign / becomeActive：拉下控制中心、来电横幅时 App 只是
    /// inactive，GhosttyKit 照常 tick，不用切。只看 App 级的通知；iPad 多窗口里单个场景退后台没接（那时 GhosttyKit
    /// 也只停那个场景的视图，别的场景还在 tick，mailbox 有人清）。
    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppInBackground(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppInBackground(false) }
            },
        ]
    }

    /// App 进出后台。进后台：从这一刻起输出只喂影子终端，surface 不再吃字节（GhosttyKit 后台不 tick，带标题的输出
    /// 约 64 帧就把 app mailbox 填满、解析卡死）；影子开始替 surface 应答查询。回前台：把影子的快照回放进 surface
    ///（后台队列上做），再接实时字节。重复调用无害。通知驱动；`MobileTerminalController` 也会转过来，测试直接调。
    func setAppInBackground(_ inBackground: Bool) {
        guard inBackground != isAppInBackground else { return }
        isAppInBackground = inBackground
        if inBackground { syncShadowColors() }
        syncSurfaceFeeding()
    }

    /// 影子替 surface 答颜色查询要用当前配色（OSC 10 / 11、`CSI ? 996 n`）。
    private func syncShadowColors() {
        let dark = view.traitCollection.userInterfaceStyle != .light
        let scheme = TerminalColorScheme.resolve(dark: dark)
        shadow.setDefaultColors(foreground: GhosttyPalette.rgb(scheme.foregroundColor),
                                background: GhosttyPalette.rgb(scheme.backgroundColor),
                                cursor: GhosttyPalette.rgb(scheme.cursorColor), dark: dark)
    }

    // MARK: surface 的生与灭

    /// surface 建好了。它的终端此刻还是出生时的默认网格，真实尺寸要等 IO 线程处理完第一条 resize 才生效；
    /// 在那之前灌进去的回放会按错的网格解析（备用屏的内容尤其会错位，而且网格和以前一样时程序收不到 SIGWINCH、不会重画）。
    /// 所以等它的终端报来的网格和视图算出来的对上了再开闸：视图那边主线程上当场就知道该是多少（`surfaceGridExpected`），
    /// 终端那边由 resize 回调报来（会话对新 surface 的第一次回调不去重，见本地包的 `InMemoryTerminalSession.setSurface`）。
    /// 兜底等 0.25 s。
    private func surfaceAttached() {
        isSurfaceReady = false
        expectedGrid = nil
        reportedGridSinceAttach = nil
        surfaceSizeTimeout?.cancel()
        surfaceSizeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.surfaceBecameReady()
        }
    }

    private func surfaceDetached() {
        surfaceSizeTimeout?.cancel()
        surfaceSizeTimeout = nil
        isSurfaceReady = false
        syncShadowColors()
        syncSurfaceFeeding()
    }

    /// 视图按自己的尺寸算出来的网格（surface 刚建好、以及之后每次尺寸变化，主线程上同步报来）。
    private func surfaceGridExpected(cols: Int, rows: Int) {
        expectedGrid = (cols, rows)
        openGateIfGridSettled()
    }

    private func openGateIfGridSettled() {
        guard !isSurfaceReady, view.surface != nil,
              let expectedGrid, let reported = reportedGridSinceAttach,
              expectedGrid == reported else { return }
        surfaceBecameReady()
    }

    private func surfaceBecameReady() {
        surfaceSizeTimeout?.cancel()
        surfaceSizeTimeout = nil
        guard !isSurfaceReady, view.surface != nil else { return }
        isSurfaceReady = true
        syncSurfaceFeeding()
    }

    // MARK: 在不在屏上

    /// 这片终端在不在屏上。不在屏上：停画；隔 `hiddenReleaseDelay` 还没回来就放掉 surface。回到屏上：重建（如果放掉了）、
    /// 从影子回放、接着画。从没露出过的标签第一次露出才建 surface（M7）。
    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else {
            // 外壳切换时新容器接走同一个视图：以它的状态为准再对一次。
            view.setSurfaceVisible(onScreen)
            return
        }
        isOnScreen = onScreen
        view.setSurfaceVisible(onScreen)
        releaseTask?.cancel()
        releaseTask = nil
        if onScreen {
            view.uTermRestoreSurface()
            return
        }
        guard view.surface != nil else {
            // 还没建过 surface：先不建，等露出来。
            releaseSurface()
            return
        }
        let delay = hiddenReleaseDelay
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.releaseSurface()
        }
    }

    /// 从没建过 surface 的终端（后台新开、还没露出过的标签）没有网格可报，远端的 PTY 会停在后端默认的 80×24，
    /// shell 和程序按那个尺寸排版，直到标签第一次露出。容器首次排布时按字体度量估一个网格先报上去（影子跟着改，
    /// 它要和远端以为的尺寸一致）；露出来建好 surface 后，终端自己报的网格会把它纠正过来（差的话多一次 SIGWINCH）。
    func estimateGridIfNeverSized(for size: CGSize) {
        guard grid == nil, view.surface == nil, size.width > 0, size.height > 0 else { return }
        let font = UIFont.monospacedSystemFont(ofSize: view.terminalFontSize, weight: .regular)
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let cellHeight = font.lineHeight
        guard cellWidth > 0, cellHeight > 0 else { return }
        let cols = UInt16(clamping: max(2, Int(size.width / cellWidth)))
        let rows = UInt16(clamping: max(1, Int(size.height / cellHeight)))
        shadow.resize(cols: cols, rows: rows)
        input.reportSize(cols: cols, rows: rows)
    }

    private func releaseSurface() {
        guard !isOnScreen else { return }
        view.uTermReleaseSurface()
        view.alignConfiguredFontSize()
    }

    // MARK: 输入

    /// 发给远端的原始字节（键盘条上的文字、提示词、回车）。和 surface 出来的击键、应答走同一条 FIFO。
    func write(_ data: Data) {
        input.write(data)
    }

    private func userInput(_ data: Data) {
        inputLog?.append(data)
        input.write(data)
    }

    private func gridChanged(cols: Int, rows: Int) {
        resizeReports += 1
        grid = (cols, rows)
        input.reportSize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
        if view.surface != nil, !isSurfaceReady {
            reportedGridSinceAttach = (cols, rows)
            openGateIfGridSettled()
        }
    }

    /// 像系统粘贴一样送一段文字：程序开了括号粘贴（DECSET 2004）就包上起止标记，程序据此认出是粘贴
    ///（例如 Claude Code 把粘进来的图片路径当附件）。模式读影子终端：它同步解析，永远是最新的，surface 在不在都一样；
    /// 整段作为一次写入发出（surface 自己的粘贴会把起止标记和正文拆成三次写）。
    func paste(_ text: String) {
        write(TerminalPaste.wrap(text, bracketed: shadow.bracketedPasteMode))
    }

    // MARK: 键盘条

    /// 键盘条上的一个键。能对上 GhosttyKit 按键的走按键路径（由终端按当前模式编码：DECCKM 下方向键发
    /// `ESC O A`、kitty 键盘协议下发 CSI u；上膛的 Ctrl / Alt 作用在这个键上），对不上的（符号、提示词）走文字路径。
    func send(_ key: uTermMobile.TerminalKey) {
        if let press = GhosttyKeyBarMapping.press(for: key), view.sendKey(press) { return }
        if key.send.count == 1, let char = key.send.first, let press = TerminalKeyPress(typing: char),
           view.sendKey(press) {
            // 单个符号按「打字」发：不会被括号粘贴包起来（Claude Code 会把粘贴的 "/" 当成粘贴内容）。
            return
        }
        // 没有 surface 可编码时退回目录里写的字节。
        write(Data(key.send.utf8))
    }

    // MARK: 粘滞 Ctrl / Alt

    /// GhosttyKit 原生的粘滞修饰：作用于下一个软键盘字符或按键，用完自动复位；连点两下锁定。
    func toggleSticky(_ modifier: TerminalPublicStickyModifier) {
        view.toggleStickyModifier(modifier)
    }

    func toggleControl() { toggleSticky(.ctrl) }
    func toggleAlt() { toggleSticky(.alt) }

    /// Ctrl / Alt 此刻是不是上膛着（含锁定）。
    var stickyModifiers: (control: Bool, alt: Bool) {
        (view.stickyActivation(for: .ctrl) != .inactive, view.stickyActivation(for: .alt) != .inactive)
    }

    func clearStickyModifiers() {
        view.resetStickyModifiers()
    }

    /// 粘滞修饰的状态变了（点了按钮、被一次按键用掉、被清掉）。
    var onStickyModifiersChanged: (() -> Void)? {
        didSet { view.setStickyModifierChangeHandler(onStickyModifiersChanged) }
    }
}

/// write / resize 回调是 `@Sendable` 的、可能在任意线程上来，只带一个弱引用回主线程（类本身是 MainActor 的，所以可跨线程传）。
private final class WeakBridgeBox {
    weak var bridge: GhosttyTerminalBridge?
}

/// 视图的委托：只管点链接。surface 的生灭与网格走视图上不经 delegate 的回调（`uTermOnSurfaceAttached` 等）：
/// 探针会把 delegate 换成自己的对象。
@MainActor
private final class SurfaceDelegate: TerminalSurfaceOpenURLDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        if let url = URL(string: url) { UIApplication.shared.open(url) }
    }
}
