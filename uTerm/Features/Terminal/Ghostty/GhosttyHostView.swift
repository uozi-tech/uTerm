import AppKit
import GhosttyTerminal
import SwiftUI

/// 把会话的 Ghostty 视图（`TerminalSession.ghostty.view`，会话持有、不随 SwiftUI 重建）挂进 SwiftUI。
///
/// 接了：挂载、焦点、内边距、深浅色、光标 / 历史 / 选中即复制设置、远控钉尺寸（`pinnedFrameSize`）、
/// 「停稳再提交」的尺寸判定、滚动时浮现的滚动条。没接：滚动转发给外层 ScrollView、拖动滚动条。
struct GhosttyHostView: NSViewRepresentable {
    let session: TerminalSession
    var isActive = true

    @AppStorage(DefaultsKey.terminalCursorShape)  private var cursorShapeRaw: String = TerminalCursorShape.block.rawValue
    @AppStorage(DefaultsKey.terminalCursorBlink)  private var cursorBlink: Bool = false
    @AppStorage(DefaultsKey.terminalScrollback)   private var scrollback: Int = 3_000
    @AppStorage(DefaultsKey.terminalCopyOnSelect) private var copyOnSelect: Bool = false
    @Environment(\.colorScheme) private var appColorScheme

    private var settings: TerminalSettings {
        TerminalSettings(cursorShape: TerminalCursorShape(rawValue: cursorShapeRaw) ?? .block,
                         cursorBlink: cursorBlink, scrollback: scrollback, copyOnSelect: copyOnSelect)
    }

    func makeNSView(context: Context) -> GhosttyContainerView {
        apply()
        let container = GhosttyContainerView(surface: session.ghostty.view)
        container.identifier = .utermTerminalRegion
        container.isActive = isActive
        return container
    }

    func updateNSView(_ nsView: GhosttyContainerView, context: Context) {
        nsView.attach(session.ghostty.view)
        nsView.isActive = isActive
        apply()
    }

    private func apply() {
        let dark = appColorScheme == .dark
        session.updateShadowColors(dark: dark)
        GhosttyTerminalBridge.applyAppearance(dark: dark)
        GhosttyTerminalBridge.apply(settings: settings)
    }

    static func dismantleNSView(_ nsView: GhosttyContainerView, coordinator: ()) {
        nsView.detachSurface()
        nsView.removeFromSuperview()
    }
}

/// 摆放 Ghostty 视图：留内边距、远控钉尺寸时按 `pinnedFrame` 摆、成为活动面板时把键盘焦点交给终端。
final class GhosttyContainerView: NSView {
    /// 顶边 0：终端凹槽紧贴在 40pt 标签条下方，条里 26pt 胶囊上下已各留 7pt。默认配色的终端底与卡面同色
    /// （凹槽看不出边），再加内边距就成了「胶囊上 7、下 14」的不对称间距（实机反馈）。左右与底边保留，避开凹槽圆角。
    static let insets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
    private weak var surface: GhosttySurfaceView?
    /// 滚动条：Ghostty 自己不画，按它报的总行数 / 视口位置自绘。只在用户滚动、且确有历史可滚时浮现，
    /// 停手约 1 s 后淡出。只显示，不能拖。
    let scrollIndicator = GhosttyScrollIndicator()
    /// 「停稳再提交」的判定与顺延计时（与 iOS 的容器共用）。
    private let settler = TerminalResizeSettler()
    private var lastScrollbar: TerminalScrollbar?
    private var hideIndicatorWork: DispatchWorkItem?

    var isActive = false {
        didSet { if isActive, !oldValue { requestFocus() } }
    }

