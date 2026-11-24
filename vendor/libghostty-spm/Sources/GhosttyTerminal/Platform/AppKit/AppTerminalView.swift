//
//  AppTerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import DisplayLink
    import GhosttyKit

    @MainActor
    open class AppTerminalView: NSView {
        let core = TerminalSurfaceCoordinator()
        var metalLayer: CAMetalLayer?
        var inputHandler: TerminalKeyEventHandler?

        // Grouped view state, one struct per concern — same convention as
        // the UIKit twin: each state type is defined in the extension file
        // that owns the behavior (+Input, +Lifecycle); the storage lives
        // here because extensions cannot add stored properties.
        var keyEcho: KeyEchoState = .init()
        var pointer: PointerSelectionState = .init()
        var focusBridge: FocusBridgeState = .init()
        var drop: DropState = .init()
        var directTouch: DirectTouchState = .init()
        /// uTerm 本地补丁：宿主放掉了 surface（`uTermReleaseSurface()`），回窗口、布局都不自己重建。
        var uTermSurfaceReleased = false
        /// uTerm 本地补丁：把所在显示器报给引擎的记录（见 AppTerminalView+DisplayID.swift）。
        var displayReport: DisplayReportState = .init()

        open weak var delegate: (any TerminalSurfaceViewDelegate)? {
            get { core.delegate }
            set { core.delegate = newValue }
        }

        open var controller: TerminalController? {
            get { core.controller }
            set { core.controller = newValue }
        }

        open var configuration: TerminalSurfaceOptions {
            get { core.configuration }
            set { core.configuration = newValue }
        }

        open func setSurfaceVisible(_ visible: Bool) {
            core.setDisplayVisible(visible)
        }

        /// Adjusts this surface's resize coalescing window without rebuilding
        /// it. Overrides `TerminalSurfaceOptions.resizeThrottleMilliseconds`,
        /// which is the declarative home for the same policy and the one every
        /// platform can reach; pass `nil` to fall back to it.
        open func setResizeThrottle(milliseconds: Double?) {
            core.resizeThrottleInterval = milliseconds.map { max(0, $0) / 1000 }
        }

        var surface: TerminalSurface? {
            core.surface
        }

        override public init(frame: NSRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func commonInit() {
            wantsLayer = true

            let metal = CAMetalLayer()
            metal.device = MTLCreateSystemDefaultDevice()
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            metal.isOpaque = false
            metal.backgroundColor = NSColor.clear.cgColor
            layer = metal
            metalLayer = metal
            layer?.backgroundColor = NSColor.clear.cgColor

            inputHandler = TerminalKeyEventHandler(view: self)
            setupTrackingArea()
            setupDropInput()
            setupDirectTouchInput()

            // uTerm 本地补丁：放掉 surface 期间不算挂着（不自己重建）。
            core.isAttached = { [weak self] in
                guard let self else { return false }
                return window != nil && !uTermSurfaceReleased
            }
            core.displayLinkContext = .view(self)
            // uTerm 本地补丁：上游这里设的是它那份协调器的 `wakeupSkipsDraw`。我们的协调器（补丁第 2、20 条）里同一件事叫
            // `wakeupDefersSyncDraw`：手指在触控屏上拖着或滑行时，引擎 wakeup 的 tick 不 refresh（欠着，停下后补）。
            // Mac 上 wakeup 本来就不同步重画（`wakeupDrawsSynchronously`），所以这里多出来的只有「不 refresh」；
            // 没有触控屏的 Mac 上 `directTouchIsScrolling` 恒为 false，行为不变。
            core.wakeupDefersSyncDraw = { [weak self] in
                self?.directTouchIsScrolling ?? false
            }
            core.scaleFactor = { [weak self] in
                self?.currentScaleFactor() ?? 2.0
            }
            core.viewSize = { [weak self] in
                guard let self else { return (0, 0) }
                return (bounds.width, bounds.height)
            }
            core.platformSetup = { [weak self] config in
                guard let self else { return }
                config.platform_tag = GHOSTTY_PLATFORM_MACOS
                config.platform = ghostty_platform_u(
                    macos: ghostty_platform_macos_s(
                        nsview: Unmanaged.passUnretained(self).toOpaque(),
                    ),
                )
            }
            core.onMetricsUpdate = { [weak self] in
                self?.updateMetalLayerMetrics()
            }
            core.onPostRender = { [weak self] in
                self?.enforceMetalLayerScale()
            }
        }

        /// Upstream's rule: Copy is offered whenever ghostty has a selection.
        /// A cached drag rect went stale on scroll and select_all, and the
        /// quicklook-word test misses whitespace inside a selection.
        open func selectionMenuPoint(at point: CGPoint) -> CGPoint? {
            guard surface?.hasSelection() == true else {
                TerminalDebugLog.log(
                    .input,
                    "selection menu miss point=\(selectionPointDescription(point))",
                )
                return nil
            }

            TerminalDebugLog.log(
                .input,
                "selection menu hit point=\(selectionPointDescription(point))",
            )
            return point
        }

        open func selectionContextMenu() -> NSMenu {
            let menu = NSMenu()
            let copyItem = NSMenuItem(
                title: String(localized: "Copy", bundle: .ghosttyTerminal),
                action: #selector(copy(_:)),
                keyEquivalent: "",
            )
            copyItem.target = self
            menu.addItem(copyItem)
            return menu
        }

        @discardableResult
        open func copySelectedTextToPasteboard() -> Bool {
            guard surface?.hasSelection() == true else {
                return false
            }
            guard surface?.performBindingAction("copy_to_clipboard") == true else {
                return false
            }
            TerminalDebugLog.log(
                .input,
                "selection copied to clipboard",
            )
            return true
        }

        private func selectionPointDescription(_ point: CGPoint) -> String {
            "\(String(format: "%.2f", point.x))x\(String(format: "%.2f", point.y))"
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif
