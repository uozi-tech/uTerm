import SwiftUI
import AppKit
import SwiftTerm

/// Reusable `NSViewRepresentable` that mounts a pre-existing
/// `SwiftTerm.TerminalView` (owned by `TerminalSession`) into the SwiftUI
/// hierarchy. The NSView is intentionally reused so the scrollback buffer
/// persists across SwiftUI view rebuilds (e.g. maximize / restore).
///
/// `TerminalTheme.apply` configures THIS view's CALayer to round only its
/// *bottom* corners (radius 8); this is purely cosmetic so the terminal sits
/// flush under the header (square top) and matches the pane card's rounded
/// bottom (no visible seam).
struct TerminalHostView: NSViewRepresentable {
    let terminalView: SwiftTerm.TerminalView
    var forwardsScrollToParent = false
    /// 这个终端是不是当前该接收键盘输入的那一个，见 `TerminalContainerView.isActive`。
    var isActive = true

    @AppStorage("terminalCursorShape")  private var cursorShapeRaw: String = TerminalCursorShape.block.rawValue
    @AppStorage("terminalCursorBlink")  private var cursorBlink: Bool = false
    /// Small live scrollback as a per-pane memory bound.
    /// 3000 lines ≈ 5MB/pane vs 24MB at 10k — meaningful win at 6 panes.
    @AppStorage("terminalScrollback")   private var scrollback: Int = 3_000
    @AppStorage("terminalCopyOnSelect") private var copyOnSelect: Bool = false

    /// app 主题（解钉后即工作区/SFTP 窗口的外观）。变化会触发 updateNSView 重 apply。
    @Environment(\.colorScheme) private var appColorScheme

    private var currentSettings: TerminalSettings {
        TerminalSettings(
            cursorShape: TerminalCursorShape(rawValue: cursorShapeRaw) ?? .block,
            cursorBlink: cursorBlink,
            scrollback: scrollback,
            copyOnSelect: copyOnSelect
        )
    }

    func makeNSView(context: Context) -> TerminalContainerView {
        let dark = appColorScheme == .dark
        (terminalView as? CopyableTerminalView)?.copyOnSelect = copyOnSelect
        TerminalTheme.apply(to: terminalView, settings: currentSettings, dark: dark)
        let container = TerminalContainerView(
            terminalView: terminalView,
            forwardsScrollToParent: forwardsScrollToParent
        )
        container.identifier = .utermTerminalRegion   // ⌘W 焦点判定标记
        container.isActive = isActive
        container.layer?.backgroundColor = currentSettings.colorScheme(dark: dark).backgroundColor.cgColor
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        let dark = appColorScheme == .dark
        nsView.forwardsScrollToParent = forwardsScrollToParent
        (terminalView as? CopyableTerminalView)?.copyOnSelect = copyOnSelect
        nsView.attach(terminalView)
        nsView.isActive = isActive
        nsView.layer?.backgroundColor = currentSettings.colorScheme(dark: dark).backgroundColor.cgColor
        TerminalTheme.apply(to: terminalView, settings: currentSettings, dark: dark)
    }

    static func dismantleNSView(_ nsView: TerminalContainerView, coordinator: ()) {
        // Detach from the wrapper NSHostingView SwiftUI is about to tear down.
        // The terminalView itself stays alive (owned by TerminalSession), but
        // leaving it parented to a doomed NSHostingView causes ghost
        // renderings when AppKit reflows views during screen reconfiguration
        // (external display attach, DPI / resolution change) — the old
        // hosting view's compositor cache may still display the layer at
        // its previous frame on the previous screen.
        nsView.detachTerminal()
        nsView.removeFromSuperview()
    }
}

final class TerminalContainerView: NSView {
    /// 顶边 0：终端凹槽紧贴在 40pt 标签条下方，条里 26pt 胶囊上下已各留 7pt。默认配色的
    /// 终端底与卡面同色（凹槽看不出边），再加 6pt 内边距就成了「胶囊上 7、下 14」的不对称
    /// 间距（实机反馈）。左右与底边保留，避开凹槽圆角。
    private static let terminalInsets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
    /// 尺寸停止变化多久后才提交给终端。连续拖动期间不断顺延。
    static let settleDelay: Duration = .milliseconds(80)
    /// 查看方式：`log stream --level debug --predicate 'subsystem == "com.uozi.uTerm" AND category == "terminal-resize"'`
    /// （还要把设置里的日志级别调到 debug）。
    private static let logCategory = "terminal-resize"

