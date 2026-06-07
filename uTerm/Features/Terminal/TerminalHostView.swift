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
        container.layer?.backgroundColor = currentSettings.colorScheme(dark: dark).backgroundColor.cgColor
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        let dark = appColorScheme == .dark
        nsView.forwardsScrollToParent = forwardsScrollToParent
        (terminalView as? CopyableTerminalView)?.copyOnSelect = copyOnSelect
        nsView.attach(terminalView)
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
    private static let terminalInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

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
        self.terminalView?.removeFromSuperview()
        terminalView.removeFromSuperview()
        terminalView.autoresizingMask = []
        self.terminalView = terminalView
        addSubview(terminalView)
        needsLayout = true
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
        removeScrollForwardingMonitor()
    }

    override func layout() {
        super.layout()
        guard let terminalView else { return }
        let insets = Self.terminalInsets
        terminalView.frame = NSRect(
            x: insets.left,
            y: insets.bottom,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom)
        )
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
