//
//  TerminalSurfaceCoordinator.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import DisplayLink
import Foundation
import GhosttyKit

/// Shared terminal state and logic used by both UIKit and AppKit views.
///
/// Platform views own a `TerminalSurfaceCoordinator` instance and set platform-specific
/// hooks via closures. The core handles surface lifecycle, metrics
/// synchronization, and frame rendering via scheduled wakeups.
@MainActor
final class TerminalSurfaceCoordinator {
    weak var delegate: (any TerminalSurfaceViewDelegate)? {
        didSet { bridge.delegate = delegate }
    }

    var controller: TerminalController? {
        didSet {
            guard controller !== oldValue else { return }
            rebuildIfReady(removingBridgeFrom: oldValue)
        }
    }

    var configuration: TerminalSurfaceOptions = .init() {
        didSet {
            guard !configuration.isEquivalent(to: oldValue) else { return }
            rebuildIfReady()
        }
    }

    var surface: TerminalSurface?
    /// The in-memory session `surface` was handed to at build time. Teardown
    /// must clear that session, not whichever one `configuration` names by
    /// then: a rebuild runs from `configuration`'s didSet, after the property
    /// already holds the new backend, and a swap to another session or to
    /// `.exec` would otherwise free a surface the old session still uses.
    private var surfaceSession: InMemoryTerminalSession?
    let bridge = TerminalCallbackBridge()

    // MARK: - Platform Hooks

    var isAttached: () -> Bool = { false }
    /// Where frames come from. Platform views bind it to themselves, so the
    /// link follows the display their window is on; `.main` serves a
    /// coordinator with no view, as in tests.
    var displayLinkContext: DisplayLinkContext = .main {
        didSet { displayLink?.context = displayLinkContext }
    }

    var scaleFactor: () -> Double = { 2.0 }
    var viewSize: () -> (width: Double, height: Double) = { (0, 0) }
    var platformSetup: ((inout ghostty_surface_config_s) -> Void)?
    var onMetricsUpdate: (() -> Void)?
    var onCellSizeDidChange: (() -> Void)?
    var onMouseShape: ((ghostty_action_mouse_shape_e) -> Void)?
    /// uTerm 本地补丁：surface 建好 / 拆掉、视图按自己的尺寸算出了新网格。和 `TerminalSurfaceLifecycleDelegate` /
    /// `TerminalSurfaceGridResizeDelegate` 同一时刻发出，但不经 delegate：宿主靠它们决定什么时候往 surface 里灌字节，
    /// 不能因为 delegate 被换成别的对象（只关心滚动条、标题的）就收不到。
    var onSurfaceAttached: (() -> Void)?
    var onSurfaceDetached: (() -> Void)?
    var onGridMetrics: ((TerminalGridMetrics) -> Void)?
    /// uTerm 本地补丁：见 `TerminalSurface.sendsCommandChords`；之后建的 surface 也带上。
    var sendsCommandChords: (() -> Bool)? {
        didSet { surface?.sendsCommandChords = sendsCommandChords }
    }
    /// uTerm 本地补丁：surface 一直保持聚焦，不跟着视图的焦点走。Ghostty 的 surface 焦点同时管两件事——失焦时光标画成
    /// 空心框（`renderer/cursor.zig`），以及给开了 DEC 1004 的程序报 focus in / out；iOS 上收起键盘后用户还在看这个终端，
    /// 光标不该变空心（换引擎之前的行为），所以 surface 一直聚焦（新 surface 出生就是聚焦的），1004 由宿主照自己的规则报。
    /// 视图焦点变化仍照常通知 delegate；拆 surface 时也不再先报失焦。默认关（Mac 失焦画空心是对的）。
    var keepsSurfaceFocused = false {
        didSet { if keepsSurfaceFocused { surface?.setFocus(true) } }
    }
    /// uTerm 本地补丁：这个 surface 自己的 `adjust-cell-height`（物理像素），0 = 跟 app 的配置。见
    /// `TerminalSurfaceCoordinator+CellHeight.swift`。surface 重建、app 的配置整份推下来时归 0（新配置里没有这一项）。
    var cellHeightAdjustment = 0
    /// 正在把这个 surface 自己的配置推给它（`ghostty_surface_update_config` 里同步发的 CONFIG_CHANGE 是自己引起的）。
    var isApplyingSurfaceConfig = false

    /// Called after every display-link render (`tick`).
    ///
    /// When `synchronizeMetrics` sends a new pixel size to ghostty via
    /// `setSize`, the underlying IOSurface is not rebuilt synchronously.
    /// Until the next full render pass ghostty still uses the **old**
    /// IOSurface, so it derives an incorrect `contentsScale` for the
    /// IOSurfaceLayer (e.g. old-pixel-height / new-point-height → 4.62
    /// instead of the expected 3.0). This causes a visible "jump" on
    /// every layout change (keyboard show/hide, rotation, color-scheme
    /// toggle, etc.).
    ///
    /// Platform views use this hook to silently enforce the correct
    /// `contentsScale` and `frame` on sublayers after each render,
    /// correcting any drift introduced by ghostty within a single frame.
    var onPostRender: (() -> Void)?

    private var lastMetrics: TerminalViewportMetrics?

    /// The live surface's font size, which Ghostty cannot report; kept by
    /// +FontSize. `nil` while there is no surface, so every build reports
    /// its starting size, to whichever delegate is set by then.
    var fontSize: TerminalFontSize?

    /// The view size, in points, the surface was last sized to. While a
    /// resize throttle window is open this trails the live bounds: the
    /// surface's IOSurface is still the old size, so a platform layer that
    /// stretches to the new bounds shows the old pixels scaled — and the
    /// engine, deriving `contentsScale` from old pixels over new points,
    /// fights the host's correction on every tick. A UIKit host keeps its
    /// sublayer at *this* size until the trailing sync lands, so the gap
    /// shows background instead of a stretched frame. `nil` until the first
    /// sync and after teardown.
    private(set) var syncedViewSize: (width: Double, height: Double)?
    /// The content scale the surface was last sized at. A platform view
    /// falls back to it while its window has no screen, and a scale change
    /// is never held back by the resize throttle.
    private(set) var syncedScale: Double?

    private var isDisplayVisible = true
    /// The last visibility the SwiftUI host declared through
    /// `TerminalViewState.isSurfaceVisible`. The representable forwards only
    /// changes to this value, so an imperative `setSurfaceVisible` call made
    /// between SwiftUI updates is not silently reverted by every refresh
    /// re-stamping the declarative default.
    var hostDeclaredDisplayVisible: Bool?
    /// Whether the platform reports the hosting window as on screen
    /// (AppKit: not minimized, hidden, or fully covered). Kept apart from
    /// `isDisplayVisible` so occlusion never overwrites what the host
    /// declared; the two are ANDed.
    private var isWindowVisible = true
    private var isApplicationActive = true
    private var pendingImmediateTick = true
    /// uTerm 本地补丁：这次 tick 要不要在主线程同步整帧重画（`ghostty_surface_draw` = drawFrame(sync: true)：
    /// 等空闲帧、编码、commit、waitUntilCompleted 等 GPU 画完）。尺寸 / 度量 / 可见性 / 选区这些宿主侧变化要（渲染线程不知道
    /// 它们，或者要同步出帧防拉伸）；引擎的 wakeup 不要：wakeup 是 app 邮箱里来了消息（标题、滚动条……），这些变化渲染线程
    /// 自己知道、自己会画。真机甩动时每跨一行渲染器就往邮箱推一条滚动条消息 → wakeup → 下一拍主线程同步重画一整帧，
    /// 实测每次 1.4–2.2 ms、最长 5.5 ms，还要等 GPU，GPU 一忙就把主线程拖过一拍（user 日志里的晚交帧和惯性 link 跳拍）。
    private var pendingSyncDraw = true

    /// uTerm 本地补丁：引擎 wakeup（app 邮箱里来了标题、滚动条这类消息）触发的 tick 要不要也在主线程同步整帧重画。
    /// 按平台定死，不是开关：
    /// - iOS：要。不画的话（渲染线程自己会画这些变化）真机上滚动发糊；滚动手感是按同步重画验收的。
    /// - Mac：不要。主线程白画一帧还拿着 draw_mutex 挡渲染线程，Mac 上没有 iOS 那个观感问题。
    #if os(macOS)
        static let wakeupDrawsSynchronously = false
    #else
        static let wakeupDrawsSynchronously = true
    #endif

