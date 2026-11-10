import AppKit
import Carbon.HIToolbox
import GhosttyTerminal
import SwiftTerm

/// 把一条 `TerminalSession` 的字节流接到 GhosttyKit 的 host-managed IO（mac-only 试验）。
///
/// ## 形态：Ghostty 渲染 + 影子 SwiftTerm
///
/// 字节照旧由 `TerminalOutputPump` 喂给 SwiftTerm，喂完的同一批字节（`onFed`，与镜像同一个点）再交给 Ghostty。
/// 所以 SwiftTerm 在这里是**不上屏的影子**：远控镜像的快照、`terminal-read` 读屏、holder 检查点、OSC 7501 /
/// 133 / 9 / 777 这些依赖 SwiftTerm 内部状态（补丁 #6 / #11）的功能全部原样可用，一行没改。
///
/// 代价是每个字节解析两遍。应答只能有一个来源：影子 SwiftTerm 发出的应答（DA、DSR…）在
/// `TerminalSession.send(source:data:)` 里丢掉，以 Ghostty 的为准——用户的键盘输入本来也只从 Ghostty 来。
///
/// ## 时序
///
/// Ghostty 的 surface 要等视图进了窗口才建（`AppTerminalView.viewDidMoveToWindow`），之前收到的字节最多缓 1 MiB，
/// 超了丢最旧的——会截断转义序列。所以 surface 没挂上时不往里送；挂上那一刻用影子 SwiftTerm 的快照
/// （`snapshotSequence`，以 RIS 开头）把它对齐到当前画面，之后再逐批转发。快照只能在解析边界上拍
/// （`isAtSnapshotBoundary`），不在边界就等下一批字节喂完再试。
@MainActor
final class GhosttyTerminalBridge {
    let view: GhosttySurfaceView
    let io: InMemoryTerminalSession
    private weak var owner: TerminalSession?
    private let delegate = DelegateProxy()

    /// surface 已经挂上、并且已经用快照对齐过：之后的字节逐批转发。
    private(set) var isLive = false
    private var surfaceAttached = false
    /// Ghostty 最近报告的网格。
    private(set) var grid: (cols: Int, rows: Int)?
    /// 测试 / 探针用：Ghostty 发往后端的全部字节（键盘与应答）都经过这里。
    var onWriteForTesting: (@MainActor (Data) -> Void)?
    /// 测试用：收到快照对齐时调用。
    private(set) var seedCount = 0

