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
        view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        link.attach(view)
        link.onSurfaceInput = { [weak self] in self?.ghosttyDidWrite($0) }
        link.onGridReported = { [weak self] viewport in
            self?.ghosttyDidResize(cols: Int(viewport.columns), rows: Int(viewport.rows))
        }
        link.platformAllowsFeeding = { [weak self] in self?.isOnScreen ?? false }
        // 从这一刻起尺寸归 surface 管：没有 surface 时钉的尺寸不用再还原（钉着的目标还在 `pendingPin` 里，
        // surface 报来格子尺寸后照常钉到视图上）。
        link.onSurfaceAttached = { [weak self] in self?.gridBeforeSurfacelessPin = nil }
        delegate.bridge = self
        view.delegate = delegate
        view.controller = GhosttyTerminalConfig.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io))
        view.onResizeSettled = { [weak self] in self?.resizeDidSettle() }
        view.onWindowChange = { [weak self] inWindow in self?.setOnScreen(inWindow) }
        view.onFocusGained = { [weak self] in self?.owner?.acknowledgeProgramStatus() }
        view.onPasteImage = { [weak self] in self?.owner?.pasteImage($0) ?? false }
        view.onControlVImage = { [weak self] in self?.owner?.handleControlVImage($0) ?? false }
        view.scrollsPagesLocally = { [weak self] in
            // 程序自己要翻页键的时候（全屏程序开了应用光标键、开了 kitty 键盘协议、在备用屏上）交给程序。
            guard let shadow = self?.owner?.shadow else { return false }
            return shadow.kittyKeyboardFlags == 0 && !shadow.isModeSet(1) && !shadow.isOnAlternateScreen
        }
        view.sendsCommandChords = { [weak self] in
            // 开了 kitty 键盘协议的程序能收带 ⌘（super）的按键；legacy 模式下不发。看影子终端。
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

    fileprivate func ghosttyDidResize(cols reportedCols: Int, rows reportedRows: Int) {
        // 报来的网格是 Ghostty 的 IO 线程在某一刻量的，转到主线程时可能已经过时。最常见的一次：surface 刚建好时先按
        // 引擎默认的 800×600 px 报一个约 53×21，紧接着才是视图的真实尺寸；把过时的那个发给 PTY，正在跑的全屏程序
        // （重启后接回的 Claude Code）就先按 53 列重排一遍。所以发给 PTY 的一律以 surface 此刻的网格为准：之后那次报告
        // 到达时值相同，不会重复发。
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
        link.gridReported(cols: cols, rows: rows)
        let changed = grid.map { $0.cols != cols || $0.rows != rows } ?? true
        grid = (cols, rows)
        // 镜像端重发快照、检查点重存，要等影子真的换了网格：主线程上的 `surfaceGrid` 可能比终端先变（容器提交尺寸后
        // 主动补报的那一次），这时影子还是旧网格，按它拍的快照是旧尺寸；IO 线程改完影子、报过来的那一次再算。
        if let shadowSize = owner?.shadow.size, changed || notifiedShadowSize.map({ $0 != shadowSize }) ?? true {
            notifiedShadowSize = shadowSize
            owner?.shadowGridDidChange()
        }
        // 容器还在等尺寸停稳（首次挂载、接回、窗口在定尺寸）：这时的网格是中间态，不发给 PTY；停稳后
        // `resizeDidSettle` 再发最终那一次。远控钉住的尺寸是确定的目标，照发。
        if !view.holdsGridReports || view.pinnedFrameSize != nil {
            owner?.ghosttyGridDidChange(cols: cols, rows: rows)
        }
        // surface 还没建好时就来了接管：现在有格子尺寸了，补上。
        if let pending = pendingPin, view.pinnedFrameSize == nil { pinGrid(cols: pending.cols, rows: pending.rows) }
    }

    /// 容器把视图尺寸提交了（停稳了）：把 surface 此刻的网格发给 PTY。网格没变时引擎不会再报一次，所以这里主动补；
    /// 变了的话引擎随后报来的值相同，输入通道去重。surface 还没建时什么也不做，它建好后报的第一次照常走。
    private func resizeDidSettle() {
        guard let current = io.surfaceGrid, current.columns > 0, current.rows > 0 else { return }
        ghosttyDidResize(cols: Int(current.columns), rows: Int(current.rows))
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
        view.pinnedCursorRow = cursorRow
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
    func repositionPinnedGridIfCursorMoved() {
        guard view.pinnedFrameSize != nil, let row = cursorRow, row != view.pinnedCursorRow else { return }
        view.pinnedCursorRow = row
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
        TerminalSurfaceClipboardConfirmationDelegate, TerminalSurfaceScrollbarDelegate {
        weak var bridge: GhosttyTerminalBridge?

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

    /// 容器在提交尺寸（或确认尺寸没变）之后调：放开网格上报，并把此刻的网格发出去。
    func resizeDidSettle() {
        holdsGridReports = false
        onResizeSettled?()
    }

    /// 远控接管尺寸时钉住的视图尺寸（对端行列数 × 格子）。非 nil 时 `GhosttyContainerView` 按它摆放而不是铺满。
    var pinnedFrameSize: NSSize?
    /// 钉住期间上一次摆放时光标在第几行（比窗格高时跟着光标走，见 `GhosttyContainerView.pinnedFrame`）。
    var pinnedCursorRow: Int?
    /// 引擎报来的滚动条（总行数、视口首行、一屏行数），和用户刚滚了一下：容器据此画滚动条。
    var onScrollbar: (@MainActor (TerminalScrollbar) -> Void)?
    var onScrollActivity: (@MainActor () -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScrollActivity?()
    }
    var pasteboard: NSPasteboard = .general
    /// PageUp / PageDown（不带修饰键）此刻该不该在本地翻回滚。返回 false = 发给程序。
    var scrollsPagesLocally: (@MainActor () -> Bool)?
    /// 没有菜单、没有绑定接的 ⌘ 组合要不要编码发给程序。返回 false（或没设）= 丢掉。
    var sendsCommandChords: (@MainActor () -> Bool)?
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
        // 没有菜单、没有绑定接的 ⌘ 组合：程序没开 kitty 键盘协议时丢掉（换引擎之前、Terminal.app 都是这样）。
        // Ghostty 在 legacy 模式下会把 ⌘↑ 编成 `CSI 1;9A`、⌘↩ 编成 `CSI 27;9;13~`，shell 不认，只会在命令行里
        // 留下「;9A」这类残渣。绑定（⌘← / ⌘→ / ⌘⌫ / ⌘C …）照常交给 Ghostty。
        if event.modifierFlags.contains(.command), sendsCommandChords?() != true, !isKeyBinding(event) {
            return
        }
        super.keyDown(with: event)
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
