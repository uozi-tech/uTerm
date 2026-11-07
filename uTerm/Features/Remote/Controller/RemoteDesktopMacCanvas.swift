import AppKit
import AVFoundation
import SwiftUI

/// 远程桌面的显示比例：适配窗口（整块屏幕放进来）或原始大小（那台 Mac 的一个点 = 本机一个点，超出的部分
/// 指针推到窗口边上时画面跟着走）。
nonisolated enum RemoteDesktopScaleMode: String, Hashable, Sendable {
    case fit
    case actual
}

/// Mac 上看 / 控另一台 Mac 的画布。
struct RemoteDesktopMacCanvas: NSViewRepresentable {
    let session: RemoteDesktopSession
    let scaleMode: RemoteDesktopScaleMode
    /// 那台 Mac 的显示器点尺寸（开流后才有）。作为参数传进来，SwiftUI 才会在它变化时调 `updateNSView`。
    let displaySize: CGSize?
    /// ⌘V 时本机剪贴板里的内容粘过去了（或读不出来）：外面显示一句提示。
    var onPasteNote: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> RemoteDesktopCanvasNSView {
        RemoteDesktopCanvasNSView(session: session)
    }

    func updateNSView(_ view: RemoteDesktopCanvasNSView, context: Context) {
        view.onPasteNote = onPasteNote
        view.update(displaySize: displaySize, scaleMode: scaleMode)
    }

    static func dismantleNSView(_ view: RemoteDesktopCanvasNSView, coordinator: ()) {
        view.teardown()
    }
}

/// 画布本体。
///
/// - 画面：`AVSampleBufferDisplayLayer`，帧在解码队列上直接 enqueue，不经主线程（与手机端同一条路）。
/// - 指针：绝对坐标。本机指针在画面上就是那台 Mac 的指针（那边采集时不画光标，本机光标就是它）；
///   本机指针不在画面上、或只能查看时，按那台 Mac 回报的位置画一个箭头。
/// - 键盘：画布是第一响应者时，按键（含 ⌘ 组合）原样发过去，不进本机菜单，也不进本机输入法：
///   中文等由那台 Mac 的输入法处理。⌘W 例外（关本机标签，由窗口拦下）；⌘V 在本机剪贴板有图片 / 文字时
///   改成「粘贴到那台 Mac」。系统级快捷键（⌘Tab、⌘空格）本机系统先拿走，发不过去。
/// - 失焦（切走窗口）时把按着的键和鼠标键全部抬起，那边不会卡住修饰键。
@MainActor
final class RemoteDesktopCanvasNSView: NSView {
    private let session: RemoteDesktopSession
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let cursorLayer = CAShapeLayer()
    var onPasteNote: (String) -> Void = { _ in }

    private var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 16, height: 10), viewSize: .zero)
    private var scaleMode: RemoteDesktopScaleMode = .fit
    private var trackingArea: NSTrackingArea?
    private var mouseInside = false
    /// 最近一次发出的指针（归一化），重复的不再发。
    private var lastSentPointer: (x: Float, y: Float)?
    /// 那台 Mac 回报的光标。
    private var macCursor = RemoteDesktopCursor(x: 0.5, y: 0.5, visible: true)
    /// 按下还没抬起的键 / 鼠标键，失焦时补抬起。
    private var pressedKeys: [UInt16: RemoteKeyModifiers] = [:]
    private var pressedButtons: Set<UInt8> = []
    private var lastMouseLocation: CGPoint?
    private var edgeTimer: Timer?
    private var pasting = false

    init(session: RemoteDesktopSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
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
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func teardown() {
        releaseAll()
        stopEdgeTimer()
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

    private nonisolated final class RendererBox: @unchecked Sendable {
        let renderer: AVSampleBufferVideoRenderer
        init(_ renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }
        func enqueue(_ sample: CMSampleBuffer) {
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }

    private func macCursorArrived(_ cursor: RemoteDesktopCursor) {
        guard cursor != macCursor else { return }
        macCursor = cursor
        layoutContent()
    }

    // MARK: - 布局

    func update(displaySize: CGSize?, scaleMode: RemoteDesktopScaleMode) {
        var changed = false
        if let size = displaySize, size.width > 0, size.height > 0, size != viewport.contentSize {
            viewport.contentSize = size
            changed = true
        }
        if scaleMode != self.scaleMode {
            self.scaleMode = scaleMode
            changed = true
        }
        if changed { applyScale() }
    }

    override func layout() {
        super.layout()
        guard viewport.viewSize != bounds.size else { return }
        viewport.viewSize = bounds.size
        applyScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        cursorLayer.contentsScale = scale
        displayLayer.contentsScale = scale
    }

    private func applyScale() {
        switch scaleMode {
        case .fit:
            viewport.reset()
        case .actual:
            let fit = viewport.fitScale
            viewport.setZoom(fit > 0 ? 1 / fit : 1)
        }
        viewport.clamp()
        layoutContent()
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = viewport.contentFrame
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
        stopEdgeTimer()
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
        let point = location(of: event)
        lastMouseLocation = point
        updateEdgeTimer(at: point)
        sendMove(to: point)
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

    // MARK: - 原始大小：指针推到窗口边上时画面跟着走

    private func updateEdgeTimer(at point: CGPoint) {
        let velocity = RemoteTrackpad.edgeVelocity(at: point, in: bounds.size, zone: 24, maxSpeed: 900)
        let overflows = viewport.contentFrame.width > bounds.width + 0.5 || viewport.contentFrame.height > bounds.height + 0.5
        guard scaleMode == .actual, overflows, velocity != .zero else {
            stopEdgeTimer()
            return
        }
        guard edgeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepEdge() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeTimer = timer
    }

    private func stepEdge() {
        guard let point = lastMouseLocation else { return stopEdgeTimer() }
        let velocity = RemoteTrackpad.edgeVelocity(at: point, in: bounds.size, zone: 24, maxSpeed: 900)
        guard velocity != .zero else { return stopEdgeTimer() }
        let before = viewport.contentFrame.origin
        // 指针往右推，看右边的内容：画面往左走。
        viewport.pan(by: CGSize(width: -velocity.width / 60, height: -velocity.height / 60))
        guard viewport.contentFrame.origin != before else { return }
        layoutContent()
        sendMove(to: point)
    }

    private func stopEdgeTimer() {
        edgeTimer?.invalidate()
        edgeTimer = nil
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

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    @objc private func windowResignedKey(_ note: Notification) {
        guard (note.object as? NSWindow) === window else { return }
        releaseAll()
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