    init(owner: TerminalSession) {
        self.owner = owner
        // write / resize 由 Ghostty 在任意线程回调。主队列是 FIFO，键入与应答的先后顺序不会乱。
        let box = WeakBox()
        io = InMemoryTerminalSession(
            write: { data in
                DispatchQueue.main.async { MainActor.assumeIsolated { box.bridge?.ghosttyDidWrite(data) } }
            },
            resize: { viewport in
                let cols = Int(viewport.columns), rows = Int(viewport.rows)
                DispatchQueue.main.async { MainActor.assumeIsolated { box.bridge?.ghosttyDidResize(cols: cols, rows: rows) } }
            },
            // 只有行列数要发给远端（SIGWINCH）；像素级变化不用。
            suppressesPixelOnlyResizes: true)
        view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        box.bridge = self
        delegate.bridge = self
        view.delegate = delegate
        view.controller = GhosttyTerminalConfig.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io))
        view.onFocusGained = { [weak self] in self?.owner?.acknowledgeProgramStatus() }
        view.onPasteImage = { [weak self] in self?.owner?.pasteImage($0) ?? false }
        view.onControlVImage = { [weak self] in self?.owner?.handleControlVImage($0) ?? false }
        view.onControlReturn = { [weak self] in
            // 程序没开 kitty 键盘协议时发回车（同 `CopyableTerminalView`）；开了就让 Ghostty 自己编带修饰键的序列。
            // 协议开没开看影子 SwiftTerm（吃的是同一份字节）。
            guard let owner = self?.owner, owner.terminalView.getTerminal().keyboardEnhancementFlags.isEmpty else { return false }
            owner.sendHostBytes(Data(EscapeSequences.cmdRet))
            return true
        }
    }

    /// 用户此刻在看这个终端：同 SwiftTerm 路径的 `isUserLooking`，只是焦点看 Ghostty 视图。
    var isFocusedInWindow: Bool {
        guard let window = view.window else { return false }
        return window.isKeyWindow && window.firstResponder === view
    }

    // MARK: 字节入

    /// 影子 SwiftTerm 收到过内容没有（输出泵喂过，或 `clearOutput` / held 回放直接写过）。
    private var shadowHasContent = false

    /// 影子 SwiftTerm 刚喂完的一批字节。
    func didFeedShadow(_ bytes: ArraySlice<UInt8>) {
        shadowHasContent = true
        if isLive {
            io.receive(Data(bytes))
        } else if surfaceAttached {
            seedIfPossible()
        }
    }

    /// 不经过输出泵、直接写进影子的字节（`clearOutput`、held 回放）之后调：重新对齐。
    func resync() {
        shadowHasContent = true
        realign()
    }

    private func realign() {
        isLive = false
        if surfaceAttached { seedIfPossible() }
    }

    private func seedIfPossible() {
        // 影子还是空的（新开的标签，一个字节都没来过）：没有画面可对齐，直接开始转发。
        // 这时拍快照会把影子的整屏空行写进去；surface 刚挂上时网格还没停稳（常常先报一个偏小的尺寸），
        // 多出来的空行被挤进回滚，新标签往上滚就是一屏空白。
        guard shadowHasContent else {
            isLive = true
            return
        }
        guard let terminal = owner?.terminalView.getTerminal(), terminal.isAtSnapshotBoundary else { return }
        io.receive(Data(terminal.snapshotSequence(scrollbackLimit: terminal.options.scrollback)))
        seedCount += 1
        isLive = true
    }

    fileprivate func surfaceDidAttach() {
        surfaceAttached = true
        realign()
    }

    fileprivate func surfaceDidDetach() {
        surfaceAttached = false
        isLive = false
    }

    // MARK: 输入出 / 尺寸

    private func ghosttyDidWrite(_ data: Data) {
        onWriteForTesting?(data)
        owner?.sendHostBytes(data)
    }

    private func ghosttyDidResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        grid = (cols, rows)
        owner?.ghosttyGridDidChange(cols: cols, rows: rows)
        // surface 还没建好时就来了接管：现在有格子尺寸了，补上。
        if let pending = pendingPin, view.pinnedFrameSize == nil { pinGrid(cols: pending.cols, rows: pending.rows) }
    }

    // MARK: 远控接管尺寸

    /// 还没法钉（surface 没建好、量不到格子尺寸）时记下的目标。
    private var pendingPin: (cols: Int, rows: Int)?

    /// 把 Ghostty 视图钉成 `cols × rows`：Ghostty 没有内留白（配置里 padding 是 0），网格 = ⌊视图像素 ÷ 格子像素⌋，
    /// 所以视图取「行列数 × 格子像素 ÷ 屏幕倍率」正好是那个行列数，不用像 SwiftTerm 那样试探。
    /// 之后 Ghostty 报来新网格（`ghosttyDidResize`），影子 SwiftTerm、PTY、镜像都跟着走。
    func pinGrid(cols: Int, rows: Int) {
        pendingPin = (cols, rows)
        guard let cell = view.uTermCellPixels else { return }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        view.pinnedFrameSize = NSSize(width: CGFloat(cols) * cell.width / scale, height: CGFloat(rows) * cell.height / scale)
        view.pinnedCursorRow = cursorRow
        view.superview?.needsLayout = true
    }

    func unpinGrid() {
        pendingPin = nil
        guard view.pinnedFrameSize != nil else { return }
        view.pinnedFrameSize = nil
        view.pinnedCursorRow = nil
        if let container = view.superview {
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
    }

    /// 光标在屏幕第几行（看影子 SwiftTerm：吃的是同一份字节）。
    private var cursorRow: Int? { owner?.terminalView.getTerminal().getCursorLocation().y }

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

    private final class WeakBox: @unchecked Sendable {
        weak var bridge: GhosttyTerminalBridge?
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

        func terminalDidChangeTitle(_ title: String) {
            // 影子 SwiftTerm 也会报同一个标题；`receiveShellTitle` 去重。
            bridge?.owner?.receiveShellTitle(title)
        }

        func terminalDidChangeFocus(_ focused: Bool) {
            if focused { bridge?.owner?.acknowledgeProgramStatus() }
        }

        func terminalDidAttachSurface(_ surface: TerminalSurface) { bridge?.surfaceDidAttach() }
        func terminalDidDetachSurface() { bridge?.surfaceDidDetach() }

        /// OSC 7。SwiftTerm 路径也没用它（cwd 靠后端轮询），这里同样不接。
        func terminalDidChangeWorkingDirectory(_ path: String) {}

        /// 影子 SwiftTerm 已经响过铃（SwiftTerm 的默认 `bell` 是 `NSSound.beep()`），这里不重复。
        func terminalDidRingBell() {}

        /// 不安全粘贴（多行 / 带控制字符）与受保护的 OSC 52。SwiftTerm 路径没有粘贴保护，这里先照放行处理，
        /// 真要上线应换成 uTerm 自己的确认框。
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
    /// 开关打开时由 `GhosttyHostView` 调：建好（或拿回）这条会话的 Ghostty 视图。
    @discardableResult
    func enableGhostty() -> GhosttyTerminalBridge {
        if let ghostty { return ghostty }
        let bridge = GhosttyTerminalBridge(owner: self)
        ghostty = bridge
        return bridge
    }

    /// 回到 SwiftTerm 渲染。SwiftTerm 视图下次挂上时按自己的尺寸重排、重报尺寸。
    func disableGhostty() {
        guard let ghostty else { return }
        ghostty.dispose()
        self.ghostty = nil
    }

    /// Ghostty 的网格变了：影子 SwiftTerm 跟到同一个尺寸（快照、读屏、镜像都按它），远端随之 SIGWINCH。
    func ghosttyGridDidChange(cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        if terminal.cols != cols || terminal.rows != rows {
            terminal.resize(cols: cols, rows: rows)
            mirrorTap.invalidateAll()
            heldCheckpoints?.noteScreenChanged()
        }
        inputChannel.reportSize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
    }
}
