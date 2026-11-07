import AppKit
import AVFoundation
import SwiftUI

/// Mac 上看 / 控另一台 Mac 的画布。
struct RemoteDesktopMacCanvas: NSViewRepresentable {
    let session: RemoteDesktopSession
    /// 那台 Mac 的显示器点尺寸（开流后才有）。作为参数传进来，SwiftUI 才会在它变化时调 `updateNSView`。
    let displaySize: CGSize?
    /// ⌘V 时本机剪贴板里的内容粘过去了（或读不出来）：外面显示一句提示。
    var onPasteNote: (String) -> Void = { _ in }
    /// 把 ⌘Tab、⌘空格、⌘W 这些系统 / 本机快捷键也发过去（要「辅助功能」授权）。
    var sendSystemShortcuts = true
    /// 截取系统快捷键挂不上（没有「辅助功能」授权）。
    var onShortcutCaptureFailed: () -> Void = {}

    func makeNSView(context: Context) -> RemoteDesktopCanvasNSView {
        RemoteDesktopCanvasNSView(session: session)
    }

    func updateNSView(_ view: RemoteDesktopCanvasNSView, context: Context) {
        view.onPasteNote = onPasteNote
        view.onShortcutCaptureFailed = onShortcutCaptureFailed
        view.sendSystemShortcuts = sendSystemShortcuts
        view.update(displaySize: displaySize)
        view.update(cursorImage: session.cursorImage)
    }

    static func dismantleNSView(_ view: RemoteDesktopCanvasNSView, coordinator: ()) {
        view.teardown()
    }
}

/// 画布本体。
///
/// - 画面：`AVSampleBufferDisplayLayer`，帧在解码队列上直接 enqueue，不经主线程（与手机端同一条路）。
///   视图是「图层宿主」（自己建根图层再 `wantsLayer`）：AppKit 不再管这棵图层树，不会在重绘 / 改透明度时
///   动到视频图层。视频图层的 frame 只在真的变了时才设：Mac 上鼠标一动光标回报每秒约 60 次，每次都重设
///   同一个 frame 也会让视频图层重新布局。
/// - 指针：绝对坐标。本机指针在画面上就是那台 Mac 的指针（那边采集时不画光标，本机光标就是它）；
///   本机指针不在画面上、或只能查看时，按那台 Mac 回报的位置画一个箭头。
/// - 键盘：画布是第一响应者时，按键（含 ⌘ 组合）原样发过去，不进本机菜单，也不进本机输入法：
///   中文等由那台 Mac 的输入法处理。⌘W 例外（关本机标签，由窗口拦下）；⌘V 在本机剪贴板有图片 / 文字时
///   改成「粘贴到那台 Mac」。系统级快捷键（⌘Tab、⌘空格）本机系统先拿走，发不过去。
/// - 失焦（切走窗口）时把按着的键和鼠标键全部抬起，那边不会卡住修饰键。
/// - 「发送系统快捷键」开着时，画布有焦点期间挂键盘事件钩子（`RemoteDesktopKeyboardCapture`），
///   ⌘Tab / ⌘空格 / 调度中心 / ⌘W / ⌘Q 也发过去；切走窗口或 app 立刻摘掉。
@MainActor
final class RemoteDesktopCanvasNSView: NSView {
    private let session: RemoteDesktopSession
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let cursorLayer = CAShapeLayer()
    var onPasteNote: (String) -> Void = { _ in }
    var onShortcutCaptureFailed: () -> Void = {}
    var sendSystemShortcuts = true {
        didSet { if sendSystemShortcuts != oldValue { refreshCapture() } }
    }
    private let capture = RemoteDesktopKeyboardCapture()
    private var reportedCaptureFailure = false