    /// Running only while frames are owed. The engine's wakeups arrive at
    /// PTY speed, not display speed; rendering straight from them draws far
    /// more often than the screen can show and starves input handling under
    /// heavy output. The link paces draws to vsync instead, and is paused
    /// after a stretch of idle frames so a quiet terminal costs no per-frame
    /// wakeups at all. Created once and paused rather than dropped, because
    /// a link bound to a view adds a hidden subview to it. Links on one
    /// display share one platform link.
    ///
    /// The range floors at 60: letting the system drop to 30 while output
    /// streams read as flicker on a scrolling screen. ProMotion displays may
    /// go to 120.
    private var displayLink: DisplayLink?
    private var idleFrameCount = 0
    private static let displayLinkFrameRateRange = DisplayLinkFrameRateRange(
        minimum: 60,
        maximum: 120,
        preferred: 120,
    )
    private static let idleFramesBeforeRelease = 30

    init() {
        bridge.onCellSizeChange = { [weak self] width, height in
            self?.handleCellSizeChange(width: width, height: height)
        }
        bridge.onRenderRequest = { [weak self] in
            self?.requestImmediateTick()
        }
        bridge.onMouseShape = { [weak self] shape in
            self?.onMouseShape?(shape)
        }
        bridge.onConfigChange = { [weak self] in
            guard let self else { return }
            // uTerm 本地补丁：不是自己推的配置 = app 的配置整份推下来了，里面没有这个 surface 的行高调整。
            if !isApplyingSurfaceConfig { cellHeightAdjustment = 0 }
            reloadFontSizeConfiguration()
        }
    }

    func requestImmediateTick(syncDraw: Bool = true) {
        pendingImmediateTick = true
        if syncDraw || Self.wakeupDrawsSynchronously { pendingSyncDraw = true }
        ensureDisplayLink()
    }

    func stopDisplayLink() {
        releaseDisplayLink()
    }

    // MARK: - Surface Lifecycle

    func rebuildIfReady(removingBridgeFrom previousController: TerminalController? = nil) {
        // A pane that is merely hidden reports a zero size. Tearing the surface
        // down here and then bailing out at the size guard below would destroy
        // ghostty's grid and scrollback for a condition that is temporary: when
        // the pane comes back there is nothing left to show, and only the app
        // redrawing can refill it. Keep the surface — the caller re-runs this
        // once the view has a usable size again.
        //
        // This is the same intent as the reattach guard in viewDidMoveToWindow
        // ("rebuilding on every reattach discards Ghostty's scrollback/state"),
        // which cannot help while the teardown happens before the checks.
        if surface != nil, previousController == nil, !hasValidViewSize {
            // The rebuild is owed, not cancelled. Configuration options are
            // consumed only by createSurface, and no caller re-runs this once
            // the view regains a size (fitToSize, viewDidMoveToWindow and the
            // UIKit twin all take the surface != nil branch and merely sync
            // metrics). Dropping the request outright would leave a hidden
            // pane running its old configuration indefinitely.
            pendingRebuild = true
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface kept: view size temporarily invalid \(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))",
            )

