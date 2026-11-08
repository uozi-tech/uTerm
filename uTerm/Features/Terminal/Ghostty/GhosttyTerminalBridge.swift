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
    }

    /// 用户此刻在看这个终端：同 SwiftTerm 路径的 `isUserLooking`，只是焦点看 Ghostty 视图。
    var isFocusedInWindow: Bool {
        guard let window = view.window else { return false }
        return window.isKeyWindow && window.firstResponder === view
    }

    // MARK: 字节入

    /// 影子 SwiftTerm 刚喂完的一批字节。
    func didFeedShadow(_ bytes: ArraySlice<UInt8>) {
        if isLive {
            io.receive(Data(bytes))
        } else if surfaceAttached {
            seedIfPossible()
        }
    }

    /// 不经过输出泵、直接写进影子的字节（`clearOutput`、held 回放）之后调：重新对齐。
    func resync() {
        isLive = false
        if surfaceAttached { seedIfPossible() }
    }

    private func seedIfPossible() {
        guard let terminal = owner?.terminalView.getTerminal(), terminal.isAtSnapshotBoundary else { return }
        io.receive(Data(terminal.snapshotSequence(scrollbackLimit: terminal.options.scrollback)))
        seedCount += 1
        isLive = true
    }

    fileprivate func surfaceDidAttach() {
        surfaceAttached = true
        resync()
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
    }

    // MARK: 外观

    /// app 外观变了：Ghostty 按 theme 里的深 / 浅两套切。
    static func applyAppearance(dark: Bool) {
        GhosttyTerminalConfig.controller.setColorScheme(dark ? .dark : .light)
    }

    /// 字体 / 光标 / 历史这类设置变了（整份配置重载，所有 Ghostty 窗格一起生效）。
    static func apply(settings: TerminalSettings) {
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
        TerminalSurfaceClipboardConfirmationDelegate, TerminalSurfaceBellDelegate {
        weak var bridge: GhosttyTerminalBridge?

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

/// uTerm 的 Ghostty 视图子类：焦点回到终端、只有图片的剪贴板（⌘V / ⌃V），与 `CopyableTerminalView` 同语义。
final class GhosttySurfaceView: AppTerminalView {
    var onFocusGained: (@MainActor () -> Void)?
    var onPasteImage: (@MainActor (TerminalImage) -> Bool)?
    var onControlVImage: (@MainActor (TerminalImage) -> Bool)?
    var pasteboard: NSPasteboard = .general

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
        return super.performKeyEquivalent(with: event)
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
