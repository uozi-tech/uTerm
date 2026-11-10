import Foundation
import GhosttyKit
import GhosttyTerminal
import os
import UIKit

// 命名：GhosttyTerminal 也导出了 `TerminalKey` / `TerminalColorScheme` / `TerminalController` / `TerminalTheme`，
// 本模块里同名的 uTerm 类型优先，所以 GhosttyKit 的一律写全 `GhosttyTerminal.`。

/// 一条终端：GhosttyKit 的视图（画面）+ host-managed 会话 + 影子终端（读状态）+ uTerm 的输入通道。
/// `MobileTerminalController` 每个会话持有一个，视图跨外壳切换复用。
///
/// 字节流方向：
/// - 远端 → 终端：`bind(_:)` / `feed(_:)` 经两端共用的 `TerminalOutputPump` 分流：先进影子终端（同步解析），画面吃得了的时候再 `session.receive`。
///   GhosttyKit 在自己的串行队列上解析，按 vsync 画，主线程不参与解析。
///   画面吃不了的三种情况——App 在后台（GhosttyKit 不 tick，标题这类消息会把解析卡死）、surface 还没建（标签没露出过）、
///   surface 被放掉了（标签隐藏久了）——只喂影子；画面回来时把影子的快照回放进 surface，再接实时字节。
/// - 终端 → 远端：键盘 / 粘贴 / 查询应答从 `InMemoryTerminalSession` 的 write 回调出来（可能在任意线程），
///   跳回主线程进 `TerminalInputChannel`；网格尺寸走 resize 回调进同一个通道（同轮合并、相同不重发）。
///   应答只有一个来源：画面在吃字节时由 surface 答，其余时候由影子答（输出泵切换）。
@MainActor
final class GhosttyTerminalBridge {
    let view: MGhosttyTerminalView
    let session: InMemoryTerminalSession
    /// 影子终端：和 surface 吃同一份字节，surface 不在时只有它在吃。读状态、拍快照都找它。
    let shadow: ShadowTerminal
    /// 输出泵（两端共用）：影子永远收、surface 只在能吃时收，入站带闸门；远控发来的整屏快照也由它还原、回放。
    let outputPump: TerminalOutputPump
    /// 击键、粘贴、应答与网格尺寸共用的一条 FIFO。
    let input = TerminalInputChannel()
    /// 影子与 surface 之间的接线（两端共用，见 `TerminalSurfaceLink`）。上面的 `session` / `shadow` / `outputPump` 就是它的。
    let link: TerminalSurfaceLink
    /// 影子终端的事件：程序状态、查询应答、历史、远控镜像的规则两端共用（`TerminalEventRouter`），控制器接它的出口。
    /// 读状态只认影子：它永远在吃字节，surface 不在（后台、标签没露出、surface 放掉了）时也不漏。
    var events: TerminalEventRouter { link.events }
    /// 程序状态以外的影子事件（标题、通知、响铃、未知 OSC），主线程上、按字节流的先后到。
    var onEvent: ((ShadowTerminal.Event) -> Void)?
    /// 最近一次 resize 回调报来的网格（探针读它）。
    private(set) var grid: (cols: Int, rows: Int)?
    /// 最近一次 resize 回调报来的格子像素尺寸（探针读它，核字体）。
    private(set) var cellPixels: (width: UInt32, height: UInt32)?
    /// resize 回调次数（探针读它，看转屏时远端会收到几次 SIGWINCH）。
    private(set) var resizeReports = 0
    /// 每一块 write 回调给出的字节（探针读它，核按键编码）。nil = 不记。
    var inputLog: [Data]?
    /// 程序用 OSC 52 写剪贴板时写到哪（测试换成私有的，别动模拟器那块与 Mac 同步的系统剪贴板）。
    var pasteboard: UIPasteboard = .general
    /// App 在不在后台（`MobileTerminalController` 听 `didEnterBackground` / `willEnterForeground` 转过来，测试直接调）。
    private(set) var isAppInBackground = false
    /// surface 建好了、它的终端也报过尺寸了：可以往里灌字节（见 `TerminalSurfaceLink`）。
    var isSurfaceReady: Bool { link.isSurfaceReady }
    /// 这片终端在不在屏上（所在格的前台标签、终端模式）。
    private(set) var isOnScreen = true
    /// 不在屏上之后多久放掉 surface（交换链、网格、回滚都还），再露出来时重建并从影子回放（两端同一个值）。
    /// 每个 surface 的帧缓冲约 14.5 MB，`setSurfaceVisible(false)` 不还（M2）。测试里改短。
    private let retention = TerminalSurfaceRetention()
    var hiddenReleaseDelay: Duration {
        get { retention.delay }
        set { retention.delay = newValue }
    }
    /// 擦屏后清选区、整屏回放后找回视口（两端共用）。
    var keeper: TerminalSurfaceKeeper { link.keeper }
    private let delegateProxy: SurfaceDelegate

