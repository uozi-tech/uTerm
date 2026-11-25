import AppKit
import Carbon.HIToolbox
import GhosttyTerminal
import os

/// 一条 `TerminalSession` 的画面：GhosttyKit 的视图 + 平台那一侧的事（按键、右键菜单、尺寸怎么发给 PTY、远控钉尺寸、
/// 在不在屏上）。影子与 surface 之间的接线两端共用（`TerminalSurfaceLink`）。
///
/// 字节流方向：
/// - 远端 → 终端：两端共用的 `TerminalOutputPump` 分流：先进影子终端（同步解析），画面吃得了的时候再交给 surface
///   （异步解析、渲染线程出帧）。画面吃不了的三种情况——surface 还没建（标签没露出过）、视图离开了窗口（切走的标签）、
///   surface 被放掉了（标签藏了 `hiddenReleaseDelay`）——只喂影子；画面回来时先补尾巴或把影子的状态回放进 surface，
///   再接实时字节。
/// - 终端 → 远端：键盘 / 粘贴 / 查询应答从 `InMemoryTerminalSession` 的 write 回调出来（任意线程），回主线程进
///   `TerminalInputChannel`；网格尺寸走 resize 回调进同一个通道（同轮合并、相同不重发）。
///   应答只有一个来源：画面在吃字节时由 surface 答，其余时候由影子答（输出泵切换）。
@MainActor
final class GhosttyTerminalBridge {
    let view: GhosttySurfaceView
    /// 会话的 host-managed IO（`TerminalSession.surfaceIO`）。
    let io: InMemoryTerminalSession
    private weak var owner: TerminalSession?
    private let delegate = DelegateProxy()

    /// Ghostty 最近报告的网格。
    private(set) var grid: (cols: Int, rows: Int)?
    /// 上次通知「网格变了」（`shadowGridDidChange`）时影子的网格。
    private var notifiedShadowSize: (cols: Int, rows: Int)?
    /// 测试 / 探针用：Ghostty 发往后端的全部字节（键盘与应答）都经过这里。
    var onWriteForTesting: (@MainActor (Data) -> Void)?
    /// surface 此刻在吃实时字节（挂上并且已经用影子的状态对齐过）。
    var isLive: Bool { owner?.outputPump.isFeedingSurface ?? false }
    /// 测试用：影子的状态回放进 surface 的次数。
    var seedCount: Int { owner?.outputPump.currentStats.replays ?? 0 }

    /// 视图在不在窗口里（切走的标签被 SwiftUI 卸下来就不在）。不在：surface 停画、不吃字节（只喂影子），
    /// 隔 `hiddenReleaseDelay` 还没回来就放掉 surface；回来时重建（放掉了的话）并由泵回放。
    private(set) var isOnScreen = false
    private let retention = TerminalSurfaceRetention()
    /// 不在屏上多久放掉 surface（测试里改短）。
    var hiddenReleaseDelay: Duration {
        get { retention.delay }
        set { retention.delay = newValue }
    }
    /// 擦屏后清选区、整屏回放后找回视口（两端共用）。
    var keeper: TerminalSurfaceKeeper { link.keeper }
    /// 会话的影子 + surface 接线（`TerminalSession.link`）。
    private let link: TerminalSurfaceLink