    init(surface: GhosttySurfaceView) {
        super.init(frame: .zero)
        wantsLayer = true
        attach(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ surface: GhosttySurfaceView) {
        guard self.surface !== surface else { return }
        self.surface?.removeFromSuperview()
        self.surface?.onScrollbar = nil
        self.surface?.onScrollActivity = nil
        surface.removeFromSuperview()
        self.surface = surface
        settler.cancel()
        // 进窗口的那一刻 surface 可能当场建好并按视图此刻的尺寸报网格；容器还没量过，先不让它发给 PTY。
        surface.holdsGridReports = true
        addSubview(surface)
        addSubview(scrollIndicator, positioned: .above, relativeTo: surface)
        surface.onScrollbar = { [weak self] in self?.scrollbarDidChange($0) }
        surface.onScrollActivity = { [weak self] in self?.revealScrollIndicator() }
        needsLayout = true
        requestFocus()
    }

    func detachSurface() {
        if surface?.superview === self { surface?.removeFromSuperview() }
        surface = nil
        settler.cancel()
    }

    override func layout() {
        super.layout()
        syncSurfaceFrame(settled: false)
    }

    /// 把 Ghostty 视图的尺寸对齐到容器。视图尺寸一变 Ghostty 就立刻按新网格重排，而程序要等 SIGWINCH 才知道；
    /// 首次挂载、重启接回、窗口还在定尺寸、分屏还在排的时候，量到的常常只是中间态——把它发给 PTY，正在跑的全屏程序
    /// （接回的 Claude Code）就按一个很窄的列宽把历史重排一遍，之后尺寸对了也只重画活动区。所以尺寸停稳才提交
    /// （判定在共享的 `TerminalResizeSettler`）：等待期间视图保持旧尺寸、网格不动，提交时 Ghostty 的网格、影子终端、
    /// PTY 一起变。等待期间 surface 自己报来的网格（刚建好时按当时的视图尺寸报的那一次）也不发给 PTY
    /// （`GhosttySurfaceView.holdsGridReports`），提交之后只发最终那一次。
    private func syncSurfaceFrame(settled: Bool) {
        // SwiftUI 可能晚于新容器才拆掉旧容器；已被接走的视图不归这里摆放。
        guard let surface, surface.superview === self else { return }
        let i = Self.insets
        // 远控接管尺寸：按对端的行列数钉住，不缩放，放不下的部分裁掉；比窗格高时跟着光标走。目标是确定的，直接提交。
        if let pinned = surface.pinnedFrameSize {
            settler.cancel()
            layer?.masksToBounds = true
            let rows = pinned.height > 0 ? Int((pinned.height / max(1, cellHeightPoints(surface))).rounded()) : 0
            let frame = Self.pinnedFrame(pinned, in: bounds, insets: i, cursorRow: surface.pinnedCursorRow, rows: rows)
            if surface.frame != frame { surface.frame = frame }
            surface.resizeDidSettle()
            layoutScrollIndicator()
            return
        }
        let width = bounds.width - i.left - i.right
        let height = bounds.height - i.top - i.bottom
        // 窗格被收起时没有可用空间：保持原有行列数，等它再露出来。
        guard width > 0, height > 0 else {
            settler.cancel()
            return
        }
        let target = NSRect(x: i.left, y: i.bottom, width: width, height: height)
        let decision = settler.decide(
            target: TerminalResizeSettler.Target(size: target.size),
            current: TerminalResizeSettler.Target(size: surface.frame.size),
            // 挂上时 pty 已经有尺寸、程序已经在画（接回的 Claude Code 等），首次挂载也是一次尺寸变化，和平时一样等停稳。
            isFirstMount: false,
            settled: settled,
            onSettled: { [weak self] in self?.syncSurfaceFrame(settled: true) })
        switch decision {
        case .cancel:
            return  // 只在没有目标时出现，上面已经处理过
        case .commit:
            layer?.masksToBounds = false
            if surface.frame != target { surface.frame = target }
            surface.resizeDidSettle()
        case .hold:
            // 等待期间保持旧尺寸，贴左上角摆放，放不下的部分裁掉；这期间报来的网格先不发给 PTY。
            surface.holdsGridReports = true
            layer?.masksToBounds = true
            surface.setFrameOrigin(Self.pinnedFrame(surface.frame.size, in: bounds, insets: i).origin)
        }
        layoutScrollIndicator()
    }

    private func cellHeightPoints(_ surface: GhosttySurfaceView) -> CGFloat {
        guard let cell = surface.uTermCellPixels else { return 1 }
        return cell.height / (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: 滚动条

    private func scrollbarDidChange(_ scrollbar: TerminalScrollbar) {
        lastScrollbar = scrollbar
        layoutScrollIndicator()
    }

    /// 滑块的位置：轨道是终端视图露在窗格里的那一段的右边缘；滑块高度按「一屏 ÷ 总行数」，最矮 24pt。
    private func layoutScrollIndicator() {
        guard let surface, let bar = lastScrollbar, bar.total > bar.len else {
            scrollIndicator.isHidden = true
            return
        }
        scrollIndicator.isHidden = false
        let track = surface.frame.intersection(bounds)
        let knob = max(24, track.height * CGFloat(bar.len) / CGFloat(bar.total))
        let travel = max(0, track.height - knob)
        let progress = CGFloat(bar.offset) / CGFloat(bar.total - bar.len)   // 0 = 回滚顶部，1 = 活动区
        // 容器不翻转：顶部在 maxY。
        let frame = NSRect(x: bounds.maxX - 9, y: track.maxY - knob - travel * progress, width: 6, height: knob)
        if scrollIndicator.frame != frame { scrollIndicator.frame = frame }
    }

    /// 用户滚了一下：有历史可滚就让滚动条浮现，停手 1 s 后淡出。
    private func revealScrollIndicator() {
        guard let bar = lastScrollbar, bar.total > bar.len else { return }
        hideIndicatorWork?.cancel()
        scrollIndicator.setShown(true)
        let work = DispatchWorkItem { [weak self] in self?.scrollIndicator.setShown(false) }
        hideIndicatorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus()
    }

    /// 连接可能晚于用户的操作才完成，这时终端才挂载，不能打断正在输入的 Agent 框、编辑器或正在
    /// 浏览的文件列表。其它终端除外：切标签时旧终端可能还没卸载，它的焦点就是要交过来的。
    static func canTakeFocus(from responder: NSResponder?) -> Bool {
        if responder is GhosttySurfaceView { return true }
        return !(responder is NSTextInputClient || responder is NSTableView)
    }

    /// 钉住的终端比窗格高时，光标那一行往下还要留在窗格里的行数（Claude Code 的输入框下面有一条边线和一两行状态）。
    static let pinnedRowsKeptBelowCursor = 3

    /// 钉住尺寸的终端摆在哪：放得下就贴左上角；比窗格高时跟着光标走——从顶上裁，裁到光标那一行
    ///（再往下留 `pinnedRowsKeptBelowCursor` 行）刚好落在窗格里为止，最多裁到底边贴着窗格底。
    ///
    /// 手机竖屏的行数常比 Mac 窗格多。一律贴顶会把屏幕底部正在打字的那一行裁掉；一律贴底（之前的做法）则在
    /// 屏幕没写满时裁错地方：程序刚起来、刚清过屏，内容都在屏幕顶上、下面是空行，留在窗格里的反而是一屏空白，
    /// 看着像被接管状态条挡住了。裁掉的量取整到整行，窗格顶上不留半行。
    ///
    /// 不传 `cursorRow` 时按光标在最后一行算（贴底）。
    static func pinnedFrame(_ pinned: NSSize, in bounds: NSRect, insets: NSEdgeInsets,
                            cursorRow: Int? = nil, rows: Int = 0) -> NSRect {
        let available = bounds.height - insets.top - insets.bottom
        // 贴顶时的位置（容器不翻转，y 往上）。
        var y = bounds.height - insets.top - pinned.height
        if pinned.height > available {
            let maxCut = pinned.height - available
            var cut = maxCut
            if let cursorRow, rows > 0 {
                let rowHeight = pinned.height / CGFloat(rows)
                let keepBottom = min(pinned.height, CGFloat(cursorRow + 1 + pinnedRowsKeptBelowCursor) * rowHeight)
                cut = min(maxCut, (max(0, keepBottom - available) / rowHeight).rounded(.up) * rowHeight)
            }
            y += cut
        }
        return NSRect(x: insets.left, y: y, width: pinned.width, height: pinned.height)
    }

    private func requestFocus() {
        guard isActive, window != nil else { return }
        Task { [weak self] in
            guard let self, self.isActive, let window = self.window, let surface = self.surface,
                  surface.superview === self,
                  Self.canTakeFocus(from: window.firstResponder) else { return }
            window.makeFirstResponder(surface)
        }
    }
}

/// Ghostty 窗格的滚动条滑块：一条半透明的圆角条，不接鼠标。
final class GhosttyScrollIndicator: NSView {
    private(set) var isShown = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        alphaValue = 0
        updateColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.42).cgColor
        }
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.12 : 0.3
            animator().alphaValue = shown ? 1 : 0
        }
    }
}
