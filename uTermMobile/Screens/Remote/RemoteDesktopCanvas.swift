import AVFoundation
import SwiftUI
import UIKit

/// 粘滞修饰键（键盘条上的 ⌃⌥⇧⌘）：点亮后作用于下一次按键或点击，用完自动熄灭。
@MainActor
@Observable
final class RemoteDesktopKeyState {
    private(set) var modifiers: RemoteKeyModifiers = []

    func toggle(_ modifier: RemoteKeyModifiers) {
        if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
    }

    /// 取走当前的修饰并熄灭。
    func consume() -> RemoteKeyModifiers {
        defer { modifiers = [] }
        return modifiers
    }
}

/// 远程桌面画布：解码后的画面 + 本地画的光标 + 触控板式手势。
struct RemoteDesktopCanvas: UIViewRepresentable {
    let session: RemoteDesktopSession
    let keys: RemoteDesktopKeyState
    /// 软键盘是否弹出（由外面的键盘按钮控制）。
    @Binding var keyboardVisible: Bool
    /// 递增一次 = 回到「适配屏幕」。
    let fitToken: Int
    /// Mac 显示器的点尺寸（开流后才有）。作为参数传进来，SwiftUI 才会在它变化时调 `updateUIView`。
    let displaySize: CGSize?

    func makeUIView(context: Context) -> RemoteDesktopCanvasView {
        let view = RemoteDesktopCanvasView(session: session, keys: keys)
        // 键盘可能在 SwiftUI 更新期间被收走（拆视图时 UIKit 卸第一响应者），不能当场写状态。
        view.onKeyboardDismissed = { DispatchQueue.main.async { keyboardVisible = false } }
        return view
    }

    func updateUIView(_ view: RemoteDesktopCanvasView, context: Context) {
        view.setKeyboardVisible(keyboardVisible)
        if view.fitToken != fitToken {
            view.fitToken = fitToken
            view.resetViewport()
        }
        view.updateContentSize(displaySize)
    }

    static func dismantleUIView(_ view: RemoteDesktopCanvasView, coordinator: ()) {
        view.teardown()
    }
}

/// 画布本体。
///
/// - 画面：`AVSampleBufferDisplayLayer`，帧在解码队列上直接 enqueue（带 DisplayImmediately），不经主线程。
///   图层的位置与大小就是视口里显示器的位置（`RemoteDesktopViewport.contentFrame`），缩放平移只改图层 frame。
/// - 光标：Mac 不画光标（采集时 `showsCursor = false`），手机本地画。触控板模式下光标完全由本地预测，
///   手指一动光标就动，不等 Mac 回画面；手指离开一会儿后才采用 Mac 报回的位置（Mac 上有人动了鼠标）。
/// - 指针移动按屏幕刷新合并：一帧只发最新位置。
/// - 手势：触摸直接交给 `RemoteTrackpadGesture` 判定，这里只执行结果（判定规则见那边的注释）。
@MainActor
final class RemoteDesktopCanvasView: UIView {
    private let session: RemoteDesktopSession
    private let keys: RemoteDesktopKeyState
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let cursorLayer = CAShapeLayer()
    private let keyInput = RemoteKeyInputView()
    /// 量画布四角落在多大的屏幕圆角里（见 `screenCornerRadius`）。不画东西、不接触摸。
    private let cornerProbe = UIView()
    var fitToken = 0
    var onKeyboardDismissed: (() -> Void)?

    /// 放大后光标离画面边缘至少留这么多（视图点）。
    private static let pointerMargin: CGFloat = 48