    /// 回滚上限，surface 与影子用同一份（两端共用的 `TerminalScrollbackLimits` 按行数算出两边的值；不一样的话回放进
    /// surface 的历史长度和它自己攒的不同，M4 的前提）。iOS 固定 1 万行。
    /// 另一个作用是给回放封顶：1 万行回滚拍快照 + 出回放流 + 自查，Duo 上热着跑约 3 ms，回前台那一下（冷）约 15 ms。
    nonisolated static let scrollback = TerminalScrollbackLimits(lines: 10_000)
    nonisolated static var scrollbackLines: Int { scrollback.lines }

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
            builder.withCursorStyle(TerminalGhosttyConfig.cursorStyle(look.shape))
            builder.withCursorStyleBlink(look.blink)
        })
    }

    /// 配置在这里定：iOS 自己的字体、字号、底色不透明、留白铺色，加上两端共用的那些项（光标、留白、着色规则、剪贴板、
    /// 回滚上限、按键绑定，见 `TerminalGhosttyConfig.applyCommon`）；配色作为 `theme` 传（两端共用的
    /// `TerminalGhosttyConfig.theme`，深 / 浅两份都来自 uTerm 的 `TerminalColorScheme`），GhosttyKit 按视图的日夜自己切。
    static func makeController(
        fontSize: Float,
        cursor: TerminalCursorLook = TerminalCursorLook(shape: TerminalCursorPreference.defaultShape,
                                                        blink: TerminalCursorPreference.defaultBlink),
        overrides: (inout GhosttyTerminal.TerminalConfiguration.Builder) -> Void = { _ in }
    ) -> GhosttyTerminal.TerminalController {
        GhosttyTerminal.TerminalController(theme: TerminalGhosttyConfig.theme()) { builder in
            // 字体回退链（font-family 可以重复写，按顺序找）：
            // 1. 系统等宽。iOS 上只认这个私有 family 名（`.AppleSystemUIFontMonospaced`；"SF Mono" 等名字都会静默退回
            //    内置的 JetBrains Mono，M12）。不写 font-style：Ghostty 自己选到的就是常规字重（用例核过不是 Light）。
            // 2. Menlo：系统等宽万一取不到，拉丁字符落到它，而不是后面苹方的比例字形。
            // 3. 苹方：中文要显式写。靠 Ghostty 自动回退找中文字体的话，同一份配置不同次运行选到的字重不稳定
            //   （有时细体、有时中等），而且落到苹方的 UI Text 变体，全角标点和引号贴左。
            // 不开 font-thicken：那是对齐 macOS 字体平滑加粗用的，iOS 的 CoreGraphics 没有这一层。
            for family in fontFamilies { builder.withFontFamily(family) }
            builder.withFontSize(fontSize)
            builder.withBackgroundOpacity(1)
            // 余下的不到一格留在右 / 下边，由外层 8pt 边距同色铺底。
            builder.withCustom("window-padding-color", "extend")
            // 硬件键盘、键盘条、`sendKey` 都经 `ghostty_surface_key`，都过共用的按键绑定表；其中 `macos-option-as-alt`
            // 在 iOS 上不起作用，引擎照收。
            TerminalGhosttyConfig.applyCommon(to: &builder, cursorShape: cursor.shape, cursorBlink: cursor.blink,
                                              scrollback: scrollback)
            // 生产不传；用例拿它在同一份配置上改一两项做对照（换字体、换字重）。
            overrides(&builder)
        }
    }

    /// 见 `makeController` 里的说明。
    static let fontFamilies = [UIFont.monospacedSystemFont(ofSize: 11, weight: .regular).familyName, "Menlo", "PingFang SC"]

    /// 影子终端的配置：和 `makeController` 给 surface 的配置对得上的那几项（两端共用的算法）。
    private static func shadowOptions() -> ShadowTerminal.Options {
        scrollback.shadowOptions(cursorBlink: TerminalCursorPreference.read().blink)
    }

    // MARK: 建立

    init(controller: GhosttyTerminal.TerminalController = GhosttyTerminalBridge.sharedController, frame: CGRect = .zero) {
        // 先按 80×24 建，surface 的终端报出真实网格后跟着改（IO 线程的 resize 回调里当场改，见 `TerminalSurfaceLink`）。
        let link = TerminalSurfaceLink(cols: 80, rows: 24, options: Self.shadowOptions())
        self.link = link
        session = link.io
        shadow = link.shadow
        outputPump = link.pump
        delegateProxy = SurfaceDelegate()
        view = MGhosttyTerminalView(frame: frame)
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(link.io),
            fontSize: Self.ghosttyFontSize(points: MGhosttyTerminalView.defaultFontSize))
        view.delegate = delegateProxy
        link.attach(view)
        // surface 写出的（击键、它答的查询）和影子替它答的走同一条路回后端。
        link.onSurfaceInput = { [weak self] in self?.userInput($0) }
        link.onShadowReply = { [weak self] in self?.userInput($0) }
        // 程序写剪贴板（OSC 52）：以影子为准。影子从快照还原时不解析字节、喂历史时不调，都不会再写。
        link.onClipboardWrite = { [weak self] in self?.pasteboard.string = $0 }
        link.onGridReported = { [weak self] viewport in
            self?.cellPixels = (viewport.cellWidthPixels, viewport.cellHeightPixels)
            self?.gridChanged(cols: Int(viewport.columns), rows: Int(viewport.rows))
        }
        link.platformAllowsFeeding = { [weak self] in !(self?.isAppInBackground ?? true) }
        // surface 没了：查询改由影子答，配色要是当前的。
        link.onSurfaceDetached = { [weak self] in self?.syncShadowColors() }
        // 硬件键盘上没有绑定接的 ⌘ 组合：程序开了 kitty 键盘协议才发（见 `MGhosttyTerminalView.dropsCommandChord`）。
        view.sendsCommandChords = { [weak self] in (self?.shadow.kittyKeyboardFlags ?? 0) != 0 }
        // 在 `feed` 里同步回调。主线程上喂的（测试、探针）当场交出去；入站任务喂的跳回主线程，先后不变。
        link.events.onEvent = { [weak self] in self?.onEvent?($0) }
        // 泵刚建好时只喂影子（它也负责应答）；surface 建好、网格到位后开闸，回放接上。
        if UIApplication.shared.applicationState == .background { setAppInBackground(true) }
    }

    deinit {
        outputPump.reset()
    }

    // MARK: 输出

    /// 喂远端输出。线程安全；影子当场解析，surface 的解析在 GhosttyKit 的串行队列上。不过闸门（测试与探针直接喂用）。
    nonisolated func feed(_ data: Data) {
        outputPump.route(data)
    }

    /// 接到一个后端：输出进泵（字节，或远控发来的整屏快照），输入 / 尺寸走共享通道（尺寸可能早于传输就绪，接上时先补发）。
    ///
    /// 背压：surface 没解析完的字节到 1 MiB 时入站任务不再取下一块，落回低水位再取（`TerminalOutputPump`）。
    /// 取不动的字节留在后端的输出流里——那条流（以及 Citadel 的 PTY 输出流）现在是不限长的，所以这还不是
    /// 真正压到 SSH 窗口上的背压，只保证终端这一层有上界；要压到远端得改 Citadel（见 measure-ios.md 的 M10）。
    ///
    /// 远控标签（`backend.mirrorsRemoteGrid`）：影子的网格由 Mac 发来的快照定，画面等网格对齐再跟（同 Mac 的远控窗口，
    /// 见迁移日志「收尾二」第 3 项）。尺寸先于输出：接入请求就带上本地网格，Mac 钉好这个尺寸再拍第一张快照。
    func bind(_ backend: any TerminalBackend) {
        input.bind(to: backend, sendingLatestSize: true)
        outputPump.reset()
        // 重连先复位光标形状、远控标签的网格跟着 Mac 走（两端共用，见 `TerminalSurfaceLink.prepare`）。
        link.prepare(for: backend)
        outputPump.start(backend.outputItems)
    }

    func unbind() {
        outputPump.reset()
        input.unbind()
    }

    // MARK: 画面吃不吃字节

    /// App 进出后台。进后台：从这一刻起输出只喂影子终端，surface 不再吃字节（GhosttyKit 后台不 tick，带标题的输出
    /// 约 64 帧就把 app mailbox 填满、解析卡死）；影子开始替 surface 应答查询。回前台：把影子的快照回放进 surface
    ///（后台队列上做），再接实时字节。重复调用无害。`MobileTerminalController` 听通知转过来，测试直接调。
    func setAppInBackground(_ inBackground: Bool) {
        guard inBackground != isAppInBackground else { return }
        isAppInBackground = inBackground
        if inBackground {
            syncShadowColors()
            // 停喂之前记下视口：回前台时要是只能整屏回放，按它找回原处（能补尾巴的话视口本来就在）。
            link.rememberViewport()
        }
        link.syncSurfaceFeeding()
        if !inBackground { link.forgetViewportUnlessCatchingUp() }
    }

    /// 影子替 surface 答颜色查询要用当前配色（OSC 10 / 11、`CSI ? 996 n`）。
    private func syncShadowColors() {
        link.syncShadowColors(dark: view.traitCollection.userInterfaceStyle != .light)
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
        retention.cancel()
        if onScreen {
            view.uTermRestoreSurface()
            return
        }
        guard view.surface != nil else {
            // 还没建过 surface：先不建，等露出来。
            releaseSurface()
            return
        }
        retention.scheduleRelease { [weak self] in self?.releaseSurface() }
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
        if !link.followsRemoteGrid.withLock({ $0 }) { shadow.resize(cols: cols, rows: rows) }
        input.reportSize(cols: cols, rows: rows)
    }

    private func releaseSurface() {
        guard !isOnScreen else { return }
        // 放掉之前记下视口：重建后整屏回放（视口回到底部），按它找回原处。
        link.rememberViewport()
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
        // 远控标签停着画面等网格对齐的话，surface 这一报可能就对上了（读的是 IO 线程报过的网格）；surface 刚建好的话看闸能不能开。
        link.gridReported(cols: cols, rows: rows)
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

/// 视图的委托：只管点链接。surface 的生灭与网格走视图上不经 delegate 的回调（`uTermOnSurfaceAttached` 等）：
/// 探针会把 delegate 换成自己的对象。
@MainActor
private final class SurfaceDelegate: TerminalSurfaceOpenURLDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        if let url = URL(string: url) { UIApplication.shared.open(url) }
    }
}
