import AppKit
import Carbon.HIToolbox
import GhosttyTerminal

/// 把一条 `TerminalSession` 的字节流接到 GhosttyKit 的 host-managed IO：画面、键盘输入、终端应答、网格尺寸都在这里。
///
/// ## 形态：Ghostty 画面 + 影子终端
///
/// 字节先进会话的影子终端（`TerminalSession.shadow`，libghostty-vt，同步解析），同一批字节再交给 Ghostty 的 surface
/// （异步解析、渲染线程出帧）。uTerm 要读的终端状态一律读影子；surface 只管画和输入。
/// 应答只能有一个来源：DA、DSR 这类查询由 surface 答（`ghosttyDidWrite`），影子终端不答——用户的键盘输入本来也只从
/// surface 来。
///
/// ## 时序
///
/// Ghostty 的 surface 要等视图进了窗口才建（`AppTerminalView.viewDidMoveToWindow`），之前收到的字节最多缓 1 MiB，
/// 超了丢最旧的——会截断转义序列。所以 surface 没建好时输出泵不往里送（`TerminalOutputPump.setSurfaceFeeding`）；
/// 建好那一刻泵把影子终端的状态回放进去（`ShadowTerminal.makeReplay`，开头自带复位；`receiveReplay` 不产生应答），
/// 之后再逐片转发。影子还是空的就不回放。surface 一旦建好，视图离开窗口（切标签）也不销毁，继续吃字节。
@MainActor
final class GhosttyTerminalBridge {
    let view: GhosttySurfaceView
    /// 会话的 host-managed IO（`TerminalSession.surfaceIO`）。
    let io: InMemoryTerminalSession
    private weak var owner: TerminalSession?
    private let delegate = DelegateProxy()

    /// Ghostty 最近报告的网格。
    private(set) var grid: (cols: Int, rows: Int)?
    /// 测试 / 探针用：Ghostty 发往后端的全部字节（键盘与应答）都经过这里。
    var onWriteForTesting: (@MainActor (Data) -> Void)?
    /// surface 此刻在吃实时字节（挂上并且已经用影子的状态对齐过）。
    var isLive: Bool { owner?.outputPump.isFeedingSurface ?? false }
    /// 测试用：影子的状态回放进 surface 的次数。
    var seedCount: Int { owner?.outputPump.currentStats.replays ?? 0 }

    /// `InMemoryTerminalSession` 的 write / resize 回调（任意线程）转到主线程上的 bridge。会话先建 IO、后建 bridge，
    /// 所以中间隔一个盒子。主队列是 FIFO，键入与应答的先后顺序不会乱。
    nonisolated final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private weak var target: GhosttyTerminalBridge?

        fileprivate func attach(_ bridge: GhosttyTerminalBridge) {
            lock.withLock { target = bridge }
        }

        private var bridge: GhosttyTerminalBridge? { lock.withLock { target } }