    private var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 16, height: 10), viewSize: .zero)
    /// 指针（显示器归一化坐标）。
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var lastSentPointer: CGPoint?
    private var lastLocalInput: CFTimeInterval = 0
    /// 触摸时间戳与显示时钟的偏差只记一次（排查用）。
    private var loggedClockSkew = false
    private var displayLink: CADisplayLink?
    private var gesture = RemoteTrackpadGesture()
    /// 正在等按住时长的那根手指：计时到点前先看它是不是其实已经抬起（抬起事件可能晚到，见 `tick`）。
    private weak var holdTouch: UITouch?
    private var dragging = false
    private var dragLocation: CGPoint?
    /// 拖拽离开过边缘区才开始自动走：从边缘起手的拖拽不该一按下光标就自己跑。
    private var dragEdgeArmed = false
    private var lastClick: (time: CFTimeInterval, point: CGPoint, count: UInt8)?
    private var scrolling = false
    private var momentum: CGPoint = .zero
    private var momentumActive = false
    /// Mac 报的光标是否在这块显示器上（光标挪到别的屏上时不画）。
    private var macCursorVisible = true

    init(session: RemoteDesktopSession, keys: RemoteDesktopKeyState) {
        self.session = session
        self.keys = keys
        super.init(frame: .zero)
        backgroundColor = .black
        // 放大后的画面不能盖到顶栏 / 键盘条上：由视图自己裁。SwiftUI 的 `.clipped()` 按安全区里的
        // 布局框裁，会把左右忽略安全区后多出来的那条也裁掉。
        clipsToBounds = true
        isMultipleTouchEnabled = true
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
        cursorLayer.path = Self.arrowPath()
        cursorLayer.fillColor = UIColor.black.cgColor
        cursorLayer.strokeColor = UIColor.white.cgColor
        cursorLayer.lineWidth = 1.5
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.35
        cursorLayer.shadowRadius = 1.5
        cursorLayer.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(cursorLayer)
        addSubview(keyInput)
        cornerProbe.isUserInteractionEnabled = false
        cornerProbe.alpha = 0
        if #available(iOS 26.0, *) { cornerProbe.cornerConfiguration = .corners(radius: .containerConcentric()) }
        addSubview(cornerProbe)
        keyInput.keys = keys
        keyInput.send = { [weak self] input in self?.send(input) }
        keyInput.onResign = { [weak self] in self?.onKeyboardDismissed?() }
        attachReceiver()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func teardown() {
        apply(gesture.cancel())
        stopMomentum()
        displayLink?.invalidate()
        displayLink = nil
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
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.macCursor(cursor) } }
            })
    }

    /// 渲染器从解码队列上用（`AVSampleBufferVideoRenderer` 可以在任意线程 enqueue；状态出错先 flush 再继续）。
    private nonisolated final class RendererBox: @unchecked Sendable {
        let renderer: AVSampleBufferVideoRenderer
        init(_ renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }
        func enqueue(_ sample: CMSampleBuffer) {
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }

    // MARK: - 布局

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startDisplayLink()
            // 外接键盘（iPad）：画布自己当第一响应者，不弹软键盘也能收到按键。
            if !keyInput.isFirstResponder { becomeFirstResponder() }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        viewport.viewSize = bounds.size
        cornerProbe.frame = bounds
        viewport.cornerRadius = screenCornerRadius()
        viewport.clamp()
        layoutContent()
        keyInput.frame = CGRect(x: 0, y: max(0, bounds.height - 48), width: bounds.width, height: min(48, bounds.height))
    }

    /// 画布四角里最大的屏幕圆角：画布铺满整屏，下面两个角（键盘条收起时）正是屏幕的物理圆角，
    /// 「适配屏幕」要让画面四角落在弧线以内（`RemoteDesktopCornerFit`）。
    ///
    /// iOS 26 起用系统的同心圆角：探针视图与画布同框，`containerConcentric` 给出每个角离屏幕圆角
    /// 还剩多大的半径（不在屏幕角上的角是 0）。在 `layoutSubviews` 里读，变了系统会再排一次版。
    /// 更早的系统没有这个接口：画布的角贴着屏幕的角、且屏幕有 Home 条（全面屏）时按 55pt 算。
    private func screenCornerRadius() -> CGFloat {
        if #available(iOS 26.0, *) {
            return cornerProbe.effectiveRadius(corner: .allCorners)
        }
        guard let window, window.safeAreaInsets.bottom > 0 else { return 0 }
        let frame = convert(bounds, to: window)
        let screen = window.bounds
        let touchesBottom = abs(frame.maxY - screen.maxY) < 1, touchesTop = abs(frame.minY - screen.minY) < 1
        let touchesSide = abs(frame.minX - screen.minX) < 1 || abs(frame.maxX - screen.maxX) < 1
        return touchesSide && (touchesTop || touchesBottom) ? Self.legacyScreenCornerRadius : 0
    }

    private static let legacyScreenCornerRadius: CGFloat = 55

    func updateContentSize(_ size: CGSize?) {
        guard let size, size.width > 0, size.height > 0, size != viewport.contentSize else { return }
        viewport.contentSize = size
        viewport.clamp()
        layoutContent()
    }

    func resetViewport() {
        viewport.reset()
        layoutContent()
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = viewport.contentFrame
        cursorLayer.position = viewport.viewPoint(normalized: pointer)
        cursorLayer.isHidden = session.info == nil || !macCursorVisible
        CATransaction.commit()
    }

    /// 箭头光标，尖端在原点。尺寸固定（视图点），不随缩放变。
    private static func arrowPath() -> CGPath {
        let path = UIBezierPath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 17))
        path.addLine(to: CGPoint(x: 4.2, y: 13))
        path.addLine(to: CGPoint(x: 7.2, y: 19.5))
        path.addLine(to: CGPoint(x: 9.8, y: 18.3))
        path.addLine(to: CGPoint(x: 6.9, y: 12))
        path.addLine(to: CGPoint(x: 12.3, y: 12))
        path.close()
        return path.cgPath
    }

    // MARK: - 每帧合并

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    private func wake() {
        displayLink?.isPaused = false
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let lifted = holdTouch.map { $0.phase == .ended || $0.phase == .cancelled } ?? false
        apply(gesture.tick(at: link.timestamp, fingerLifted: lifted))
        let duration = link.targetTimestamp - link.timestamp
        if momentumActive { stepMomentum(duration: duration) }
        let edgeMoving = stepDragEdge(duration: duration)
        if lastSentPointer != pointer, session.canControl {
            lastSentPointer = pointer
            session.send(.move(x: Float(pointer.x), y: Float(pointer.y)))
        }
        if !momentumActive && !edgeMoving && !gesture.needsTick && lastSentPointer == pointer { link.isPaused = true }
    }

    /// `CADisplayLink` 强持有 target：用一个弱引用的中转，画布才能正常释放。
    private final class DisplayLinkProxy {
        weak var owner: RemoteDesktopCanvasView?
        init(_ owner: RemoteDesktopCanvasView) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }

    // MARK: - Mac 光标回报

    private func macCursor(_ cursor: RemoteDesktopCursor) {
        // 手指刚动过：以本地预测为准，不让回报的旧位置把光标拽回去。
        guard CACurrentMediaTime() - lastLocalInput > 0.4, !dragging else { return }
        let point = CGPoint(x: CGFloat(cursor.x), y: CGFloat(cursor.y))
        guard point != pointer else { return }
        pointer = point
        lastSentPointer = point
        macCursorVisible = cursor.visible
        layoutContent()
    }

    // MARK: - 手势

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 手指一碰到就停住惯性，和 Mac 触控板一样；这一下不算点击。
        if momentumActive {
            stopMomentum()
            gesture.suppressNextTap()
        }
        if !loggedClockSkew, let timestamp = touches.first?.timestamp,
           abs(CACurrentMediaTime() - timestamp) > 0.2 {
            loggedClockSkew = true
            AppLogger.info("远程桌面：触摸时间与显示时钟差 \(Int((CACurrentMediaTime() - timestamp) * 1000)) ms",
                           category: RemoteLog.category)
        }
        feedTouches(event)
        wake()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        feedTouches(event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        feedTouches(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        noteLocalInput()
        apply(gesture.cancel())
    }

    /// 时间一律取送达画布的这一刻，和 `tick` 的 `CADisplayLink` 同一个时钟（与 Moonlight 从
    /// touchesBegan 起计时一致）。不用 `UITouch.timestamp`：它和显示时钟对不上、或按下事件晚送到时，
    /// 按下那一刻就已「按满 0.45 s」，每一下都成了按住左键——点击变长按、移动光标变拖选。
    private func feedTouches(_ event: UIEvent?) {
        noteLocalInput()
        let active = (event?.touches(for: self) ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        let touches = active.map {
            RemoteTrackpadTouch(id: Int(bitPattern: ObjectIdentifier($0)), location: $0.location(in: self))
        }
        apply(gesture.update(touches, at: CACurrentMediaTime()))
        holdTouch = gesture.needsTick && active.count == 1 ? active.first : nil
    }

    private func apply(_ actions: [RemoteTrackpadAction]) {
        for action in actions {
            apply(action)
        }
    }

    private func apply(_ action: RemoteTrackpadAction) {
        switch action {
        case .movePointer(let delta, let speed):
            moveOrPan(by: delta, speed: speed)
        case .click(let button):
            click(button)
        case .dragBegan:
            beginDrag()
        case .dragMoved(let delta, let speed, let location):
            dragLocation = location
            moveOrPan(by: delta, speed: speed)
        case .dragEnded:
            endDrag()
        case .scrollBegan:
            beginScroll()
        case .scrollMoved(let delta):
            moveScroll(by: delta)
        case .scrollEnded(let velocity):
            finishScroll(velocity: velocity)
        case .zoomed(let factor, let anchor):
            viewport.zoom(by: factor, anchor: anchor)
            keepPointerInView()
            layoutContent()
        case .panned(let delta):
            viewport.pan(by: delta)
            keepPointerInView()
            layoutContent()
        }
    }

    private func noteLocalInput() {
        lastLocalInput = CACurrentMediaTime()
    }

    private func moveOrPan(by delta: CGSize, speed: CGFloat) {
        guard session.canControl else {
            // 只能看：单指拖动用来平移放大后的画面（指针跟着 Mac 报回的位置走）。
            viewport.pan(by: delta)
            layoutContent()
            return
        }
        movePointer(by: delta, speed: speed)
    }

    /// 捏合把光标留在了画面外时，让它跟着留在画面边上：否则下一次移动或点击都发生在看不见的地方，
    /// 画面还会被拽回光标那边，刚放大的位置就没了。
    private func keepPointerInView() {
        pointer = Self.pointerKeptInView(pointer, viewport: viewport, canControl: session.canControl,
                                         cursorVisible: macCursorVisible)
        if session.canControl, macCursorVisible, lastSentPointer != pointer { wake() }
    }

    /// 只能看、或光标在别的显示器上时不动它：那时指针跟着 Mac 报回的位置走。
    static func pointerKeptInView(_ pointer: CGPoint, viewport: RemoteDesktopViewport,
                                  canControl: Bool, cursorVisible: Bool) -> CGPoint {
        guard canControl, cursorVisible else { return pointer }
        return viewport.keepingVisible(pointer, margin: pointerMargin)
    }

    private func movePointer(by delta: CGSize, speed: CGFloat) {
        guard delta != .zero else { return }
        pointer = RemoteTrackpad.advance(pointer, by: delta, speed: speed, viewport: viewport)
        viewport.ensureVisible(pointer, margin: Self.pointerMargin)
        macCursorVisible = true
        layoutContent()
        wake()
    }

    /// 点一下 = 按下 + 抬起。连点（0.35 s 内、位置几乎不动）自己数 clickCount，Mac 才认得出双击 / 三击，
    /// 也不用等系统的双击手势判定（那会让每次单击都晚 300 ms）。
    private func click(_ button: RemoteMouseButton) {
        guard session.canControl else { return }
        flushPointer()
        let now = CACurrentMediaTime()
        var count: UInt8 = 1
        if button == .left, let last = lastClick, now - last.time < 0.35,
           hypot(last.point.x - pointer.x, last.point.y - pointer.y) < 0.01 {
            count = min(3, last.count + 1)
        }
        lastClick = button == .left ? (now, pointer, count) : nil
        let modifiers = keys.consume()
        let (x, y) = (Float(pointer.x), Float(pointer.y))
        session.send(.button(button, down: true, clickCount: count, x: x, y: y, modifiers: modifiers))
        session.send(.button(button, down: false, clickCount: count, x: x, y: y, modifiers: modifiers))
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
    }

    /// 按住左键，之后手指移动就是拖拽（选文字、拖窗口），抬手松开。
    private func beginDrag() {
        guard session.canControl else { return }
        flushPointer()
        dragging = true
        dragLocation = nil
        dragEdgeArmed = false
        session.send(.button(.left, down: true, clickCount: 1, x: Float(pointer.x), y: Float(pointer.y),
                             modifiers: keys.modifiers))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func endDrag() {
        guard dragging else { return }
        dragging = false
        dragLocation = nil
        flushPointer()
        session.send(.button(.left, down: false, clickCount: 1, x: Float(pointer.x), y: Float(pointer.y),
                             modifiers: keys.consume()))
    }

    /// 手指停在边缘时光标继续走，放大后才能拖到屏幕外的位置。返回这一帧有没有在走。
    private func stepDragEdge(duration: CFTimeInterval) -> Bool {
        guard dragging, let dragLocation else { return false }
        let velocity = RemoteTrackpad.edgeVelocity(at: dragLocation, in: bounds.size)
        if velocity == .zero {
            dragEdgeArmed = true
            return false
        }
        guard dragEdgeArmed else { return false }
        let dt = CGFloat(max(1.0 / 240, min(1.0 / 30, duration)))
        // 150 点/秒是增益为 1 的速度：自动走的距离不再被慢速减半或加速放大。
        movePointer(by: CGSize(width: velocity.width * dt, height: velocity.height * dt), speed: 150)
        return true
    }

    /// 双指拖动 = 触控板双指滚动（自然方向）：手指移动多少视图点，Mac 上的内容就走多少对应的点。
    private func beginScroll() {
        guard session.canControl else { return }
        scrolling = true
        flushPointer()
        session.send(.scroll(dx: 0, dy: 0, phase: .began))
    }

    private func moveScroll(by delta: CGSize) {
        guard scrolling else { return }
        let scale = max(0.01, viewport.scale)
        session.send(.scroll(dx: Float(delta.width / scale), dy: Float(delta.height / scale), phase: .changed))
    }

    private func finishScroll(velocity: CGPoint) {
        guard scrolling else { return }
        endScroll(phase: .ended)
        let scale = max(0.01, viewport.scale)
        let speed = CGPoint(x: velocity.x / scale, y: velocity.y / scale)
        if hypot(speed.x, speed.y) > 120 {
            momentum = speed
            momentumActive = true
            session.send(.scroll(dx: 0, dy: 0, phase: .momentumBegan))
            wake()
        }
    }

    private func endScroll(phase: RemoteScrollPhase) {
        scrolling = false
        session.send(.scroll(dx: 0, dy: 0, phase: phase))
    }

    /// 所有结束惯性的路径都走这里：Mac 上的 app 要收到结束信号，滚动状态才会复位。
    private func stopMomentum() {
        guard momentumActive else { return }
        momentumActive = false
        session.send(.scroll(dx: 0, dy: 0, phase: .momentumEnded))
    }

    /// 惯性：速度按每秒衰减到约 5%（接近 macOS 触控板的手感），低于阈值结束。
    private func stepMomentum(duration: CFTimeInterval) {
        let dt = CGFloat(max(1.0 / 240, min(1.0 / 30, duration)))
        let decay = pow(0.05, dt)
        momentum = CGPoint(x: momentum.x * decay, y: momentum.y * decay)
        if hypot(momentum.x, momentum.y) < 20 {
            stopMomentum()
            return
        }
        session.send(.scroll(dx: Float(momentum.x * dt), dy: Float(momentum.y * dt), phase: .momentum))
    }

    /// 点击 / 拖拽前先把最新的指针位置发出去（不等下一帧合并），保证点在手指看到的位置上。
    private func flushPointer() {
        guard lastSentPointer != pointer else { return }
        lastSentPointer = pointer
        session.send(.move(x: Float(pointer.x), y: Float(pointer.y)))
    }

    private func send(_ input: RemoteDesktopInput) {
        noteLocalInput()
        stopMomentum()
        session.send(input)
    }

    // MARK: - 键盘

    func setKeyboardVisible(_ visible: Bool) {
        if visible, !keyInput.isFirstResponder {
            _ = keyInput.becomeFirstResponder()
        } else if !visible, keyInput.isFirstResponder {
            keyInput.dismissKeyboard()
            becomeFirstResponder()
        }
    }

    /// 外接键盘（画布是第一响应者时）：按物理键位发 Mac 键码。
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.handle(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.handle(presses, down: false) { super.pressesEnded(presses, with: event) }
    }
}