            return
        }
        pendingRebuild = false

        tearDownSurface(removingBridgeFrom: previousController ?? controller)
        guard let controller else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: missing controller")
            return
        }
        guard isAttached() else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: view detached")
            return
        }
        guard hasValidViewSize else {
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface rebuild skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))",
            )
            return
        }

        let scale = scaleFactor()
        TerminalDebugLog.log(
            .lifecycle,
            "surface rebuild scale=\(String(format: "%.2f", scale)) \(configuration.debugSummary)",
        )
        let rawSurface = controller.createSurface(
            bridge: bridge,
            configuration: configuration,
            platformSetup: { [self] config in
                platformSetup?(&config)
                config.scale_factor = scale
            },
        )
        guard let rawSurface else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild failed")
            return
        }

        bridge.rawSurface = rawSurface
        let newSurface = TerminalSurface(rawSurface)
        newSurface.sendsCommandChords = sendsCommandChords
        surface = newSurface
        surfaceSession = configuration.inMemorySession
        newSurface.setOcclusion(effectiveSurfaceVisible)
        // Wakeups must keep draining while the surface is merely occluded:
        // the app mailbox (titles, pwd, bell, child-exit) only empties in
        // ghostty_app_tick, and a full mailbox blocks the session's write
        // thread on its next push. Only a detached surface or a
        // backgrounded app suspends ticks — visibility gates rendering
        // alone (canRenderFrame).
        controller.addWakeupObserver(
            ObjectIdentifier(self),
            shouldProcess: { [weak self] in
                guard let self else { return false }
                return isApplicationActive && isAttached()
            },
            onWakeup: { [weak self] in
                self?.requestImmediateTick(syncDraw: false)
            },
        )
        TerminalDebugLog.log(.lifecycle, "surface rebuild succeeded")
        startFontSizeTracking(on: newSurface, controller: controller)
        (delegate as? any TerminalSurfaceLifecycleDelegate)?
            .terminalDidAttachSurface(newSurface)
        onSurfaceAttached?()
        synchronizeMetrics()
        requestImmediateTick()
    }

    // MARK: - Metrics

    /// Ghostty's IO thread coalesces resize messages with a hardcoded 25ms
    /// trailing-only window (Thread.zig). For an alt-screen TUI that fully
    /// repaints on every winsize (Claude Code), a live divider drag posts new
    /// sizes faster than that window resolves — the grid reflow runs
    /// permanently behind the layer bounds and the renderer composites the
    /// stale grid into the new frame: the mid-drag collapse. Bounding the
    /// stream (leading edge for responsiveness, trailing edge so the final
    /// size always lands) hands the engine a signal it can settle on.
    ///
    /// The right window is CONTENT-dependent, so it is a per-surface value
    /// the host sets (`TerminalSurfaceOptions.resizeThrottleMilliseconds`, or
    /// the platform setter for a live change): a primary-screen transcript
    /// that never re-emits its scrollback (codex-style) renders best fully
    /// unthrottled — large throttled jumps read as blinking — while the
    /// alt-screen full-repaint agents need ~96ms. 0 disables. The env var
    /// GHOSTTY_SURFACE_RESIZE_THROTTLE_MS, when set, overrides every surface
    /// for whole-process A/B runs.
    private static let resizeThrottleOverride: TimeInterval? = {
        guard
            let raw = ProcessInfo.processInfo
            .environment["GHOSTTY_SURFACE_RESIZE_THROTTLE_MS"],
            let ms = Double(raw), ms >= 0
        else { return nil }
        return ms / 1000
    }()

    /// Set directly by a platform view; otherwise sourced from
    /// `configuration.resizeThrottleMilliseconds`. Kept as an override so the
    /// AppKit setter can adjust a live surface without rebuilding it.
    var resizeThrottleInterval: TimeInterval?

    private var effectiveResizeThrottle: TimeInterval {
        if let override = Self.resizeThrottleOverride {
            return override
        }
        if let interval = resizeThrottleInterval {
            return interval
        }
        return max(0, configuration.resizeThrottleMilliseconds) / 1000
    }

    private var resizeThrottleArmed = false
    private var resizeThrottleTrailing = false
    /// Invalidates in-flight throttle timers across a teardown. A timer
    /// armed for the old surface must not size — or re-arm against — the
    /// surface that replaced it.
    private var resizeThrottleGeneration = 0
    /// A rebuild deferred by the zero-size guard above, replayed by
    /// `synchronizeMetrics` as soon as the view has a usable size again.
    private var pendingRebuild = false

    func synchronizeMetrics() {
        // Redeem a rebuild the zero-size guard deferred. Every caller that
        // could restore a usable size lands here, so this is the one place
        // that reliably observes the transition.
        if pendingRebuild, hasValidViewSize {
            pendingRebuild = false
            rebuildIfReady()
            return
        }

        guard effectiveResizeThrottle > 0 else {
            performMetricsSync()
            return
        }

        // A scale change (the window crossed displays, or a display came
        // back) cannot wait out the window: until it lands every frame
        // renders at the old scale. The armed timer stays as it is.
        if resizeThrottleArmed, scaleFactor() != syncedScale {
            performMetricsSync()
            return
        }

        guard !resizeThrottleArmed else {
            // Newest wins: the trailing fire re-reads the live view size,
            // so nothing needs to be captured here.
            resizeThrottleTrailing = true
            return
        }

        // Arm only behind a size the surface actually received. The
        // creation-time cell_size callback lands here while `surface` is still
        // nil; arming then would make the new surface's own first sync wait
        // out a full window as a trailing edge.
        guard performMetricsSync() else { return }
        armResizeThrottle()
    }

    private func armResizeThrottle() {
        resizeThrottleArmed = true
        let generation = resizeThrottleGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + effectiveResizeThrottle,
        ) { [weak self] in
            guard let self else { return }
            // A teardown bumped the generation: this timer belongs to a
            // surface that no longer exists. Returning without touching
            // `resizeThrottleArmed` leaves the current surface's own state
            // alone.
            guard generation == resizeThrottleGeneration else { return }
            resizeThrottleArmed = false
            guard resizeThrottleTrailing else { return }
            resizeThrottleTrailing = false
            guard performMetricsSync() else { return }
            armResizeThrottle()
        }
    }

    /// Returns whether a size reached the surface.
    @discardableResult
    private func performMetricsSync() -> Bool {
        guard let surface else {
            TerminalDebugLog.log(.metrics, "synchronizeMetrics skipped: missing surface")
            return false
        }

        let scale = scaleFactor()
        let size = viewSize()
        guard size.width > 0, size.height > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))",
            )
            return false
        }

        let pixelWidth = UInt32((size.width * scale).rounded(.down))
        let pixelHeight = UInt32((size.height * scale).rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid pixel size=\(pixelWidth)x\(pixelHeight)",
            )
            return false
        }

        TerminalDebugLog.log(
            .metrics,
            "sync view=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height)) scale=\(String(format: "%.2f", scale)) pixels=\(pixelWidth)x\(pixelHeight)",
        )

        surface.setContentScale(x: scale, y: scale)
        surface.setSize(width: pixelWidth, height: pixelHeight)
        syncedViewSize = size
        syncedScale = scale

        guard let surfaceSize = surface.size(),
              surfaceSize.columns > 0, surfaceSize.rows > 0
        else {
            TerminalDebugLog.log(.metrics, "sync missing grid metrics after resize")
            onMetricsUpdate?()
            return true
        }

        let metrics = TerminalViewportMetrics(surfaceSize: surfaceSize, scale: scale)
        guard metrics != lastMetrics else {
            TerminalDebugLog.log(
                .metrics,
                "sync unchanged \(metrics.debugSummary)",
            )
            onMetricsUpdate?()
            return true
        }

        lastMetrics = metrics
        TerminalDebugLog.log(.metrics, "sync updated \(metrics.debugSummary)")
        // Deliberately no host resize dispatch here. This runs on the AppKit
        // thread right after setSize(), i.e. before the engine's IO thread has
        // run the resize operation at all — the host would learn the new size
        // from a thread that has not yet reflowed anything.
        //
        // Worse, it poisons the correctly-phased notification: the IO thread's
        // `receiveResizeCallback` (invoked from HostManaged.resize, immediately
        // before `terminal.resize`, both serial within one IO-thread resize
        // operation) then arrives carrying a size the session already recorded,
        // and is discarded as unchanged. A relative-cursor TUI therefore
        // repainted against a winsize that led the grid, and its clamped CUD
        // merged the footer.
        //
        // Leaving `receiveResizeCallback` as the sole PTY-resize source matches
        // stock Ghostty, where pty.setSize runs only inside Termio.resize.
        // Local UI metrics still flow via the delegate below and
        // onMetricsUpdate.
        onGridMetrics?(surfaceSize)
        if let delegate = delegate as? any TerminalSurfaceGridResizeDelegate {
            delegate.terminalDidResize(surfaceSize)
        } else if let delegate = delegate as? any TerminalSurfaceResizeDelegate {
            delegate.terminalDidResize(
                columns: Int(surfaceSize.columns),
                rows: Int(surfaceSize.rows),
            )
        }
        onMetricsUpdate?()
        return true
    }

    func fitToSize() {
        if surface == nil {
            rebuildIfReady()
        } else {
            synchronizeMetrics()
        }
        if surface != nil {
            requestImmediateTick()
        }
    }

    func setDisplayVisible(_ visible: Bool) {
        guard isDisplayVisible != visible else {
            surface?.setOcclusion(effectiveSurfaceVisible)
            return
        }

        isDisplayVisible = visible
        surface?.setOcclusion(effectiveSurfaceVisible)

        if canRenderFrame {
            requestImmediateTick()
        } else {
            stopDisplayLink()
        }
    }

    func setWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }

        isWindowVisible = visible
        surface?.setOcclusion(effectiveSurfaceVisible)

        if canRenderFrame {
            requestImmediateTick()
        } else {
            stopDisplayLink()
        }
    }

    func setApplicationActive(_ active: Bool) {
        guard isApplicationActive != active else {
            // Same state, but not necessarily the same surface: one built
            // between two syncs still wears the occlusion stamped at its
            // birth. Re-stamp — a surface born occluded that never hears
            // otherwise skips every draw and shows as a blank pane.
            surface?.setOcclusion(effectiveSurfaceVisible)
            if active {
                renderImmediately()
            } else {
                stopDisplayLink()
            }
            return
        }

        isApplicationActive = active
        surface?.setOcclusion(effectiveSurfaceVisible)

        if active {
            synchronizeMetrics()
            renderImmediately()
        } else {
            stopDisplayLink()
        }
    }

    // MARK: - Frame Rendering

    func tick() {
        guard canRenderFrame else {
            releaseDisplayLink()
            return
        }
        guard pendingImmediateTick else {
            idleFrameCount += 1
            if idleFrameCount >= Self.idleFramesBeforeRelease {
                releaseDisplayLink()
            }
            return
        }
        idleFrameCount = 0
        pendingImmediateTick = false
        TerminalDebugLog.log(.render, "tick")
        // uTerm 测量打点：trace 关着时 mark() 返回 0，span 不记。
        var mark = UTermScrollTrace.mark()
        controller?.tick()
        UTermScrollTrace.span("tick-app", since: mark)
        mark = UTermScrollTrace.mark()
        surface?.refresh()
        UTermScrollTrace.span("tick-refresh", since: mark)
        if pendingSyncDraw {
            pendingSyncDraw = false
            mark = UTermScrollTrace.mark()
            surface?.draw()
            UTermScrollTrace.span("tick-draw", since: mark)
        }
        onPostRender?()
    }

    // MARK: - Focus

    func setFocus(_ focused: Bool) {
        requestImmediateTick()
        TerminalDebugLog.log(.lifecycle, "focus=\(focused)")
        // uTerm 本地补丁：见 `keepsSurfaceFocused`。
        surface?.setFocus(focused || keepsSurfaceFocused)
        (delegate as? any TerminalSurfaceFocusDelegate)?
            .terminalDidChangeFocus(focused)
    }

    #if DEBUG
        /// Test access to the host-managed resize state. Read-only apart from
        /// `pendingRebuild`, which tests set to drive the redemption path
        /// without needing a real ghostty surface.
        var testHooks_pendingRebuild: Bool {
            get { pendingRebuild }
            set { pendingRebuild = newValue }
        }

        var testHooks_throttleArmed: Bool {
            resizeThrottleArmed
        }

        var testHooks_throttleTrailing: Bool {
            resizeThrottleTrailing
        }

        var testHooks_throttleGeneration: Int {
            resizeThrottleGeneration
        }

        var testHooks_isWindowVisible: Bool {
            isWindowVisible
        }

        var testHooks_canRenderFrame: Bool {
            canRenderFrame
        }
    #endif

    // MARK: - Cleanup

    func freeSurface() {
        TerminalDebugLog.log(.lifecycle, "free surface")
        tearDownSurface(removingBridgeFrom: controller)
    }

    deinit {
        // `@MainActor` classes have a nonisolated deinit by default, but
        // `tearDownSurface` calls methods on other main-actor types (surface,
        // bridge, controller). We rely on deinit running synchronously with
        // exclusive access; assume main-actor isolation so teardown can run
        // inline without crossing isolation.
        MainActor.assumeIsolated {
            tearDownSurface(removingBridgeFrom: controller)
        }
    }

    private func tearDownSurface(removingBridgeFrom controller: TerminalController?) {
        TerminalDebugLog.log(.lifecycle, "tear down surface")
        releaseDisplayLink()
        // Held to the end: ghostty's IO thread calls the session as
        // unretained receive userdata until `surface.free()` joins it, and
        // after a backend swap deferred by the zero-size guard this may be
        // the session's last strong reference. `setFocus(false)` below can
        // still queue a focus report for that thread to write.
        let session = surfaceSession
        defer { withExtendedLifetime(session) {} }
        session?.clearSurface(ifMatches: surface?.rawValue)
        surfaceSession = nil
        controller?.removeWakeupObserver(ObjectIdentifier(self))
        // Must run before rawSurface is cleared: a clipboard-read
        // confirmation still awaiting the host's answer must resolve to a
        // deny before the surface it names goes away, or the requesting
        // program hangs forever. This is the wrapper-level backstop behind
        // "exactly one of complete/deny fires for every request" — it
        // fires regardless of whether the host's own confirmation UI ever
        // dismisses.
        bridge.denyAllPendingClipboardRequests()
        bridge.rawSurface = nil
        bridge.scrollbar = nil
        let hadSurface = surface != nil
        // uTerm 本地补丁：一直聚焦的 surface 拆掉时不报失焦（见 `keepsSurfaceFocused`）。
        if !keepsSurfaceFocused { surface?.setFocus(false) }
        surface?.free()
        surface = nil
        fontSize = nil
        // uTerm 本地补丁：新 surface 从 app 的配置起步。
        cellHeightAdjustment = 0
        lastMetrics = nil
        syncedViewSize = nil
        syncedScale = nil
        // Retire any armed timer with the surface it was armed for, and
        // clear the gate so the replacement surface sizes immediately
        // instead of being suppressed by the old surface's armed flag.
        resizeThrottleGeneration &+= 1
        resizeThrottleArmed = false
        resizeThrottleTrailing = false
        pendingImmediateTick = true
        controller?.remove(bridge)
        if hadSurface {
            // A message the IO thread queued for this surface names it by
            // address, and the app checks that address only by membership.
            // The allocator gives it straight to the next surface on this
            // app, so an exit still queued would land there: the live child
            // reads as exited and the next key closes the surface. Draining
            // while the address is unknown drops those messages.
            controller?.tick()
            (delegate as? any TerminalSurfaceLifecycleDelegate)?
                .terminalDidDetachSurface()
            onSurfaceDetached?()
        }
    }

    private func handleCellSizeChange(width: UInt32, height: UInt32) {
        TerminalDebugLog.log(
            .metrics,
            "cell size changed width=\(width) height=\(height)",
        )
        synchronizeMetrics()
        requestImmediateTick()
        onCellSizeDidChange?()
    }

    private func ensureDisplayLink() {
        guard canRenderFrame else {
            releaseDisplayLink()
            return
        }
        idleFrameCount = 0
        if let displayLink {
            guard displayLink.isPaused else { return }
            displayLink.isPaused = false
        } else {
            let link = DisplayLink(
                context: displayLinkContext,
                preferredFrameRateRange: Self.displayLinkFrameRateRange,
            )
            link.delegate = self
            displayLink = link
        }
        TerminalDebugLog.log(.lifecycle, "display link acquired")
    }

    private func releaseDisplayLink() {
        guard let displayLink, !displayLink.isPaused else { return }
        displayLink.isPaused = true
        idleFrameCount = 0
        TerminalDebugLog.log(.lifecycle, "display link released")
    }

    private var effectiveSurfaceVisible: Bool {
        isDisplayVisible && isWindowVisible && isApplicationActive
    }

    private var canRenderFrame: Bool {
        effectiveSurfaceVisible && isAttached()
    }

    private var hasValidViewSize: Bool {
        let size = viewSize()
        return size.width > 0 && size.height > 0
    }

    private func renderImmediately() {
        guard canRenderFrame else {
            releaseDisplayLink()
            return
        }

        pendingImmediateTick = true
        pendingSyncDraw = true
        tick()
        ensureDisplayLink()
    }
}

extension TerminalSurfaceCoordinator: DisplayLinkDelegate {
    func displayLink(_: DisplayLink, didUpdate _: DisplayLinkFrame) {
        tick()
    }
}