    private var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 16, height: 10), viewSize: .zero)
    private var trackingArea: NSTrackingArea?
    private var mouseInside = false
    /// 最近一次发出的指针（归一化），重复的不再发。
    private var lastSentPointer: (x: Float, y: Float)?
    /// 那台 Mac 回报的光标。
    private var macCursor = RemoteDesktopCursor(x: 0.5, y: 0.5, visible: true)
    /// 按下还没抬起的键 / 鼠标键，失焦时补抬起。
    private var pressedKeys: [UInt16: RemoteKeyModifiers] = [:]
    private var pressedButtons: Set<UInt8> = []
    private var pasting = false

    init(session: RemoteDesktopSession) {
        self.session = session
        super.init(frame: .zero)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        cursorLayer.path = Self.arrowPath()
        cursorLayer.fillColor = NSColor.black.cgColor
        cursorLayer.strokeColor = NSColor.white.cgColor
        cursorLayer.lineWidth = 1.5
        cursorLayer.shadowColor = NSColor.black.cgColor
        cursorLayer.shadowOpacity = 0.35
        cursorLayer.shadowRadius = 1.5
        cursorLayer.isHidden = true
        layer?.addSublayer(cursorLayer)
        attachReceiver()
        AppLogger.info("远程桌面画布：建立", category: RemoteLog.category)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowResignedKey),
                           name: NSWindow.didResignKeyNotification, object: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            center.addObserver(self, selector: #selector(focusChanged), name: name, object: nil)
        }
        capture.onKey = { [weak self] event in self?.captured(event) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func teardown() {
        AppLogger.info("远程桌面画布：拆除", category: RemoteLog.category)
        capture.set(active: false)
        releaseAll()
        NotificationCenter.default.removeObserver(self)
        session.receiver.setHandlers(onImage: nil, onCursor: nil)
    }

    // MARK: - 画面

    private func attachReceiver() {
        let renderer = RendererBox(displayLayer.sampleBufferRenderer)
        session.receiver.setHandlers(
            onImage: { image, _ in
                guard let sample = RemoteVideoDecoder.displaySample(image) else { return }
                renderer.enqueue(sample)
            },
            onCursor: { [weak self] cursor in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.macCursorArrived(cursor) } }
            })
    }

    /// 渲染器从解码队列上用。出错（或系统要求 flush）时先记一笔原因，flush 后把这一帧照常送进去，
    /// 画面不会停在黑屏上等下一次变化。
    private nonisolated final class RendererBox: @unchecked Sendable {
        let renderer: AVSampleBufferVideoRenderer
        private var failures = 0
        init(_ renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }
        func enqueue(_ sample: CMSampleBuffer) {
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                failures += 1
                if failures <= 20 || failures % 100 == 0 {
                    let reason = renderer.error.map { "\($0)" } ?? "需要 flush"
                    let count = failures
                    AppLogger.info("远程桌面画布：渲染器出错，flush 后继续（第 \(count) 次）：\(reason)",
                                   category: RemoteLog.category)
                }
                renderer.flush()
            }
            renderer.enqueue(sample)
        }
    }

    private func macCursorArrived(_ cursor: RemoteDesktopCursor) {
        guard cursor != macCursor else { return }
        macCursor = cursor
        layoutContent()
    }

    // MARK: - 布局

    /// 画面总是整块适配进窗口（留黑边，不裁不拉伸）。
    func update(displaySize: CGSize?) {
        guard let size = displaySize, size.width > 0, size.height > 0, size != viewport.contentSize else { return }
        viewport.contentSize = size
        applyFit()
        fitWindowOnce()
        refreshCapture()
    }

    /// 上次按哪块屏幕的尺寸对过窗口。
    private var fittedFor: CGSize?

    /// 拿到（或换了）那台屏幕的尺寸：把窗口高度对上它的比例（宽度不动，放不下就按屏幕高度缩宽度），画面上下不留黑边。
    /// 同一块屏幕只对一次，之后用户怎么拉都不再管。全屏时不动。
    private func fitWindowOnce() {
        guard fittedFor != viewport.contentSize, let window, !window.styleMask.contains(.fullScreen), bounds.width > 0,
              let screen = window.screen ?? NSScreen.main else { return }
        fittedFor = viewport.contentSize
        let target = Self.fittedFrame(window: window.frame, canvas: bounds.size, display: viewport.contentSize,
                                      visible: screen.visibleFrame)
        if target != window.frame { window.setFrame(target, display: true, animate: true) }
    }

    /// 窗口要多大，画布才正好是那台屏幕的比例。上沿不动；超出可见区时等比缩小宽度。
    nonisolated static func fittedFrame(window: CGRect, canvas: CGSize, display: CGSize, visible: CGRect) -> CGRect {
        guard canvas.width > 0, display.width > 0, display.height > 0 else { return window }
        let chrome = CGSize(width: window.width - canvas.width, height: window.height - canvas.height)
        var width = canvas.width
        var height = (width * display.height / display.width).rounded()
        let maxHeight = window.maxY - visible.minY - chrome.height
        if height > maxHeight, maxHeight > 0 {
            height = maxHeight
            width = (height * display.width / display.height).rounded()
        }
        let size = CGSize(width: width + chrome.width, height: height + chrome.height)
        return CGRect(x: window.minX, y: window.maxY - size.height, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        guard viewport.viewSize != bounds.size else { return }
        viewport.viewSize = bounds.size
        applyFit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        cursorLayer.contentsScale = scale
    }

    private func applyFit() {
        viewport.reset()
        layoutContent()
        window?.invalidateCursorRects(for: self)
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = viewport.contentFrame
        if displayLayer.frame != frame { displayLayer.frame = frame }
        cursorLayer.position = viewport.viewPoint(normalized: CGPoint(x: CGFloat(macCursor.x), y: CGFloat(macCursor.y)))
        // 本机指针在画面上并且能控制时，本机光标就是那台 Mac 的光标，不再画一个。
        let localIsCursor = session.canControl && mouseInside
        cursorLayer.isHidden = session.info == nil || !macCursor.visible || localIsCursor
        CATransaction.commit()
    }

    private static func arrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 17))
        path.addLine(to: CGPoint(x: 4.2, y: 13))
        path.addLine(to: CGPoint(x: 7.2, y: 19.5))
        path.addLine(to: CGPoint(x: 9.8, y: 18.3))
        path.addLine(to: CGPoint(x: 6.9, y: 12))
        path.addLine(to: CGPoint(x: 12.3, y: 12))
        path.closeSubpath()
        return path
    }

    // MARK: - 光标形状

    private var remoteCursorImage: RemoteDesktopCursorImage?
    private var remoteCursor: NSCursor?

    /// 那台 Mac 的光标换了样子（I 形、调整大小…）：本机指针在画面上时就用它。
    func update(cursorImage: RemoteDesktopCursorImage?) {
        guard cursorImage != remoteCursorImage else { return }
        remoteCursorImage = cursorImage
        remoteCursor = cursorImage.flatMap(Self.cursor(from:))
        window?.invalidateCursorRects(for: self)
        if mouseInside, session.canControl { (remoteCursor ?? .arrow).set() }
    }

    nonisolated static func cursor(from image: RemoteDesktopCursorImage) -> NSCursor? {
        guard image.width > 0, image.height > 0, let picture = NSImage(data: image.png) else { return nil }
        picture.size = NSSize(width: image.width, height: image.height)
        return NSCursor(image: picture, hotSpot: NSPoint(x: image.hotX, y: image.hotY))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard session.canControl, let remoteCursor else { return }
        let picture = viewport.contentFrame.intersection(bounds)
        guard !picture.isEmpty else { return }
        addCursorRect(picture, cursor: remoteCursor)
    }

    // MARK: - 指针

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                         .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        layoutContent()
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        layoutContent()
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func rightMouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func otherMouseDragged(with event: NSEvent) { pointerMoved(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonEvent(event)
    }

    override func mouseUp(with event: NSEvent) { buttonEvent(event) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonEvent(event)
    }
    override func rightMouseUp(with event: NSEvent) { buttonEvent(event) }
    override func otherMouseDown(with event: NSEvent) { buttonEvent(event) }
    override func otherMouseUp(with event: NSEvent) { buttonEvent(event) }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func pointerMoved(_ event: NSEvent) {
        sendMove(to: location(of: event))
    }

    private func sendMove(to point: CGPoint) {
        guard session.canControl else { return }
        let p = RemoteDesktopEventMapper.normalized(point, in: viewport)
        if let last = lastSentPointer, last == p { return }
        lastSentPointer = p
        session.send(.move(x: p.x, y: p.y))
    }

    private func buttonEvent(_ event: NSEvent) {
        guard session.canControl, let (button, down) = RemoteDesktopEventMapper.button(for: event.type) else { return }
        let p = RemoteDesktopEventMapper.normalized(location(of: event), in: viewport)
        lastSentPointer = p
        if down { pressedButtons.insert(button.rawValue) } else { pressedButtons.remove(button.rawValue) }
        session.send(.button(button, down: down, clickCount: UInt8(clamping: max(1, event.clickCount)),
                             x: p.x, y: p.y, modifiers: RemoteDesktopEventMapper.modifiers(event.modifierFlags)))
    }

    override func scrollWheel(with event: NSEvent) {
        guard session.canControl,
              let input = RemoteDesktopEventMapper.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                                          precise: event.hasPreciseScrollingDeltas,
                                                          phase: event.phase, momentumPhase: event.momentumPhase)
        else { return }
        session.send(input)
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        guard session.canControl else { return }
        if RemoteDesktopEventMapper.isPasteShortcut(code: event.keyCode, flags: event.modifierFlags),
           !event.isARepeat, session.canPaste {
            pasteFromLocalClipboard(fallback: event)
            return
        }
        sendKey(event.keyCode, down: true, flags: event.modifierFlags)
    }

    override func keyUp(with event: NSEvent) {
        guard session.canControl, pressedKeys[event.keyCode] != nil else { return }
        sendKey(event.keyCode, down: false, flags: event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        guard session.canControl else { return }
        for input in RemoteDesktopEventMapper.modifierKey(code: event.keyCode, flags: event.modifierFlags) {
            if case .key(let code, let down, let modifiers) = input, code != 0x39 {
                if down { pressedKeys[code] = modifiers } else { pressedKeys.removeValue(forKey: code) }
            }
            session.send(input)
        }
    }

    /// ⌘ 组合先到这里（早于本机菜单）：画布有焦点时全部当按键发过去。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, session.canControl, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    private func sendKey(_ code: UInt16, down: Bool, flags: NSEvent.ModifierFlags) {
        let modifiers = RemoteDesktopEventMapper.modifiers(flags)
        if down { pressedKeys[code] = modifiers } else { pressedKeys.removeValue(forKey: code) }
        session.send(.key(code: code, down: down, modifiers: modifiers))
    }

    private func pasteFromLocalClipboard(fallback event: NSEvent) {
        guard !pasting else { return }
        pasting = true
        let code = event.keyCode, flags = event.modifierFlags
        Task { @MainActor [weak self] in
            defer { self?.pasting = false }
            guard let self else { return }
            do {
                if let content = try await RemoteDesktopMacPasteSource.read() {
                    session.paste(content)
                    return
                }
            } catch {
                onPasteNote(error.localizedDescription)
                return
            }
            // 本机剪贴板里没有能粘的（或是文件）：照常按 ⌘V，粘出那台 Mac 自己剪贴板里的东西。
            sendKey(code, down: true, flags: flags)
            sendKey(code, down: false, flags: flags)
        }
    }

    // MARK: - 失焦

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.refreshCapture() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        capture.set(active: false)
        releaseAll()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshCapture()
    }

    @objc private func windowResignedKey(_ note: Notification) {
        guard (note.object as? NSWindow) === window else { return }
        capture.set(active: false)
        releaseAll()
    }

    @objc private func focusChanged(_ note: Notification) {
        refreshCapture()
    }

    // MARK: - 系统快捷键

    /// 按现在的焦点挂上 / 摘掉键盘钩子。
    private func refreshCapture() {
        let active = RemoteDesktopKeyboardCapture.shouldCapture(
            enabled: sendSystemShortcuts, appActive: NSApp.isActive, windowKey: window?.isKeyWindow ?? false,
            canvasFocused: window?.firstResponder === self, canControl: session.canControl)
        capture.set(active: active)
        if active, capture.failed, !reportedCaptureFailure {
            reportedCaptureFailure = true
            onShortcutCaptureFailed()
        }
    }

    /// 钩子截下的按键：和窗口收到的按键同一套处理（⌘V 照样先看本机剪贴板）。
    private func captured(_ event: NSEvent) {
        switch event.type {
        case .keyDown: keyDown(with: event)
        case .keyUp: keyUp(with: event)
        case .flagsChanged: flagsChanged(with: event)
        default: break
        }
    }

    /// 按着的键和鼠标键全部抬起：切走窗口后本机收不到抬起，那边会一直以为 ⌘ 按着。
    private func releaseAll() {
        guard session.canControl else {
            pressedKeys.removeAll()
            pressedButtons.removeAll()
            return
        }
        for (code, _) in pressedKeys { session.send(.key(code: code, down: false, modifiers: [])) }
        pressedKeys.removeAll()
        let p = lastSentPointer ?? (Float(macCursor.x), Float(macCursor.y))
        for raw in pressedButtons {
            guard let button = RemoteMouseButton(rawValue: raw) else { continue }
            session.send(.button(button, down: false, clickCount: 1, x: p.x, y: p.y, modifiers: []))
        }
        pressedButtons.removeAll()
    }
}