        func write(_ data: Data) {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.bridge?.ghosttyDidWrite(data) } }
        }

        func resize(_ viewport: InMemoryTerminalViewport) {
            let cols = Int(viewport.columns), rows = Int(viewport.rows)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.bridge?.ghosttyDidResize(cols: cols, rows: rows) } }
        }
    }

    init(owner: TerminalSession) {
        self.owner = owner
        io = owner.surfaceIO
        view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        owner.surfaceIORelay.attach(self)
        delegate.bridge = self
        view.delegate = delegate
        view.controller = GhosttyTerminalConfig.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io))
        view.onFocusGained = { [weak self] in self?.owner?.acknowledgeProgramStatus() }
        view.onPasteImage = { [weak self] in self?.owner?.pasteImage($0) ?? false }
        view.onControlVImage = { [weak self] in self?.owner?.handleControlVImage($0) ?? false }
        view.onControlReturn = { [weak self] in
            // 程序没开 kitty 键盘协议时发回车；开了就让 Ghostty 自己编带修饰键的序列。
            // 协议开没开看影子终端（吃的是同一份字节）。
            guard let owner = self?.owner, owner.shadow.kittyKeyboardFlags == 0 else { return false }
            owner.sendHostBytes(Data([0x0D]))
            return true
        }
    }

    /// 用户此刻在看这个终端：同 SwiftTerm 路径的 `isUserLooking`，只是焦点看 Ghostty 视图。
    var isFocusedInWindow: Bool {
        guard let window = view.window else { return false }
        return window.isKeyWindow && window.firstResponder === view
    }

    // MARK: surface 的生命周期

    /// surface 建好了：让影子终端先跟到它此刻的网格（回放流要按接收端的尺寸生成），再让输出泵开始喂它——
    /// 泵会先把影子的状态回放进去（影子为空、surface 没落下过内容就不回放），然后接实时字节。
    fileprivate func surfaceDidAttach() {
        guard let owner else { return }
        hasSurface = true
        // 从这一刻起尺寸归 surface 管：没有 surface 时钉的尺寸不用再还原（钉着的目标还在 `pendingPin` 里，
        // surface 报来格子尺寸后照常钉到视图上）。
        gridBeforeSurfacelessPin = nil
        if let grid = io.surfaceGrid {
            owner.shadow.resize(cols: grid.columns, rows: grid.rows,
                                cellWidth: grid.cellWidthPixels, cellHeight: grid.cellHeightPixels)
        }
        owner.outputPump.setSurfaceFeeding(true)
    }

    /// surface 没了（视图被销毁、换了 controller 重建）：输出只进影子，下一个 surface 建好时再回放。
    fileprivate func surfaceDidDetach() {
        hasSurface = false
        owner?.outputPump.setSurfaceFeeding(false)
    }

    // MARK: 输入出 / 尺寸

    fileprivate func ghosttyDidWrite(_ data: Data) {
        onWriteForTesting?(data)
        owner?.sendHostBytes(data)
    }

    fileprivate func ghosttyDidResize(cols reportedCols: Int, rows reportedRows: Int) {
        // 报来的网格是 Ghostty 的 IO 线程在某一刻量的，转到主线程时可能已经过时。最常见的一次：surface 刚建好时先按
        // 引擎默认的 800×600 px 报一个约 53×21，紧接着才是视图的真实尺寸；把过时的那个发给 PTY，正在跑的全屏程序
        // （重启后接回的 Claude Code）就先按 53 列重排一遍。所以一律以 surface 此刻的网格为准：之后那次报告到达时
        // 值相同，不会重复发。影子终端在回调里是按报来的值改的，过时的话一并拉回来。
        var cols = reportedCols, rows = reportedRows
        if let current = io.surfaceGrid, current.columns > 0, current.rows > 0,
           Int(current.columns) != cols || Int(current.rows) != rows {
            cols = Int(current.columns)
            rows = Int(current.rows)
            owner?.shadow.resize(cols: current.columns, rows: current.rows,
                                 cellWidth: current.cellWidthPixels, cellHeight: current.cellHeightPixels)
        }
        guard cols > 0, rows > 0 else { return }
        let changed = grid.map { $0.cols != cols || $0.rows != rows } ?? true
        grid = (cols, rows)
        if changed { owner?.shadowGridDidChange() }
        owner?.ghosttyGridDidChange(cols: cols, rows: rows)
        // surface 还没建好时就来了接管：现在有格子尺寸了，补上。
        if let pending = pendingPin, view.pinnedFrameSize == nil { pinGrid(cols: pending.cols, rows: pending.rows) }
    }

    // MARK: 远控接管尺寸

    /// 还没法钉（surface 没建好、量不到格子尺寸）时记下的目标。
    private var pendingPin: (cols: Int, rows: Int)?
    /// surface 建着没有（视图进过窗口）。没建时没有视图尺寸可钉，接管尺寸直接作用在影子终端和 PTY 上。
    private var hasSurface = false
    /// 没有 surface 时被接管之前的行列数：解除接管时还原。
    private var gridBeforeSurfacelessPin: (cols: Int, rows: Int)?

    /// 把 Ghostty 视图钉成 `cols × rows`：Ghostty 没有内留白（配置里 padding 是 0），网格 = ⌊视图像素 ÷ 格子像素⌋，
    /// 所以视图取「行列数 × 格子像素 ÷ 屏幕倍率」正好是那个行列数，不用像 SwiftTerm 那样试探。
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
        view.superview?.needsLayout = true
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
        view.delegate = nil
        view.removeFromSuperview()
    }

    /// Ghostty 的各个回调协议。单独一个对象：`TerminalSession` 不必知道这些协议。
    private final class DelegateProxy: TerminalSurfaceTitleDelegate, TerminalSurfaceFocusDelegate,
        TerminalSurfaceLifecycleDelegate, TerminalSurfacePwdDelegate,
        TerminalSurfaceClipboardConfirmationDelegate, TerminalSurfaceBellDelegate, TerminalSurfaceScrollbarDelegate {
        weak var bridge: GhosttyTerminalBridge?

        /// 视口滚了或者内容变长了：给容器画滚动条用。
        func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
            bridge?.view.onScrollbar?(scrollbar)
        }

        /// 标题以影子终端的为准（标签藏着、surface 没在吃字节时它照样更新）；`receiveShellTitle` 去重。
        func terminalDidChangeTitle(_ title: String) {}

        func terminalDidChangeFocus(_ focused: Bool) {
            if focused { bridge?.owner?.acknowledgeProgramStatus() }
        }

        func terminalDidAttachSurface(_ surface: TerminalSurface) { bridge?.surfaceDidAttach() }
        func terminalDidDetachSurface() { bridge?.surfaceDidDetach() }

        /// OSC 7。cwd 靠后端轮询，这里不接。
        func terminalDidChangeWorkingDirectory(_ path: String) {}

        /// 影子 SwiftTerm 已经响过铃（SwiftTerm 的默认 `bell` 是 `NSSound.beep()`），这里不重复。
        func terminalDidRingBell() {}

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