    init(owner: TerminalSession) {
        self.owner = owner
        link = owner.link
        io = owner.surfaceIO
        // 出生时零尺寸：surface 要等容器把真实尺寸提交给视图（停稳之后）才建。给个临时尺寸的话，视图第一次进窗口那一刻
        // surface 就按它建好、报出一个对不上 PTY 的网格，影子跟着缩过去再放回来——备用屏被清空、这段时间到的输出按错的
        // 宽度排，而 PTY 尺寸始终没变、程序不会重画（800×500 时实测影子 144×46 → 106×35 → 144×46，
        // `TerminalContainerViewTests.testFirstMountNeverMovesTheShadowOffThePTYGrid`）。
        view = GhosttySurfaceView(frame: .zero)
        link.attach(view)
        link.onSurfaceInput = { [weak self] in self?.ghosttyDidWrite($0) }
        // 击键在 IO 线程上直接进会话的输入通道，不先回主线程（见 `TerminalInputChannel`）；主线程上只给测试报一声。
        link.directInput = { [sink = owner.inputChannel.direct] data in
            sink.write(data)
            return true
        }
        link.onSurfaceInputSent = { [weak self] in self?.onWriteForTesting?($0) }
        link.onGridReported = { [weak self] viewport in
            self?.ghosttyDidResize(cols: Int(viewport.columns), rows: Int(viewport.rows))
        }
        link.platformAllowsFeeding = { [weak self] in self?.isOnScreen ?? false }
        // 从这一刻起尺寸归 surface 管：没有 surface 时钉的尺寸不用再还原（钉着的目标还在 `pendingPin` 里，
        // surface 报来格子尺寸后照常钉到视图上）。
        link.onSurfaceAttached = { [weak self] in self?.gridBeforeSurfacelessPin = nil }
        // 按行填满（两端共用的规则与接线在 `TerminalSurfaceLink`）：钉着远控尺寸时不调；零头的上半份由容器把视图往下挪。
        link.rowFillSuspended = { [weak view] in view?.pinnedFrameSize != nil }
        link.onRowFillOffsetChanged = { [weak view] in view?.superview?.needsLayout = true }
        view.cursorRowProvider = { [weak self] in self?.cursorRow }
        view.refitRowFill = { [weak link] in
            link?.refitRowFill()
            return link?.rowFillOffset ?? 0
        }
        delegate.bridge = self
        view.delegate = delegate
        view.controller = GhosttyTerminalConfig.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io))
        view.onResizeSettled = { [weak self] in self?.resizeDidSettle() }
        view.onWindowChange = { [weak self] inWindow in self?.setOnScreen(inWindow) }
        view.search = link.search
        view.onFocusGained = { [weak self] in self?.owner?.acknowledgeProgramStatus() }
        view.onPasteImage = { [weak self] in self?.owner?.pasteImage($0) ?? false }
        view.onControlVImage = { [weak self] in self?.owner?.handleControlVImage($0) ?? false }
        view.scrollsPagesLocally = { [weak self] in
            // 程序自己要翻页键的时候（全屏程序开了应用光标键、开了 kitty 键盘协议、在备用屏上）交给程序。
            guard let shadow = self?.owner?.shadow else { return false }
            return shadow.kittyKeyboardFlags == 0 && !shadow.isModeSet(1) && !shadow.isOnAlternateScreen
        }
        view.uTermSendsCommandChords = { [weak self] in
            // 开了 kitty 键盘协议的程序能收带 ⌘（super）的按键；legacy 模式下没有绑定接的不发（本地包里丢，见
            // `TerminalSurface.sendsCommandChords`）。看影子终端。
            (self?.owner?.shadow.kittyKeyboardFlags ?? 0) != 0
        }
        view.onControlReturn = { [weak self] in
            // 程序没开 kitty 键盘协议时发回车；开了就让 Ghostty 自己编带修饰键的序列。
            // 协议开没开看影子终端（吃的是同一份字节）。
            guard let owner = self?.owner, owner.shadow.kittyKeyboardFlags == 0 else { return false }
            owner.sendHostBytes(Data([0x0D]))
            return true
        }
    }

    /// 键盘焦点在这个终端上、窗口是 key（`TerminalSession.isUserLooking` 再加上 app 在前台）。
    var isFocusedInWindow: Bool {
        guard let window = view.window else { return false }
        return window.isKeyWindow && window.firstResponder === view
    }

    // MARK: surface 的生命周期

    /// surface 的生灭、就绪（等它的终端报出和视图一致的网格才开闸）、追上影子都在 `TerminalSurfaceLink`（两端共用）。
    /// surface 建着没有（视图进过窗口、没被放掉）。没建时没有视图尺寸可钉，接管尺寸直接作用在影子终端和 PTY 上。
    private var hasSurface: Bool { link.hasSurface }

    // MARK: 在不在屏上

    /// 视图进出窗口时调（`GhosttySurfaceView.viewDidMoveToWindow`）。
    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        retention.cancel()
        if onScreen {
            if view.uTermIsSurfaceReleased {
                // 重建：建好后走 surface 就绪 → 网格到位 → 回放 → 由 `keeper` 找回切走前的视口。
                // 先把「可见」声明回来：切走时声明过不可见，这个状态记在视图上、不随 surface 放掉而清；新 surface 出生时
                // 就带着它，引擎对不可见的 surface 整个跳过绘制——窗格白着，要等再切一次（走下面 else 的 `true`）才好。
                view.setSurfaceVisible(true)
                view.uTermRestoreSurface()
            } else {
                view.setSurfaceVisible(true)
                // 期间没来过输出：surface 一直停在原处，不用追，记着的视口作废。
                link.forgetViewportUnlessCatchingUp()
            }
            link.syncSurfaceFeeding()
            return
        }
        // 切走之前记下视口：之后要是只能整屏回放（surface 被放掉、期间输出太多），回来时找回这里。
        link.rememberViewport()
        view.setSurfaceVisible(false)
        link.syncSurfaceFeeding()
        guard hasSurface else { return }
        retention.scheduleRelease { [weak self] in
            guard let self, !self.isOnScreen else { return }
            self.view.uTermReleaseSurface()
        }
    }

    /// surface 被放掉了没有（测试用）。
    var isSurfaceReleased: Bool { view.uTermIsSurfaceReleased }

    // MARK: 输入出 / 尺寸

    fileprivate func ghosttyDidWrite(_ data: Data) {
        onWriteForTesting?(data)
        owner?.sendHostBytes(data)
    }

    /// `fromTerminal`：这是 surface 的终端自己报来的网格（resize 回调）。容器提交尺寸后主动补报的那次（`resizeDidSettle`）
    /// 读的是主线程上刚设下的尺寸，IO 线程上的终端可能还在出生时的默认网格——那一次不能算「终端报来了真实网格」，
    /// 否则 surface 刚建好就在提交尺寸的同一调用里开闸，回放按默认网格（约 53×21）灌进去，影子比它高的行被顶进回滚区，
    /// 随后终端改到真实尺寸也拉不回来：窗格一片空白。
    fileprivate func ghosttyDidResize(cols reportedCols: Int, rows reportedRows: Int, fromTerminal: Bool = true) {
        // 报来的网格是 Ghostty 的 IO 线程在某一刻量的，转到主线程时可能已经过时。最常见的一次：surface 刚建好时先按
        // 引擎默认的 800×600 px 报一个约 53×21，紧接着才是视图的真实尺寸；把过时的那个发给 PTY，正在跑的全屏程序
        // （重启后接回的 Claude Code）就先按 53 列重排一遍。所以发给 PTY 的以 surface 此刻的网格为准，并且要等影子已经
        // 换上它（`ptyGrid`；那次默认网格的报告影子不认）：之后的报告到达时值相同，不会重复发。
        // 影子终端不在这里改：它只跟 surface 的终端自己报的网格走（IO 线程的 resize 回调里当场改，M4 的前提——按主线程上
        // 的网格改，两边会在不同的字节位置换宽度，折行就对不上了）。主线程上的 `surfaceGrid` 可能比终端先变，这一刻
        // 按它改影子就早了。
        var cols = reportedCols, rows = reportedRows
        if let current = io.surfaceGrid, current.columns > 0, current.rows > 0 {
            cols = Int(current.columns)
            rows = Int(current.rows)
        }
        guard cols > 0, rows > 0 else { return }
        // 远控主控端停着画面等网格对齐的话，现在可能对上了；surface 刚建好的话看闸能不能开。
        if fromTerminal { link.gridReported(cols: reportedCols, rows: reportedRows) } else { link.pump.surfaceGridDidChange() }
        let changed = grid.map { $0.cols != cols || $0.rows != rows } ?? true
        grid = (cols, rows)
        // 镜像端重发快照、检查点重存，要等影子真的换了网格：主线程上的 `surfaceGrid` 可能比终端先变（容器提交尺寸后
        // 主动补报的那一次），这时影子还是旧网格，按它拍的快照是旧尺寸；IO 线程改完影子、报过来的那一次再算。
        if let shadowSize = owner?.shadow.size, changed || notifiedShadowSize.map({ $0 != shadowSize }) ?? true {
            notifiedShadowSize = shadowSize
            owner?.shadowGridDidChange()
        }
        // 钉着，网格却不是钉的行列数：钉住的视图尺寸是按旧格子算的，按此刻的格子重钉（见 `repinIfStale`）。
        // 这次的网格是错的，不发给 PTY，重钉之后 surface 报来的那一次才发。
        if repinIfStale(cols: cols, rows: rows) { return }
        // 容器还在等尺寸停稳（首次挂载、接回、窗口在定尺寸）：这时的网格是中间态，不发给 PTY；停稳后
        // `resizeDidSettle` 再发最终那一次。远控钉住的尺寸是确定的目标，照发。
        if !view.holdsGridReports || view.pinnedFrameSize != nil, let pty = ptyGrid(surfaceGrid: (cols, rows)) {
            owner?.ghosttyGridDidChange(cols: pty.cols, rows: pty.rows)
        }
        // 钉住时网格变了（手机软键盘升降）：Ghostty 放大行数会把回滚的行拉回屏幕、缩小则往上顶，光标行跟着挪，
        // 这期间没有新输出，`repositionPinnedGridIfCursorMoved` 不会被输出触发——在这里按新网格下的光标行重摆。
        repositionPinnedGridIfCursorMoved()
        // surface 还没建好时就来了接管：现在有格子尺寸了，补上。
        if let pending = pendingPin, view.pinnedFrameSize == nil { pinGrid(cols: pending.cols, rows: pending.rows) }
    }

    /// 钉住的视图尺寸 = 行列数 × 格子（`pinGrid` 那一刻的格子）。两种情况下它和 surface 此刻的格子对不上，网格就不是
    /// 手机的行列数（手机按 32 行画、PTY 却是 33 行，Claude Code 的画面在手机上错位）：
    /// - 标签藏久了 surface 被放掉、切回来重建：新 surface 的行高调整归 0（按行填满调过的格子变回自然高度），
    ///   按旧格子算的高度多出一行；
    /// - 藏着（surface 放掉了、量不到格子）时手机又钉了新尺寸：只改了影子和 PTY（`pendingPin`），视图还是上一次钉的尺寸。
    /// 这时按 `pendingPin` 和此刻的格子重钉。重钉后的尺寸和原来一样（格子的取整怎么都凑不出那个行列数）时不算，照常发。
    /// 返回重钉了没有。
    private func repinIfStale(cols: Int, rows: Int) -> Bool {
        guard let pending = pendingPin, let pinned = view.pinnedFrameSize,
              pending.cols != cols || pending.rows != rows else { return false }
        pinGrid(cols: pending.cols, rows: pending.rows)
        return view.pinnedFrameSize != pinned
    }

    /// 发给 PTY 的网格：影子终端已经换上了的才发；还没换上（主线程上刚设下、引擎 IO 线程还没处理到）返回 nil，不发。
    ///
    /// 程序一收到 SIGWINCH 就按新尺寸整帧重画（Claude Code：从左上角逐行擦一屏再写整帧，之后全靠相对移动改行）。
    /// 影子在引擎 IO 线程处理到这次 resize 时才换网格（引擎还会把连着的几次 resize 合并、隔一小会儿才处理），
    /// 要是 PTY 先知道了新尺寸，程序按新尺寸画的那一帧就先进了旧网格的影子、随后被重新折行——影子从此和程序以为的屏幕
    /// 错开几行，之后每次相对移动都落错地方。远控镜像、holder 检查点都是影子的快照，手机上看到的就是这个：字打到屏幕
    /// 左上角、擦行擦不到该擦的地方（`400k5`）、状态行出现两遍（真机回归，`RemoteMirrorClaudeRedrawTests`）。
    /// 所以 PTY 只跟影子：影子换上这个网格的那一次报告（IO 线程的 resize 回调）转到主线程时再发，程序之后写的字节一定
    /// 落在新网格上；中途还没换上的尺寸（容器提交尺寸后主动补报的那一次、引擎还没处理的下一次）一律不发，等它的报告。
    /// 远控主控端的影子跟着对端的快照走，这里发的是本地画面的网格（就是要对端按它钉尺寸），照旧。
    private func ptyGrid(surfaceGrid: (cols: Int, rows: Int)) -> (cols: Int, rows: Int)? {
        guard let owner else { return nil }
        if link.pump.followsSnapshotGrid { return surfaceGrid }
        return owner.shadow.size == surfaceGrid ? surfaceGrid : nil
    }

    /// 容器把视图尺寸提交了（停稳了）：把网格发给 PTY。网格没变时引擎不会再报一次，所以这里主动补（等待期间报来、
    /// 影子已经换上的那个）；变了的话影子还没换上，这次不发，等引擎报来、影子换上时再发（`ptyGrid`）。
    /// surface 还没建时什么也不做，它建好后报的第一次照常走。
    private func resizeDidSettle() {
        guard let current = io.surfaceGrid, current.columns > 0, current.rows > 0 else { return }
        ghosttyDidResize(cols: Int(current.columns), rows: Int(current.rows), fromTerminal: false)
    }

    // MARK: 远控接管尺寸

    /// 还没法钉（surface 没建好、量不到格子尺寸）时记下的目标。
    private var pendingPin: (cols: Int, rows: Int)?
    /// 没有 surface 时被接管之前的行列数：解除接管时还原。
    private var gridBeforeSurfacelessPin: (cols: Int, rows: Int)?

    /// 把 Ghostty 视图钉成 `cols × rows`：Ghostty 没有内留白（配置里 padding 是 0），网格 = ⌊视图像素 ÷ 格子像素⌋，
    /// 所以视图取「行列数 × 格子像素 ÷ 屏幕倍率」正好是那个行列数，不用试探。
    /// 之后 Ghostty 报来新网格（`ghosttyDidResize`），影子终端、PTY、镜像都跟着走。
    func pinGrid(cols: Int, rows: Int) {
        pendingPin = (cols, rows)
        guard let cell = view.uTermCellPixels else {
            // 标签从没露出过（重启后接回、还没点开的标签）：surface 没建，量不到格子。手机照样要能接管它——
            // 这时终端的尺寸只有影子终端和 PTY 两处，直接改；surface 建好之后由上面的 `pendingPin` 钉到视图上。
            if !hasSurface { resizeWithoutSurface(cols: cols, rows: rows, rememberingCurrent: true) }
            return
        }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        view.pinnedFrameSize = NSSize(width: CGFloat(cols) * cell.width / scale, height: CGFloat(rows) * cell.height / scale)
        // 光标行不在这里定：容器每次摆放时现读（`cursorRowProvider`），并记下用的是哪一行。
        view.pinnedCursorRow = nil
        owner?.tracksCursorForPinnedGrid = true
        if view.superview == nil, let pinned = view.pinnedFrameSize {
            // 窗格此刻不在视图层级里（藏在别的标签后面）：没有容器来摆，直接把视图设成钉住的尺寸。
            view.setFrameSize(pinned)
        } else {
            view.superview?.needsLayout = true
        }
    }

    func unpinGrid() {
        pendingPin = nil
        owner?.tracksCursorForPinnedGrid = false
        if !hasSurface, let before = gridBeforeSurfacelessPin {
            resizeWithoutSurface(cols: before.cols, rows: before.rows, rememberingCurrent: false)
        }
        gridBeforeSurfacelessPin = nil
        guard view.pinnedFrameSize != nil else { return }
        view.pinnedFrameSize = nil
        view.pinnedCursorRow = nil
        if let container = view.superview {
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
    }

    /// 没有 surface 时改终端的行列数：影子终端当场改，镜像端重发快照，PTY 收到新尺寸——和 surface 报来新网格时
    /// （`ghosttyDidResize`）走的是同一串后续动作。
    private func resizeWithoutSurface(cols: Int, rows: Int, rememberingCurrent: Bool) {
        guard let owner, cols > 0, rows > 0 else { return }
        let current = owner.shadow.size
        if rememberingCurrent, gridBeforeSurfacelessPin == nil { gridBeforeSurfacelessPin = current }
        guard current.cols != cols || current.rows != rows else { return }
        owner.shadow.resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
        owner.shadowGridDidChange()
        owner.ghosttyGridDidChange(cols: cols, rows: rows)
    }

    /// 光标在屏幕第几行（看影子终端：吃的是同一份字节）。
    private var cursorRow: Int? { owner?.shadow.cursor.y }

    /// 钉住期间来了新输出：光标换了行就让容器重新摆一次（比窗格高的终端跟着光标走）。
    /// 只比较、请求重摆，不写 `pinnedCursorRow`：它记的是容器上一次摆放实际用的那一行，由容器自己写。
    func repositionPinnedGridIfCursorMoved() {
        guard view.pinnedFrameSize != nil, let row = cursorRow, row != view.pinnedCursorRow else { return }
        view.superview?.needsLayout = true
    }

    // MARK: 外观

    // `GhosttyHostView` 每次 SwiftUI 更新都会调下面两个；值没变就不动，免得每次更新都整份重载配置。
    private static var appliedDark: Bool?
    private static var appliedSettings: TerminalSettings?

    /// app 外观变了：Ghostty 按 theme 里的深 / 浅两套切。
    static func applyAppearance(dark: Bool) {
        guard appliedDark != dark else { return }
        appliedDark = dark
        GhosttyTerminalConfig.controller.setColorScheme(dark ? .dark : .light)
    }

    /// 字体 / 光标 / 历史这类设置变了（整份配置重载，所有 Ghostty 窗格一起生效）。
    static func apply(settings: TerminalSettings) {
        guard appliedSettings != settings else { return }
        appliedSettings = settings
        GhosttyTerminalConfig.controller.setTerminalConfiguration(GhosttyTerminalConfig.base(settings: settings))
    }

    // MARK: 读屏（测试 / 对照用）

    /// 可见区文字，一行一行（Ghostty 侧的读法）。
    func viewportText() -> String? { io.readViewportText() }

    func dispose() {
        retention.cancel()
        view.delegate = nil
        view.removeFromSuperview()
    }

    /// Ghostty 的各个回调协议。单独一个对象：`TerminalSession` 不必知道这些协议。标题、铃、OSC 7 都以影子终端为准
    /// （标签藏着、surface 没在吃字节时它照样更新），surface 的那几个回调不接；surface 的生灭由 `TerminalSurfaceLink` 接。
    private final class DelegateProxy: TerminalSurfaceFocusDelegate,
        TerminalSurfaceClipboardConfirmationDelegate, TerminalSurfaceScrollbarDelegate, TerminalSurfaceSearchDelegate,
        TerminalSurfaceOpenURLHandlingDelegate {
        weak var bridge: GhosttyTerminalBridge?

        /// ⌘ 点链接：网址交给系统，路径在预览区打开（`TerminalSession.openTerminalLink`）。
        func terminalShouldHandleOpenURL(_ url: String, kind: TerminalOpenURLKind) -> Bool {
            bridge?.owner?.openTerminalLink(url, kind: kind) ?? false
        }

        // 回滚区查找：引擎报来的一律交给会话的查找状态（两端共用的 `TerminalSearch`）。
        func terminalDidStartSearch(needle: String?) { bridge?.link.search.handle(.started(needle: needle)) }
        func terminalDidEndSearch() { bridge?.link.search.handle(.ended) }
        func terminalDidUpdateSearchTotal(_ total: Int?) { bridge?.link.search.handle(.total(total)) }
        func terminalDidUpdateSearchSelected(_ selected: Int?) { bridge?.link.search.handle(.selected(selected)) }

        /// 视口滚了或者内容变长了：给容器画滚动条用。
        func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
            bridge?.view.onScrollbar?(scrollbar)
        }

        func terminalDidChangeFocus(_ focused: Bool) {
            if focused { bridge?.owner?.acknowledgeProgramStatus() }
        }

        /// 不安全粘贴（多行 / 带控制字符）与受保护的 OSC 52。uTerm 一直没有粘贴保护，照放行处理；OSC 52 只许写不许读。
        func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
            switch request.kind {
            case .paste: request.respond(allow: true)
            case .osc52Read: request.respond(allow: false)
            case .osc52Write: request.respond(allow: true)
            }
        }
    }
}

