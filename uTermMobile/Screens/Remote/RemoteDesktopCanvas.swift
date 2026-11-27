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
    /// 用户点了系统键盘自带的「粘贴」：按「粘贴到 Mac」处理。
    var onSystemPaste: () -> Void = {}
    /// 递增一次 = 回到「适配屏幕」。
    let fitToken: Int
    /// Mac 显示器的点尺寸（开流后才有）。作为参数传进来，SwiftUI 才会在它变化时调 `updateUIView`。
    let displaySize: CGSize?
    /// 内容占视频帧的比例（只看一个窗口时可能小于 1，见 `RemoteDesktopSession.contentFraction`）。
    var contentFraction = CGSize(width: 1, height: 1)
    /// 触摸屏模式：点哪里就是哪里、不画指针（见 `RemoteTrackpadGesture.Mode.touch`）。
    var touchMode = false
    /// 键盘触控板（长按空格键滑动）移动什么。触摸屏模式下没有指针，一律移动文字光标。
    var keyboardTrackpad: RemoteKeyboardTrackpadMode = .defaultValue
    /// 视频帧的像素尺寸（开流后才有）。画面接近一比一时按它排（`RemoteDesktopViewport.nativeSize`）。
    var streamPixels: CGSize?

    func makeUIView(context: Context) -> RemoteDesktopCanvasView {
        let view = RemoteDesktopCanvasView(session: session, keys: keys)
        // 键盘可能在 SwiftUI 更新期间被收走（拆视图时 UIKit 卸第一响应者），不能当场写状态。
        view.onKeyboardDismissed = { DispatchQueue.main.async { keyboardVisible = false } }
        view.onSystemPaste = onSystemPaste
        return view
    }

    func updateUIView(_ view: RemoteDesktopCanvasView, context: Context) {
        view.setKeyboardVisible(keyboardVisible)
        if view.fitToken != fitToken {
            view.fitToken = fitToken
            view.resetViewport()
        }
        view.updateContentSize(displaySize)
        view.updateContentFraction(contentFraction)
        view.updateStreamPixels(streamPixels)
        view.setTouchMode(touchMode)
        view.setKeyboardTrackpad(touchMode ? .caret : keyboardTrackpad)
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
/// - 触摸屏模式（`setTouchMode`）：不画光标，手势先把指针放到手指的位置（`pointerJumped`）再点、拖、滚。
@MainActor
final class RemoteDesktopCanvasView: UIView {
    private let session: RemoteDesktopSession
    private let keys: RemoteDesktopKeyState
    private let displayLayer = AVSampleBufferDisplayLayer()
    /// 画面挂在这个视图上（位置大小 = `displayedFrame`）。iOS 26 起它是 `extensionView` 的内容视图。
    private let pictureView = UIView()
    private var contentFraction = CGSize(width: 1, height: 1)
    /// 放大后 Mac 只送来看得见的那一块（按原生像素）：画在这层里面，盖住下面那张整块的。它是单位坐标的图层，
    /// 里面的画面摆在哪儿由每帧自己带的区域定（`RemoteDesktopRegionStage`）。
    private let regionSpace = CALayer()
    /// 画面的像素比屏幕上要显示的少时（窗口模式：Mac 每点 2 像素，手机 3 像素）先放大到位再显示。
    private let upscaler = RemoteDesktopUpscaler()
    /// 向 Mac 报「此刻看得见哪一块」：停稳一小会儿才报，拖着不放时隔一段也报一次。
    private var regionReport: DispatchWorkItem?
    private var lastRegionReport = Date.distantPast
    static let regionSettle: TimeInterval = 0.12
    static let regionMaxWait: TimeInterval = 0.3
    /// 角落让开（画面朝对角缩小）时空出来的那两条窄缝用画面自己的边延伸补满（系统的背景延伸：边缘镜像再模糊），
    /// 不露黑底。它的范围是「不让开时的画面 ∪ 让开后的画面」：平时两者重合、什么也不补（系统也不挂镜像和模糊层，
    /// 见 `BackgroundExtensionProbeTests`），看真显示器留的黑边照旧是黑的；只有让开时空出的缝在它的范围里。
    /// iOS 26 之前没有，缝是黑的。
    private var extensionView: UIView?
    private let cursorLayer = CAShapeLayer()
    private let keyInput = RemoteKeyInputView()
    /// 量画布四角落在多大的屏幕圆角里（见 `screenCornerRadius`）。不画东西、不接触摸。
    private let cornerProbe = UIView()
    var fitToken = 0
    var onKeyboardDismissed: (() -> Void)?
    var onSystemPaste: (() -> Void)?

    /// 放大后光标离画面边缘至少留这么多（视图点）。
    private static let pointerMargin: CGFloat = 48

    private var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 16, height: 10), viewSize: .zero,
                                                 bleedsIntoCorners: true)
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
        pictureView.isUserInteractionEnabled = false
        pictureView.layer.addSublayer(displayLayer)
        pictureView.layer.addSublayer(regionSpace)
        if #available(iOS 26.0, *) {
            let extensionView = UIBackgroundExtensionView()
            extensionView.isUserInteractionEnabled = false
            extensionView.automaticallyPlacesContentView = false
            extensionView.contentView = pictureView
            addSubview(extensionView)
            self.extensionView = extensionView
        } else {
            addSubview(pictureView)
        }
        cursorLayer.path = RemoteDesktopArrowCursor.path()
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
        keyInput.onPaste = { [weak self] in self?.onSystemPaste?() }
        keyInput.movePointer = { [weak self] delta, speed in self?.moveWithKeyboardTrackpad(by: delta, speed: speed) }
        session.attachCanvas(displayLayer, regionSpace: regionSpace, upscaler: upscaler) { [weak self] cursor in
            self?.macCursor(cursor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func teardown() {
        apply(gesture.cancel())
        stopMomentum()
        displayLink?.invalidate()
        displayLink = nil
        regionReport?.cancel()
        session.detachCanvas()
    }

    // MARK: - 布局

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startDisplayLink()
            // 外接键盘（iPad）：画布自己当第一响应者，不弹软键盘也能收到按键。视图是在 SwiftUI 更新途中挂上来的，
            // 同样不当场换（见 `setKeyboardVisible`）。
            claimsResponder = true
            queueResponderChange()
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
        viewport.corners = screenCorners()
        viewport.clamp()
        layoutContent()
        keyInput.frame = CGRect(x: 0, y: max(0, bounds.height - 48), width: bounds.width, height: min(48, bounds.height))
    }

    /// 画布四个角各自落在多大的屏幕圆角里：画布铺到屏幕边，角（键盘条收起时是下面两个）正是屏幕的
    /// 物理圆角。「适配屏幕」留着黑边时把画面往黑边里挪、让角躲开弧线（`RemoteDesktopCornerFit`）；
    /// 挪不开（画面正好铺满画布，比如无显示器的 Mac 按画布比例建的虚拟屏）就贴边铺满，角由屏幕自己切
    /// （`bleedsIntoCorners`）。
    ///
    /// iOS 26 起用系统的同心圆角：探针视图与画布同框，`containerConcentric` 给出每个角离屏幕圆角
    /// 还剩多大的半径（不在屏幕角上的角是 0）。在 `layoutSubviews` 里读，变了系统会再排一次版。
    /// 更早的系统没有这个接口：画布的角贴着屏幕的角、且屏幕有 Home 条（全面屏）时按 55pt 算。
    private func screenCorners() -> RemoteDesktopCornerRadii {
        if #available(iOS 26.0, *) {
            return RemoteDesktopCornerRadii(topLeft: cornerProbe.effectiveRadius(corner: .topLeft),
                                            topRight: cornerProbe.effectiveRadius(corner: .topRight),
                                            bottomLeft: cornerProbe.effectiveRadius(corner: .bottomLeft),
                                            bottomRight: cornerProbe.effectiveRadius(corner: .bottomRight))
        }
        guard let window, window.safeAreaInsets.bottom > 0 else { return .square }
        let frame = convert(bounds, to: window)
        let screen = window.bounds
        let top = abs(frame.minY - screen.minY) < 1, bottom = abs(frame.maxY - screen.maxY) < 1
        let left = abs(frame.minX - screen.minX) < 1, right = abs(frame.maxX - screen.maxX) < 1
        let r = Self.legacyScreenCornerRadius
        return RemoteDesktopCornerRadii(topLeft: top && left ? r : 0, topRight: top && right ? r : 0,
                                        bottomLeft: bottom && left ? r : 0, bottomRight: bottom && right ? r : 0)
    }

    private static let legacyScreenCornerRadius: CGFloat = 55

    func updateContentSize(_ size: CGSize?) {
        guard let size, size.width > 0, size.height > 0, size != viewport.contentSize else { return }
        viewport.contentSize = size
        viewport.clamp()
        layoutContent()
    }

    /// 视频帧里只有左上角这一部分是内容：把视频层按比例放大、让内容正好铺满画面区域，多出来的由画面区域裁掉。
    func updateContentFraction(_ fraction: CGSize) {
        guard fraction.width > 0, fraction.height > 0, fraction != contentFraction else { return }
        contentFraction = fraction
        pictureView.clipsToBounds = fraction.width < 1 || fraction.height < 1
        updateNativeSize()
        layoutContent()
    }

    func resetViewport() {
        viewport.reset()
        layoutContent()
    }

    private var streamPixels: CGSize?

    /// 视频帧有多少像素。画面里内容的像素数和屏幕上要占的像素数只差一丝时，按原生像素一比一排（不拉伸）。
    func updateStreamPixels(_ pixels: CGSize?) {
        guard pixels != streamPixels else { return }
        streamPixels = pixels
        updateNativeSize()
        layoutContent()
    }

    private func updateNativeSize() {
        let scale = traitCollection.displayScale
        viewport.pixelsPerPoint = scale
        guard let streamPixels, streamPixels.width > 0, streamPixels.height > 0, scale > 0 else {
            viewport.nativeSize = nil
            return
        }
        viewport.nativeSize = CGSize(width: streamPixels.width * contentFraction.width / scale,
                                     height: streamPixels.height * contentFraction.height / scale)
    }

    /// 换操作方式：进行到一半的手势先收尾（松开按着的左键、结束滚动），再换判定规则。
    func setTouchMode(_ enabled: Bool) {
        guard enabled != touchMode else { return }
        apply(gesture.cancel())
        gesture.mode = enabled ? .touch : .trackpad
        layoutContent()
    }

    private var touchMode: Bool { gesture.mode == .touch }

    func setKeyboardTrackpad(_ mode: RemoteKeyboardTrackpadMode) {
        keyInput.trackpadMode = mode
    }

    /// 键盘触控板移动指针：和单指滑动同一条路（本地先动光标，之后按帧发给 Mac）。
    private func moveWithKeyboardTrackpad(by delta: CGSize, speed: CGFloat) {
        noteLocalInput()
        stopMomentum()
        moveOrPan(by: delta, speed: speed)
    }

    // MARK: - 放大后要区域

    /// 视口变了（捏合、拖动、转屏）：停稳 `regionSettle` 后把看得见的那一块报给 Mac；一直在动时最多隔 `regionMaxWait` 报一次。
    private func reportVisibleRegionSoon() {
        guard session.supportsRegions else { return }
        regionReport?.cancel()
        if Date().timeIntervalSince(lastRegionReport) >= Self.regionMaxWait {
            reportVisibleRegion()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.reportVisibleRegion() }
        regionReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.regionSettle, execute: work)
    }

    private func reportVisibleRegion() {
        lastRegionReport = Date()
        session.requestRegion(RemoteDesktopRegionPolicy.visibleRegion(picture: viewport.displayedFrame, view: bounds,
                                                                      zoom: viewport.zoom))
    }

    /// 整帧画面没放大（捏合之前）时在屏幕上占多少像素，报给放大器：不够密的画面它先放大到这么大。
    /// 按没有捏合、没有让角时的大小算，这两样在动的时候不让它跟着换尺寸。
    private func reportDisplayPixels() {
        let fitted = viewport.contentFrame.size
        let zoom = max(1, viewport.zoom)
        let scale = traitCollection.displayScale
        upscaler.setDisplayPixels(width: Int((fitted.width / zoom / contentFraction.width * scale).rounded()),
                                  height: Int((fitted.height / zoom / contentFraction.height * scale).rounded()))
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = viewport.displayedFrame
        if let extensionView {
            let area = viewport.contentFrame.union(frame)
            extensionView.frame = area
            pictureView.frame = frame.offsetBy(dx: -area.minX, dy: -area.minY)
        } else {
            pictureView.frame = frame
        }
        displayLayer.frame = CGRect(x: 0, y: 0, width: pictureView.bounds.width / contentFraction.width,
                                    height: pictureView.bounds.height / contentFraction.height)
        displayLayer.applyRemoteDesktopCorners(viewport.pictureCorners)
        reportDisplayPixels()
        RemoteDesktopRegionPlacement.layout(regionSpace, in: pictureView.bounds)
        reportVisibleRegionSoon()
        cursorLayer.position = CGPoint(x: frame.minX + pointer.x * frame.width, y: frame.minY + pointer.y * frame.height)
        cursorLayer.isHidden = session.info == nil || !macCursorVisible || touchMode
        CATransaction.commit()
        if peekTarget != viewport.peekInsets { wake() }
    }

    /// 指针在被屏幕圆角切掉的角上时画面四边该收多少（见 `RemoteDesktopViewport.cornerPeek`）。
    /// 光标藏着（在别的显示器上 / 还没开流）时不收。
    private var peekTarget: RemoteDesktopEdgeInsets {
        // 触摸屏模式没有光标可让。
        guard session.info != nil, macCursorVisible, !touchMode else { return .zero }
        return viewport.cornerPeek(for: pointer)
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
        let peekBefore = viewport.peekInsets
        let peeking = viewport.stepPeek(toward: peekTarget, duration: duration)
        if viewport.peekInsets != peekBefore { layoutContent() }
        if lastSentPointer != pointer, session.canControl {
            lastSentPointer = pointer
            session.send(.move(x: Float(pointer.x), y: Float(pointer.y)))
        }
        if !momentumActive && !edgeMoving && !peeking && !gesture.needsTick && lastSentPointer == pointer {
            link.isPaused = true
        }
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
        case .swiped(let direction):
            swipe(direction)
        case .pointerJumped(let point):
            jumpPointer(to: point)
        }
    }

    /// 触摸屏模式：指针直接到手指的位置（落在画面外的收到画面边上）。只能看时不动。
    private func jumpPointer(to point: CGPoint) {
        guard session.canControl else { return }
        let target = Self.pointer(at: point, picture: viewport.displayedFrame)
        guard target != pointer else { return }
        pointer = target
        macCursorVisible = true
        wake()
    }

    /// 视图上的一点对应画面里的哪儿（归一化坐标，收在 0…1 里）。
    static func pointer(at point: CGPoint, picture: CGRect) -> CGPoint {
        guard picture.width > 0, picture.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(1, max(0, (point.x - picture.minX) / picture.width)),
                       y: min(1, max(0, (point.y - picture.minY) / picture.height)))
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
        // 触摸屏模式没有光标，指针下一次用之前总会先放到手指的位置。
        guard !touchMode else { return }
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
        if button == .left, let last = lastClick, now - last.time < 0.35, isRepeat(of: last.point) {
            count = min(3, last.count + 1)
            // 触摸屏模式下连点的几下手指落点差着几个点：都点在第一下的位置，双击才落在同一个目标上。
            if touchMode { pointer = last.point }
            flushPointer()
        }
        lastClick = button == .left ? (now, pointer, count) : nil
        let modifiers = keys.consume()
        let (x, y) = (Float(pointer.x), Float(pointer.y))
        session.send(.button(button, down: true, clickCount: count, x: x, y: y, modifiers: modifiers))
        session.send(.button(button, down: false, clickCount: count, x: x, y: y, modifiers: modifiers))
        MHaptics.press(intensity: 0.5)
    }

    /// 这一下和上一下点的是不是同一个地方。触控板模式下指针没动才算（差不到画面的 1%）；
    /// 触摸屏模式下每一下都是手指重新落的，落点差在 `touchRepeatRadius` 以内都算。
    private func isRepeat(of last: CGPoint) -> Bool {
        guard touchMode else { return hypot(last.x - pointer.x, last.y - pointer.y) < 0.01 }
        let frame = viewport.displayedFrame
        return hypot((last.x - pointer.x) * frame.width, (last.y - pointer.y) * frame.height) < Self.touchRepeatRadius
    }

    /// 触摸屏模式下连点的落点差在这么多视图点以内算同一处（系统双击手势的容差也在这个量级）。
    static let touchRepeatRadius: CGFloat = 28

    /// 按住左键，之后手指移动就是拖拽（选文字、拖窗口），抬手松开。
    private func beginDrag() {
        guard session.canControl else { return }
        flushPointer()
        dragging = true
        dragLocation = nil
        dragEdgeArmed = false
        session.send(.button(.left, down: true, clickCount: 1, x: Float(pointer.x), y: Float(pointer.y),
                             modifiers: keys.modifiers))
        MHaptics.emphasis()
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
        guard scrolling else {
            // 只能看时触摸屏模式的单指拖动没有别的用处：拿来平移放大后的画面（触控板模式下是单指移动在平移）。
            if touchMode, !session.canControl {
                viewport.pan(by: delta)
                layoutContent()
            }
            return
        }
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
    /// 三指扫动 = Mac 触控板的三指扫动：按对应的系统快捷键（见 `RemoteSwipeDirection.shortcut`）。
    /// 不吃键盘条上了膛的修饰键：再叠一个 ⌥ / ⌘ 就不是那个快捷键了。
    private func swipe(_ direction: RemoteSwipeDirection) {
        guard session.canControl else { return }
        let (code, modifiers) = direction.shortcut
        send(.key(code: code, down: true, modifiers: modifiers))
        send(.key(code: code, down: false, modifiers: modifiers))
        MHaptics.press(intensity: 0.5)
    }

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

    /// 外面要软键盘弹着还是收着。
    private var wantsKeyboard = false
    private var responderChangeQueued = false
    /// 刚挂上窗口：画布要当一次第一响应者。
    private var claimsResponder = false

    /// 软键盘弹不弹。只记下要的状态，这一轮主线程任务跑完再换第一响应者，**不能当场换**：
    /// 调用方是 `updateUIView`，那时 SwiftUI 正在更新；换第一响应者时 UIKit 顺着视图树通知到 SwiftUI 的宿主视图，
    /// 它当场去读图上的值，AttributeGraph 判成环，主线程就在 `AG::Graph::print_cycle` 里空转，触摸全无反应、
    /// 画面照常在放（解码不经主线程）。2026-11-18 Duo 窗口模式下点键盘按钮撞到，系统的 CPU 报告里 90 秒都停在
    /// `updateUIView` → `setKeyboardVisible` → `becomeFirstResponder` → `print_cycle`。
    func setKeyboardVisible(_ visible: Bool) {
        wantsKeyboard = visible
        guard visible != keyInput.isFirstResponder else { return }
        queueResponderChange()
    }

    private func queueResponderChange() {
        guard !responderChangeQueued else { return }
        responderChangeQueued = true
        DispatchQueue.main.async { [weak self] in self?.applyResponder() }
    }

    /// 按 `wantsKeyboard` 摆第一响应者：要软键盘就是输入视图；不要就是画布自己（外接键盘不弹软键盘也能收到按键）。
    private func applyResponder() {
        responderChangeQueued = false
        defer { claimsResponder = false }
        guard window != nil else { return }
        if wantsKeyboard {
            if !keyInput.isFirstResponder { _ = keyInput.becomeFirstResponder() }
        } else {
            // 只在刚挂上窗口、或刚从输入视图手里收回时才拿：别的时候第一响应者可能是弹层里的输入框，不能抢。
            let wasTyping = keyInput.isFirstResponder
            if wasTyping { keyInput.dismissKeyboard() }
            if wasTyping || claimsResponder, !isFirstResponder { becomeFirstResponder() }
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
