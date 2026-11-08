import AppKit
import GhosttyTerminal
import SwiftUI

/// `TerminalHostView` 的 Ghostty 版（试验开关 `DefaultsKey.terminalGhosttyRenderer`）。
///
/// 只接了一条路径：挂载、焦点、内边距、深浅色、光标 / 历史 / 选中即复制设置。没接：远控钉尺寸
/// （`pinnedFrameSize`）、「停稳再提交」的尺寸判定（Ghostty 自己有 `resizeThrottleMilliseconds`）、
/// 滚动转发给外层 ScrollView、自绘滚动条。
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
        let bridge = session.enableGhostty()
        apply()
        let container = GhosttyContainerView(surface: bridge.view)
        container.identifier = .utermTerminalRegion
        container.isActive = isActive
        return container
    }

    func updateNSView(_ nsView: GhosttyContainerView, context: Context) {
        let bridge = session.enableGhostty()
        nsView.attach(bridge.view)
        nsView.isActive = isActive
        apply()
    }

    private func apply() {
        let dark = appColorScheme == .dark
        GhosttyTerminalBridge.applyAppearance(dark: dark)
        GhosttyTerminalBridge.apply(settings: settings)
    }

    static func dismantleNSView(_ nsView: GhosttyContainerView, coordinator: ()) {
        nsView.detachSurface()
        nsView.removeFromSuperview()
    }
}

/// 摆放 Ghostty 视图：同 `TerminalContainerView` 的内边距，焦点规则同 `TerminalContainerView.canTakeFocus`。
final class GhosttyContainerView: NSView {
    private static let insets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
    private weak var surface: GhosttySurfaceView?

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
        surface.removeFromSuperview()
        self.surface = surface
        addSubview(surface)
        needsLayout = true
        requestFocus()
    }

    func detachSurface() {
        if surface?.superview === self { surface?.removeFromSuperview() }
        surface = nil
    }

    override func layout() {
        super.layout()
        guard let surface, surface.superview === self else { return }
        let i = Self.insets
        let frame = NSRect(x: i.left, y: i.bottom,
                           width: max(0, bounds.width - i.left - i.right),
                           height: max(0, bounds.height - i.top - i.bottom))
        if surface.frame != frame { surface.frame = frame }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus()
    }

    private func requestFocus() {
        guard isActive, window != nil else { return }
        Task { [weak self] in
            guard let self, self.isActive, let window = self.window, let surface = self.surface,
                  surface.superview === self,
                  window.firstResponder is GhosttySurfaceView
                    || TerminalContainerView.canTakeFocus(from: window.firstResponder) else { return }
            window.makeFirstResponder(surface)
        }
    }
}