/// uTerm 的 Ghostty 视图子类：焦点回到终端、只有图片的剪贴板（⌘V / ⌃V）、⌃↩、右键菜单，以及按键的去向（见 `TerminalKeyBindings`）。
final class GhosttySurfaceView: AppTerminalView {
    var onFocusGained: (@MainActor () -> Void)?
    var onPasteImage: (@MainActor (TerminalImage) -> Bool)?
    var onControlVImage: (@MainActor (TerminalImage) -> Bool)?
    /// ⌃↩。返回 true = 已经替程序发了回车；false = 交回 Ghostty 自己编码。
    var onControlReturn: (@MainActor () -> Bool)?
    /// 容器还在等尺寸停稳：这期间报来的网格不发给 PTY（见 `GhosttyContainerView.syncSurfaceFrame`）。
    var holdsGridReports = false
    /// 容器提交了尺寸。
    var onResizeSettled: (@MainActor () -> Void)?
    /// 容器提交尺寸之后调：按行填满重算（可能给 surface 换行高），返回网格要往下挪的点数（见 `TerminalSurfaceLink.refitRowFill`）。
    var refitRowFill: (@MainActor () -> CGFloat)?

    /// 容器在提交尺寸（或确认尺寸没变）之后调：放开网格上报，并把此刻的网格发出去。
    func resizeDidSettle() {
        holdsGridReports = false
        onResizeSettled?()
    }