    var forwardsScrollToParent: Bool {
        didSet {
            updateScrollForwardingMonitor()
        }
    }
    private weak var terminalView: SwiftTerm.TerminalView?
    /// `nonisolated(unsafe)` so `deinit` (itself nonisolated) can release the
    /// monitor. Safe: the monitor is only mutated from the MainActor while the
    /// view is alive, and `deinit` has exclusive access once it runs.
    private nonisolated(unsafe) var scrollForwardingMonitor: Any?
    /// 正在等待停稳的目标尺寸；nil = 没有在等。
    private var heldSize: NSSize?
    private var settleTask: Task<Void, Never>?
    /// 成为活动面板时把键盘焦点交给终端：切标签会重新挂载终端视图，焦点不会自己跟过来。
    var isActive = false {
        didSet {
            if isActive, !oldValue { requestTerminalFocus() }
        }
    }

    init(terminalView: SwiftTerm.TerminalView,
         forwardsScrollToParent: Bool = false) {
        self.forwardsScrollToParent = forwardsScrollToParent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TerminalTheme.backgroundColor.cgColor
        attach(terminalView)
        updateScrollForwardingMonitor()
    }

    deinit {
        removeScrollForwardingMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func attach(_ terminalView: SwiftTerm.TerminalView) {
        guard self.terminalView !== terminalView else { return }
        cancelHold()
        self.terminalView?.removeFromSuperview()
        terminalView.removeFromSuperview()
        terminalView.autoresizingMask = []
        self.terminalView = terminalView
        addSubview(terminalView)
        needsLayout = true
        requestTerminalFocus()
    }

    func detachTerminal() {
        // Only unparent the shared terminal view if it is *still* ours.
        // SwiftUI can defer this container's `dismantleNSView` until AFTER the
        // next container has already re-adopted the same (TerminalSession-owned)
        // terminal view — this happens on a tab switch away-and-back. Without
        // this guard the stale container rips the live terminal view out of the
        // new container, orphaning it so the pane renders black.
        if terminalView?.superview === self {
            terminalView?.removeFromSuperview()
        }
        terminalView = nil
        cancelHold()
        removeScrollForwardingMonitor()
    }

    override func layout() {
        super.layout()
        syncTerminalFrame(settled: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestTerminalFocus()
    }

    /// 等当前这轮 SwiftUI 更新结束再改焦点：焦点变化可能反过来触发 SwiftUI 的状态更新。
    private func requestTerminalFocus() {
        guard isActive, window != nil else { return }
        Task { [weak self] in self?.takeTerminalFocus() }
    }

    private func takeTerminalFocus() {
        guard isActive, let window, let terminalView, terminalView.superview === self,
              Self.canTakeFocus(from: window.firstResponder) else { return }
        window.makeFirstResponder(terminalView)
    }

    /// 连接可能晚于用户的操作才完成，这时终端才挂载，不能打断正在输入的 Agent 框、编辑器或正在
    /// 浏览的文件列表。其它终端除外：切标签时旧终端可能还没卸载，它的焦点就是要交过来的。
    static func canTakeFocus(from responder: NSResponder?) -> Bool {
        if responder is SwiftTerm.TerminalView { return true }
        return !(responder is NSTextInputClient || responder is NSTableView)
    }

    /// 把终端视图的尺寸对齐到容器。尺寸一变 SwiftTerm 就立刻重排缓冲区，而程序要等 SIGWINCH 才知道，
    /// 这段时间差里它会照旧按旧尺寸增量绘制；尺寸变过去又变回来时 PTY 尺寸没变、连 SIGWINCH 都没有，
    /// 屏幕就一直错位。所以尺寸停稳才提交：重排和 SIGWINCH 同时发生，中途的尺寸不碰缓冲区。
    private func syncTerminalFrame(settled: Bool) {
        // SwiftUI 可能晚于新容器才拆掉旧容器；已被接走的终端不归这里摆放。
        guard let terminalView, terminalView.superview === self else { return }
        let insets = Self.terminalInsets
        let copyable = terminalView as? CopyableTerminalView
        // 远控接管尺寸：终端按对端的行列数钉住，不缩放，放不下的部分裁掉。
        if let pinned = copyable?.pinnedFrameSize {
            cancelHold()
            layer?.masksToBounds = true
            terminalView.frame = Self.pinnedFrame(pinned, in: bounds, insets: insets)
            return
        }
        let width = bounds.width - insets.left - insets.right
        let height = bounds.height - insets.top - insets.bottom
        // 窗格被收起时没有可用空间：保持原有行列数，等它再露出来。
        guard width > 0, height > 0 else {
            cancelHold()
            return
        }
        let target = NSRect(x: insets.left, y: insets.bottom, width: width, height: height)
        let isFirstMount = copyable?.hasHostedLayout == false
        if settled || isFirstMount || terminalView.frame.size == target.size {
            if let heldSize, heldSize != target.size {
                AppLogger.debug("cancelled \(heldSize) -> \(target.size)", category: Self.logCategory)
            }
            cancelHold()
            copyable?.hasHostedLayout = true
            layer?.masksToBounds = false
            terminalView.frame = target
            return
        }
        // 等待期间保持旧尺寸，贴左上角摆放，放不下的部分裁掉。
        layer?.masksToBounds = true
        terminalView.setFrameOrigin(Self.pinnedFrame(terminalView.frame.size, in: bounds, insets: insets).origin)
        guard heldSize != target.size else { return }
        AppLogger.debug("holding \(terminalView.frame.size) -> \(target.size)", category: Self.logCategory)
        heldSize = target.size
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.syncTerminalFrame(settled: true)
        }
    }

    private func cancelHold() {
        settleTask?.cancel()
        settleTask = nil
        heldSize = nil
    }

    /// 钉住尺寸的终端摆在哪：放得下就贴左上角；比窗格高时贴底边，裁掉的是最上面的旧行——
    /// 提示符、光标和最新输出都在底部（手机竖屏的行数常比 Mac 窗格多，贴顶会把正在打字的那一行裁掉）。
    static func pinnedFrame(_ pinned: NSSize, in bounds: NSRect, insets: NSEdgeInsets) -> NSRect {
        let available = bounds.height - insets.top - insets.bottom
        let y = pinned.height <= available ? bounds.height - insets.top - pinned.height : insets.bottom
        return NSRect(x: insets.left, y: y, width: pinned.width, height: pinned.height)
    }

    override func mouseDown(with event: NSEvent) {
        if let terminalView {
            window?.makeFirstResponder(terminalView)
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard forwardsScrollToParent, forwardScrollToParent(event) else {
            super.scrollWheel(with: event)
            return
        }
    }

    private func updateScrollForwardingMonitor() {
        if forwardsScrollToParent {
            guard scrollForwardingMonitor == nil else { return }
            scrollForwardingMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.forwardsScrollToParent else { return event }
                return self.forwardScrollToParent(event) ? nil : event
            }
        } else {
            removeScrollForwardingMonitor()
        }
    }

    /// `nonisolated` because it touches no MainActor state beyond the
    /// `nonisolated(unsafe)` monitor handle — `NSEvent.removeMonitor` is
    /// callable from any thread. This lets `deinit` invoke it directly.
    private nonisolated func removeScrollForwardingMonitor() {
        if let scrollForwardingMonitor {
            NSEvent.removeMonitor(scrollForwardingMonitor)
            self.scrollForwardingMonitor = nil
        }
    }

    private func forwardScrollToParent(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint) else { return false }
        guard let scrollView = enclosingScrollView() else { return false }
        scrollView.scrollWheel(with: event)
        return true
    }

    private func enclosingScrollView() -> NSScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }
}
