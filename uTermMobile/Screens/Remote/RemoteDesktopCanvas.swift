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
        view.onKeyboardDismissed = { keyboardVisible = false }
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
/// - 手势：单指移动指针、单击点按（连点自己数 clickCount）、双指单击右键、双指拖动滚动（松手带惯性）、
///   长按后拖拽（按住左键）、捏合缩放（捏合时双指拖动改为平移画面）。
@MainActor
final class RemoteDesktopCanvasView: UIView, UIGestureRecognizerDelegate {
    private let session: RemoteDesktopSession
    private let keys: RemoteDesktopKeyState
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let cursorLayer = CAShapeLayer()
    private let keyInput = RemoteKeyInputView()
    var fitToken = 0
    var onKeyboardDismissed: (() -> Void)?

    private var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 16, height: 10), viewSize: .zero)
    /// 指针（显示器归一化坐标）。
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var lastSentPointer: CGPoint?
    private var lastLocalInput: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var dragging = false
    private var dragAnchor: CGPoint = .zero
    private var lastClick: (time: CFTimeInterval, point: CGPoint, count: UInt8)?
    private var pinching = false
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
        keyInput.keys = keys
        keyInput.send = { [weak self] input in self?.send(input) }
        keyInput.onResign = { [weak self] in self?.onKeyboardDismissed?() }
        installGestures()
        attachReceiver()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func teardown() {
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
        viewport.clamp()
        layoutContent()
    }

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
        if momentumActive { stepMomentum(duration: link.targetTimestamp - link.timestamp) }
        if lastSentPointer != pointer, session.canControl {
            lastSentPointer = pointer
            session.send(.move(x: Float(pointer.x), y: Float(pointer.y)))
        }
        if !momentumActive && lastSentPointer == pointer { link.isPaused = true }
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

    private func installGestures() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 10
        addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: longPress)
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 双指拖动（滚动）与捏合同时识别：捏合幅度够大才切成缩放 / 平移。
        (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    private func noteLocalInput() {
        lastLocalInput = CACurrentMediaTime()
        momentumActive = false
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        noteLocalInput()
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard session.canControl else {
            // 只能看：单指拖动用来平移放大后的画面（指针跟着 Mac 报回的位置走）。
            viewport.pan(by: CGSize(width: delta.x, height: delta.y))
            layoutContent()
            return
        }
        let velocity = gesture.velocity(in: self)
        movePointer(by: CGSize(width: delta.x, height: delta.y), speed: hypot(velocity.x, velocity.y))
    }

    private func movePointer(by delta: CGSize, speed: CGFloat) {
        guard delta != .zero else { return }
        pointer = RemoteTrackpad.advance(pointer, by: delta, speed: speed, viewport: viewport)
        viewport.ensureVisible(pointer, margin: 48)
        macCursorVisible = true
        layoutContent()
        wake()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        noteLocalInput()
        click(.left)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        noteLocalInput()
        click(.right)
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

    /// 长按：按住左键，之后手指移动就是拖拽（选文字、拖窗口），抬手松开。
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        noteLocalInput()
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard session.canControl else { return }
            flushPointer()
            dragging = true
            dragAnchor = location
            session.send(.button(.left, down: true, clickCount: 1, x: Float(pointer.x), y: Float(pointer.y),
                                 modifiers: keys.modifiers))
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            guard dragging else { return }
            let delta = CGSize(width: location.x - dragAnchor.x, height: location.y - dragAnchor.y)
            dragAnchor = location
            movePointer(by: delta, speed: 0)
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            flushPointer()
            session.send(.button(.left, down: false, clickCount: 1, x: Float(pointer.x), y: Float(pointer.y),
                                 modifiers: keys.consume()))
        default:
            break
        }
    }

    /// 双指拖动 = 触控板双指滚动（自然方向）：手指移动多少视图点，Mac 上的内容就走多少对应的点。
    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        noteLocalInput()
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        if pinching {
            // 捏合中：双指拖动平移画面，而不是滚动 Mac。
            viewport.pan(by: CGSize(width: delta.x, height: delta.y))
            layoutContent()
            if scrolling { endScroll(phase: .ended) }
            return
        }
        guard session.canControl else { return }
        let scale = max(0.01, viewport.scale)
        switch gesture.state {
        case .began:
            scrolling = true
            flushPointer()
            session.send(.scroll(dx: 0, dy: 0, phase: .began))
            fallthrough
        case .changed:
            guard scrolling else { return }
            session.send(.scroll(dx: Float(delta.x / scale), dy: Float(delta.y / scale), phase: .changed))
        case .ended:
            guard scrolling else { return }
            endScroll(phase: .ended)
            let velocity = gesture.velocity(in: self)
            let speed = CGPoint(x: velocity.x / scale, y: velocity.y / scale)
            if hypot(speed.x, speed.y) > 120 {
                momentum = speed
                momentumActive = true
                session.send(.scroll(dx: 0, dy: 0, phase: .momentumBegan))
                wake()
            }
        case .cancelled, .failed:
            if scrolling { endScroll(phase: .ended) }
        default:
            break
        }
    }

    private func endScroll(phase: RemoteScrollPhase) {
        scrolling = false
        session.send(.scroll(dx: 0, dy: 0, phase: phase))
    }

    /// 惯性：速度按每秒衰减到约 5%（接近 macOS 触控板的手感），低于阈值结束。
    private func stepMomentum(duration: CFTimeInterval) {
        let dt = CGFloat(max(1.0 / 240, min(1.0 / 30, duration)))
        let decay = pow(0.05, dt)
        momentum = CGPoint(x: momentum.x * decay, y: momentum.y * decay)
        if hypot(momentum.x, momentum.y) < 20 {
            momentumActive = false
            session.send(.scroll(dx: 0, dy: 0, phase: .momentumEnded))
            return
        }
        session.send(.scroll(dx: Float(momentum.x * dt), dy: Float(momentum.y * dt), phase: .momentum))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinching = false
        case .changed:
            if !pinching, abs(gesture.scale - 1) > 0.08 { pinching = true }
            guard pinching else { return }
            viewport.zoom(by: gesture.scale, anchor: gesture.location(in: self))
            gesture.scale = 1
            layoutContent()
        default:
            pinching = false
        }
    }

    /// 点击 / 拖拽前先把最新的指针位置发出去（不等下一帧合并），保证点在手指看到的位置上。
    private func flushPointer() {
        guard lastSentPointer != pointer else { return }
        lastSentPointer = pointer
        session.send(.move(x: Float(pointer.x), y: Float(pointer.y)))
    }

    private func send(_ input: RemoteDesktopInput) {
        noteLocalInput()
        session.send(input)
    }

    // MARK: - 键盘

    func setKeyboardVisible(_ visible: Bool) {
        if visible, !keyInput.isFirstResponder {
            keyInput.becomeFirstResponder()
        } else if !visible, keyInput.isFirstResponder {
            _ = keyInput.resignFirstResponder()
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

/// 隐藏的文字输入：弹软键盘、收字。外接键盘的物理按键也在这里翻成 Mac 键码。
///
/// 软键盘的字按 US 布局发成按键，交给 Mac 当前的输入法（中文等在 Mac 上组字）；键位表里没有的字符
/// 才按 Unicode 注入。修饰键条上膛时，下一个字符带上修饰（⌘C、⌃A……）。
@MainActor
final class RemoteKeyInputView: UIView, UIKeyInput {
    var keys: RemoteDesktopKeyState?
    var send: ((RemoteDesktopInput) -> Void)?
    var onResign: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    // 远程桌面里自动更正、自动大写、智能标点都只会帮倒忙。
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    /// 英文键盘：字母要按键码发过去交给 Mac 的输入法组字（见 `insertText`）。手机自己的拼音输入法在这里
    /// 用不上——这个视图只有 `UIKeyInput`，没有组字中的 marked text。
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    var hasText: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    /// 软键盘打出的字：US 键位上有的字符（字母、数字、符号、空格）逐个发成**按键**，交给 Mac 当前的输入法——
    /// 开着拼音时就在 Mac 上组字、出候选，用空格 / 数字键选字。键位表里没有的字符（emoji 等）才按 Unicode
    /// 直接注入。上膛的修饰键只作用于第一个字符（⌘C、⌃A……）。
    func insertText(_ text: String) {
        var modifiers = keys?.consume() ?? []
        var unmapped = ""
        func flushUnmapped() {
            guard !unmapped.isEmpty else { return }
            send?(.text(unmapped))
            unmapped = ""
        }
        for character in text {
            if character == "\n" {
                flushUnmapped()
                tap(RemoteKeyMap.Key.returnKey, modifiers: modifiers)
            } else if let mapped = RemoteKeyMap.keyCode(for: character) {
                flushUnmapped()
                tap(mapped.code, modifiers: mapped.shift ? modifiers.union(.shift) : modifiers)
            } else {
                unmapped.append(character)
            }
            modifiers = []
        }
        flushUnmapped()
    }

    func deleteBackward() {
        tap(RemoteKeyMap.Key.delete, modifiers: keys?.consume() ?? [])
    }

    func tap(_ code: UInt16, modifiers: RemoteKeyModifiers) {
        send?(.key(code: code, down: true, modifiers: modifiers))
        send?(.key(code: code, down: false, modifiers: modifiers))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    /// 外接键盘：HID 键位 → Mac 键码，修饰取按键自带的状态并上键盘条上膛的。返回 false = 不认识，交还系统。
    func handle(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            // 修饰键本身不单独发：修饰状态随每个按键一起带过去。
            if (0xE0...0xE7).contains(key.keyCode.rawValue) {
                handled = true
                continue
            }
            guard let code = RemoteKeyMap.keyCode(hidUsage: key.keyCode.rawValue) else { continue }
            var modifiers = Self.modifiers(key.modifierFlags)
            if down { modifiers.formUnion(keys?.consume() ?? []) }
            send?(.key(code: code, down: down, modifiers: modifiers))
            handled = true
        }
        return handled
    }

    static func modifiers(_ flags: UIKeyModifierFlags) -> RemoteKeyModifiers {
        var result: RemoteKeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.alphaShift) { result.insert(.capsLock) }
        return result
    }
}