    /// 远控接管尺寸时钉住的视图尺寸（对端行列数 × 格子）。非 nil 时 `GhosttyContainerView` 按它摆放而不是铺满。
    var pinnedFrameSize: NSSize?
    /// 钉住期间上一次摆放时光标在第几行（比窗格高时跟着光标走，见 `GhosttyContainerView.pinnedFrame`）。
    var pinnedCursorRow: Int?
    /// 光标此刻在屏幕第几行（影子终端读）。容器钉住尺寸摆放时现读，不用缓存的值——网格变了光标行会跟着挪（手机软键盘升降），
    /// 那期间没有新输出触发更新。
    var cursorRowProvider: (@MainActor () -> Int?)?
    /// 引擎报来的滚动条（总行数、视口首行、一屏行数），和用户刚滚了一下：容器据此画滚动条。
    var onScrollbar: (@MainActor (TerminalScrollbar) -> Void)?
    var onScrollActivity: (@MainActor () -> Void)?
    /// 这片终端的回滚区查找（会话的 `TerminalSurfaceLink.search`）：⌘F / ⌘G / ⇧⌘G / ⌘E 与「编辑 ▸ 查找」菜单都落到它上面。
    weak var search: TerminalSearch?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScrollActivity?()
    }
    var pasteboard: NSPasteboard = .general
    /// PageUp / PageDown（不带修饰键）此刻该不该在本地翻回滚。返回 false = 发给程序。
    var scrollsPagesLocally: (@MainActor () -> Bool)?
    /// ⌘ 组合先交给主菜单试一次，返回 true = 菜单接了。测试里换掉（真的主菜单会把 ⌘Q、⌘W 执行掉）。
    var performMenuKeyEquivalent: @MainActor (NSEvent) -> Bool = { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false }
    /// 这次右键按下弹了我们的菜单（没报给程序）：松开时也不报。
    private var rightClickShowedMenu = false
    /// 进出窗口（参数：现在在不在窗口里）。
    var onWindowChange: (@MainActor (Bool) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusGained?() }
        return ok
    }

    override func paste(_ sender: Any?) {
        if let image = TerminalImage.fromPasteboard(pasteboard), onPasteImage?(image) == true { return }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, event.keyCode == kVK_ANSI_V,
           let image = TerminalImage.fromPasteboard(pasteboard) {
            let mods = event.modifierFlags.intersection([.control, .command, .option, .shift])
            if mods == .command, onPasteImage?(image) == true { return true }
            if mods == .control, onControlVImage?(image) == true { return true }
        }
        // ⌃↩：Ghostty 自己接的话按 modifyOtherKeys 发 `CSI 27;5;13~`，没开 kitty 协议的程序（shell、Claude）不认。
        // macOS 15 起系统还把 ⌃↩ 绑成「显示上下文菜单」，所以只能在 key equivalent 这一层截（换引擎前也是这样）。
        if event.type == .keyDown, window?.firstResponder === self, Self.isControlReturn(event), onControlReturn?() == true {
            return true
        }
        // 查找：在问主菜单之前接，菜单里有没有「查找」都一样（SwiftUI 的「编辑」菜单不一定带）。绑定表里清掉了 Ghostty 的
        // ⌘F（`TerminalKeyBindings`），查找栏是 uTerm 自己画的。
        if event.type == .keyDown, window?.firstResponder === self, let command = Self.findCommand(for: event),
           performFind(command) {
            return true
        }
        // ⌘ 组合先问主菜单。key equivalent 是先问视图层级、没人要才轮到菜单；终端视图留着的那几条绑定
        // （⌘C / ⌘V / ⌘A、⌘← / ⌘→ / ⌘⌫，见 `TerminalKeyBindings`）一旦先认下，「编辑」菜单里的同名项就永远轮不到。
        // 官方 Ghostty 的 macOS 视图也是先试菜单，菜单不要的组合再回到终端。Ghostty 其余的默认绑定已经在配置里清掉，
        // 不会再吞 uTerm 的快捷键（SwiftUI 里不在菜单上的 `keyboardShortcut`，如 ⌘K 命令面板，靠的就是这个）。
        if event.type == .keyDown, window?.firstResponder === self, event.modifierFlags.contains(.command),
           performMenuKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // PageUp / PageDown 不带修饰键：停在 shell 提示符上时翻一页回滚，不发给程序（shell 收到的是 `CSI 5~`，
        // 只会在命令行里留下一个「~」）。换引擎之前就是这样；Ghostty 自己没有这条规则，绑定表也表达不了「看模式」。
        if let action = Self.pageScrollAction(for: event), scrollsPagesLocally?() == true, performBindingAction(action) {
            return
        }
        // 没有菜单、没有绑定接的 ⌘ 组合：程序没开 kitty 键盘协议时由本地包丢掉（`uTermSendsCommandChords`）。
        super.keyDown(with: event)
    }

    // MARK: 查找

    enum FindCommand: Equatable { case show, next, previous, useSelection }

    /// ⌘F 打开查找栏、⌘G / ⇧⌘G 往上 / 往下找、⌘E 用所选内容查找（Mac 上的通用键位）。
    static func findCommand(for event: NSEvent) -> FindCommand? {
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch (Int(event.keyCode), mods) {
        case (kVK_ANSI_F, .command): return .show
        case (kVK_ANSI_G, .command): return .next
        case (kVK_ANSI_G, [.command, .shift]): return .previous
        case (kVK_ANSI_E, .command): return .useSelection
        default: return nil
        }
    }

    /// 做成了返回 true。「用所选内容查找」没有选区时做不成，按键交回去（菜单、程序）。
    @discardableResult
    func performFind(_ command: FindCommand) -> Bool {
        guard let search else { return false }
        switch command {
        case .show: search.present()
        case .next: search.next()
        case .previous: search.previous()
        case .useSelection:
            guard selectionRegion != nil else { return false }
            search.presentWithSelection()
        }
        return true
    }

    @objc func showTerminalFind(_ sender: Any?) {
        performFind(.show)
    }

    /// 「编辑 ▸ 查找」菜单（`NSTextFinder.Action` 与 `NSFindPanelAction` 的这几个取值相同：1 显示、2 下一个、3 上一个、
    /// 7 用所选内容）。
    override func performTextFinderAction(_ sender: Any?) {
        if let command = Self.findCommand(forMenuTag: (sender as? NSMenuItem)?.tag ?? 0) { performFind(command) }
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    static func findCommand(forMenuTag tag: Int) -> FindCommand? {
        switch tag {
        case 1: .show
        case 2: .next
        case 3: .previous
        case 7: .useSelection
        default: nil
        }
    }

    private static func pageScrollAction(for event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return nil }
        switch Int(event.keyCode) {
        case kVK_PageUp: return "scroll_page_up"
        case kVK_PageDown: return "scroll_page_down"
        default: return nil
        }
    }

    private static func isControlReturn(_ event: NSEvent) -> Bool {
        let isReturnKey = event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter
        return isReturnKey && event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command)
    }

    // MARK: 右键菜单

    /// 拷贝 / 粘贴 / 全选，uTerm 自己的那一份（GhosttyKit 自带的只在有选区时给一个「Copy」）。没有选区时「拷贝」置灰。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = TerminalSession.makeContextMenu(for: self)
        menu.autoenablesItems = false
        menu.items.first { $0.action == #selector(NSText.copy(_:)) }?.isEnabled = selectionRegion != nil
        if search != nil {
            menu.addItem(.separator())
            let find = NSMenuItem(title: String(localized: "查找…"), action: #selector(showTerminalFind(_:)), keyEquivalent: "f")
            find.target = self
            menu.addItem(find)
        }
        return menu
    }

    /// 程序抓着鼠标（vim / tmux 开 mouse、Claude 全屏界面）时右键报给程序；否则弹菜单。
    /// GhosttyKit 的 `rightMouseDown` 不调 super，AppKit 不会自己来问 `menu(for:)`，所以在这里弹。
    override func rightMouseDown(with event: NSEvent) {
        guard !isMouseCaptured, let menu = menu(for: event) else {
            rightClickShowedMenu = false
            super.rightMouseDown(with: event)
            return
        }
        rightClickShowedMenu = true
        window?.makeFirstResponder(self)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func rightMouseUp(with event: NSEvent) {
        if rightClickShowedMenu {
            rightClickShowedMenu = false
            return
        }
        super.rightMouseUp(with: event)
    }
}

// MARK: - TerminalSession 一侧

extension TerminalSession {
    /// Ghostty 的网格变了：远端随之 SIGWINCH。影子终端已经在 resize 回调里当场跟上了。
    func ghosttyGridDidChange(cols: Int, rows: Int) {
        inputChannel.reportSize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
    }

    /// 网格的行列数真的变了：镜像端改发一份新尺寸下的快照，检查点也重存。
    func shadowGridDidChange() {
        mirrorTap.invalidateAll()
        heldCheckpoints?.noteScreenChanged()
    }
}

extension GhosttySurfaceView: NSMenuItemValidation {
    /// 「编辑 ▸ 查找」里只有显示 / 上一个 / 下一个 / 用所选内容这几项能用（替换类的置灰）；其余菜单项照旧。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(performTextFinderAction(_:)), #selector(performFindPanelAction(_:)):
            guard search != nil, let command = Self.findCommand(forMenuTag: menuItem.tag) else { return false }
            return command != .useSelection || selectionRegion != nil
        default:
            return true
        }
    }
}