/// uTerm 的 Ghostty 视图子类：焦点回到终端、只有图片的剪贴板（⌘V / ⌃V）、⌃↩、右键菜单，与 `CopyableTerminalView` 同语义。
final class GhosttySurfaceView: AppTerminalView {
    var onFocusGained: (@MainActor () -> Void)?
    var onPasteImage: (@MainActor (TerminalImage) -> Bool)?
    var onControlVImage: (@MainActor (TerminalImage) -> Bool)?
    /// ⌃↩。返回 true = 已经替程序发了回车；false = 交回 Ghostty 自己编码。
    var onControlReturn: (@MainActor () -> Bool)?
    /// 远控接管尺寸时钉住的视图尺寸（对端行列数 × 格子）。非 nil 时 `GhosttyContainerView` 按它摆放而不是铺满。
    var pinnedFrameSize: NSSize?
    /// 钉住期间上一次摆放时光标在第几行（比窗格高时跟着光标走，规则同 `TerminalContainerView.pinnedFrame`）。
    var pinnedCursorRow: Int?
    /// 引擎报来的滚动条（总行数、视口首行、一屏行数），和用户刚滚了一下：容器据此画滚动条。
    var onScrollbar: (@MainActor (TerminalScrollbar) -> Void)?
    var onScrollActivity: (@MainActor () -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScrollActivity?()
    }
    var pasteboard: NSPasteboard = .general
    /// 这次右键按下弹了我们的菜单（没报给程序）：松开时也不报。
    private var rightClickShowedMenu = false

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
        // macOS 15 起系统还把 ⌃↩ 绑成「显示上下文菜单」，所以只能在 key equivalent 这一层截（同 `CopyableTerminalView`）。
        if event.type == .keyDown, window?.firstResponder === self, Self.isControlReturn(event), onControlReturn?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isControlReturn(_ event: NSEvent) -> Bool {
        let isReturnKey = event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter
        return isReturnKey && event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command)
    }

    // MARK: 右键菜单

    /// 拷贝 / 粘贴 / 全选，和 SwiftTerm 路径同一份（GhosttyKit 自带的只在有选区时给一个「Copy」）。没有选区时「拷贝」置灰。
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
