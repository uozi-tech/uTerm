import AppKit
import CoreGraphics
import Foundation

/// 只看一个窗口时，把鼠标键盘直接投给这个窗口所在的进程（`CGEvent.postToPid`），不走全局输入通道。
///
/// 全局通道（`.cghidEventTap`）等于真的动了鼠标：Mac 上的指针被挪过去，点击落在那个位置最上面的窗口上——要看的窗口
/// 一被盖住就点到别人头上，坐在 Mac 前的人也没法同时用自己的键鼠（2026-11-18 user 反馈，要求像 Computer Use 那样
/// 鼠标、输入各管各的）。按进程投递时真实指针不动、前台 App 不变，被整个盖住的窗口照样收得到。
///
/// 2026-11-18 探针（macOS 27.2.1；带沙盒、用远控进程的身份签名；目标是后台的原生窗口和后台的 Chrome）：
/// - **鼠标和滚轮要带窗口寻址**，缺一样目标就收不到：公开字段「指针下的窗口」两个 + 目标进程号，私有字段 51（窗口号），
///   再加 `CGEventSetWindowLocation`（私有，窗口内坐标、左上角原点）。只设公开字段时只有指针移动能到。
///   （网上的做法还把私有字段 58 设成 1。那个字段就是事件的时间戳——照做等于把时间戳写成 1 纳秒，这里不设。）
/// - **键盘不用寻址**，直接到目标的第一响应者。
/// - **不接受「激活窗口的那一下点击」的视图**（系统文本框、列表）在后台点不动：先发一个 AppKit 内部的「App 被激活了」
///   事件（`appKitDefined`、子类型 1），再在窗口外（窗口内坐标 -1, -1）垫一下点击把「首次点击」吃掉，之后的点击、
///   按 Unicode 送的文字（中文）都正常。目标自以为是当前 App（窗口画成激活的样子），系统那边前台 App 没变，
///   Mac 上的实体键盘仍然打到真正的前台 App 里。Chrome 里按键和点击不激活也到，文字和右键菜单要激活。
/// - **重复发「激活」目标每次都会再收到一遍激活通知**，所以只在必要时发一次：目标真的当过前台 App 又被切走后才再发。
/// - **弹出的菜单是另一个窗口**：事件要寻址到菜单自己的窗口号、用它的窗口内坐标，寻址到主窗口只会把菜单关掉。
/// - 事件可以背靠背发，不用留间隔。标题栏上拖动窗口不会动。
///
/// 同一天的「按钮矩阵」（user 要求各种奇怪的按钮实现都要点得到；目标窗口在后台）：系统按钮、复选框、分段控件、开关、
/// 步进器、滑块拖动、弹出按钮选菜单项、SwiftUI 的 Button / Toggle / onTapGesture、`NSClickGestureRecognizer`、
/// 自己跑事件循环等抬起的自绘按钮（按事件里的位置判断时）都点得动。为了像真鼠标，这里另外补三样：
/// - **时间戳**：每个事件都写上当前时间。按时间戳算按了多久、手势速度、双击间隔的实现要它是对的
///   （探针里照网上的做法设了字段 58，时间戳成了 1 纳秒，「按了多久」算出来是负的两天）。
/// - **按下之前先移过去**：真鼠标总是先到再按。触摸屏模式下一点就是按下，目标没见过指针到那儿。
/// - **至少按住 `minimumPressNanos`**：手机上的一下轻点是按下、抬起紧挨着发的，按帧轮询状态的实现会漏掉。
///
/// **点不动的三类**（它们问的是系统的真实指针，按进程投递改不了，只能关掉独立键鼠走全局通道）：
/// - 抬起时用真实指针位置判断还在不在按钮里的（`mouseLocationOutsideOfEventStream`、`NSEvent.mouseLocation`）；
/// - 读全局按键状态的（`NSEvent.pressedMouseButtons`、`CGEventSource.buttonState`）；
/// - 靠系统的悬停通知（跟踪区域的 `mouseEntered`）才显示或才响应的原生控件——投过去的移动事件不触发它。
///   网页里的悬停不受影响（浏览器自己按收到的移动事件算）。
///
/// 这套做法用了私有字段，有的 App 可能不吃（游戏、自己读全局指针位置的），所以主控端留了开关，关掉就回到全局通道。
///
/// 鼠标键盘的投递都在连接队列上调用；前台 App 的变化在主线程上报进来，共用的两个标记加锁。
nonisolated final class RemoteWindowInputTarget: @unchecked Sendable {
    typealias Window = RemoteDesktopWindows.Entry

    /// 鼠标事件在一次按键里的位置。
    enum MousePhase: Sendable {
        /// 没按着键的移动。
        case hover
        case down
        case drag
        case up
    }

    /// 外部依赖：生产是系统窗口表和 `postToPid`，测试换成记录器。
    struct Hooks: Sendable {
        /// 这个进程此刻在屏幕上的全部窗口（含菜单、浮层），最上面的在前。
        var windows: @Sendable (_ pid: pid_t) -> [Window]
        /// 一个窗口此刻的那一行（不在屏幕上的也算：最小化、别的桌面）。
        var window: @Sendable (_ id: UInt32) -> Window?
        var post: @Sendable (_ event: CGEvent, _ pid: pid_t) -> Void
        /// 写窗口内坐标（私有接口）。
        var setWindowLocation: @Sendable (_ event: CGEvent, _ point: CGPoint) -> Void
        /// 开机以来的纳秒数（不含睡眠），和事件时间戳同一个钟。
        var now: @Sendable () -> UInt64
        /// 原地等这么多纳秒。
        var sleep: @Sendable (_ nanos: UInt64) -> Void

        static func live(setWindowLocation: @escaping @Sendable (CGEvent, CGPoint) -> Void) -> Hooks {
            Hooks(windows: { RemoteDesktopWindows.windows(ofPID: $0) },
                  window: { RemoteDesktopWindows.entry(id: $0) },
                  post: { event, pid in event.postToPid(pid) },
                  setWindowLocation: setWindowLocation,
                  now: { DispatchTime.now().uptimeNanoseconds },
                  sleep: { usleep(UInt32(min($0 / 1000, 1_000_000))) })
        }
    }

    /// 私有字段：窗口号。
    static let windowNumberField = CGEventField(rawValue: 51)
    /// 没按着键的移动、滚轮沿用上一次查到的窗口表多久。按下时总是重新查。
    static let windowListLifetimeNanos: UInt64 = 250_000_000
    /// 排在前面的普通窗口，面积不超过看的窗口的这么多才算它的附属（sheet、弹出面板）。同样大小、叠在同一个位置的
    /// 是同一个 App 的另一个窗口（两个浏览器窗口叠着很常见；2026-11-18 探针里点击就这样被发到了错的窗口）。
    static let attachmentAreaLimit = 0.85
    /// 一次按键至少按住这么久才抬起（手机上的轻点是按下、抬起紧挨着发的）。在连接队列上等，所以取得很短。
    static let minimumPressNanos: UInt64 = 30_000_000
    /// 垫的那一下点在窗口内坐标的这里：窗口外面，谁也点不到。
    static let primerPoint = CGPoint(x: -1, y: -1)

    let windowID: UInt32
    let pid: pid_t
    private let hooks: Hooks
    private let source: CGEventSource?
    private let lock = NSLock()
    /// 目标是不是系统那边真正的前台 App（这时它本来就是激活的，不用我们发）。
    private var isFront: Bool
    /// 我们发过「激活」，而且之后目标没有真的当过前台 App 又被切走。
    private var primed = false
    // 以下只在连接队列上读写。
    private var cached: (windows: [Window], at: UInt64)?
    /// 这次按键落在哪个窗口上：拖动和抬起沿用它。
    private var captured: Window?
    /// 上一个鼠标事件投在哪儿（全局坐标）；还没投过是 nil。
    private var lastMousePoint: CGPoint?
    /// 这次按键是什么时候按下的。
    private var pressedAt: UInt64?
    private var primerNumber: Int64 = 1 << 40
    private var observers: [NSObjectProtocol] = []

    init(windowID: UInt32, pid: pid_t, isFront: Bool, source: CGEventSource?, hooks: Hooks) {
        self.windowID = windowID
        self.pid = pid
        self.isFront = isFront
        self.source = source
        self.hooks = hooks
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// `CGEventSetWindowLocation`：私有接口，运行时找，找不到（以后的系统拿掉了）就不走按进程投递。
    static let windowLocationSetter: (@Sendable (CGEvent, CGPoint) -> Void)? = {
        // RTLD_DEFAULT
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        typealias Setter = @convention(c) (CGEvent, CGPoint) -> Void
        let setter = unsafeBitCast(symbol, to: Setter.self)
        return { event, point in setter(event, point) }
    }()

    /// 给这个窗口建投递目标。建不了返回 nil（调用方退回全局通道）：窗口没了、是本进程自己的窗口
    /// （服务跑在 uTerm 主程序里、看的正是 uTerm 的窗口）、系统里找不到那个私有接口。
    @MainActor
    static func live(windowID: UInt32, source: CGEventSource?) -> RemoteWindowInputTarget? {
        guard let setter = windowLocationSetter, windowNumberField != nil else {
            AppLogger.notice("远程桌面：系统里找不到按窗口投递事件要的接口，输入改走全局通道", category: RemoteLog.category)
            return nil
        }
        guard let entry = RemoteDesktopWindows.entry(id: windowID),
              entry.pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let target = RemoteWindowInputTarget(
            windowID: windowID, pid: entry.pid,
            isFront: NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid,
            source: source, hooks: .live(setWindowLocation: setter))
        target.observers = [NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak target] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            target?.frontApplicationChanged(to: app.processIdentifier)
        }]
        return target
    }

    /// 系统的前台 App 换了。目标当上或者让出前台，我们之前发的「激活」都不算数了。
    func frontApplicationChanged(to front: pid_t) {
        lock.withLock {
            let nowFront = front == pid
            guard nowFront != isFront else { return }
            isFront = nowFront
            primed = false
        }
    }

    // MARK: - 投递

    func deliverMouse(_ event: CGEvent, at point: CGPoint, phase: MousePhase) {
        let window: Window?
        switch phase {
        case .down:
            primeIfNeeded()
            window = resolve(point, fresh: true)
            captured = window
            if let window { approach(point, in: window) }
            pressedAt = hooks.now()
        case .drag:
            window = captured ?? resolve(point, fresh: false)
        case .up:
            window = captured ?? resolve(point, fresh: false)
            captured = nil
            if let pressedAt {
                let held = hooks.now() &- pressedAt
                if held < Self.minimumPressNanos { hooks.sleep(Self.minimumPressNanos - held) }
            }
            pressedAt = nil
        case .hover:
            window = resolve(point, fresh: false)
        }
        guard let window else { return }
        event.setDoubleValueField(.mouseEventPressure, value: phase == .down || phase == .drag ? 1 : 0)
        address(event, to: window, at: point)
        post(event)
        lastMousePoint = point
    }

    func deliverScroll(_ event: CGEvent, at point: CGPoint) {
        guard let window = resolve(point, fresh: false) else { return }
        address(event, to: window, at: point)
        post(event)
    }

    func deliverKey(_ event: CGEvent) {
        primeIfNeeded()
        post(event)
    }

    /// 按下之前指针还不在这个点上：先投一个移到这儿的事件。
    private func approach(_ point: CGPoint, in window: Window) {
        if let lastMousePoint, abs(lastMousePoint.x - point.x) < 0.5, abs(lastMousePoint.y - point.y) < 0.5 { return }
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                                 mouseButton: .left) else { return }
        address(move, to: window, at: point)
        post(move)
    }

    /// 写上当前时间再投。
    private func post(_ event: CGEvent) {
        event.timestamp = hooks.now()
        hooks.post(event, pid)
    }

    /// 不看这个窗口了：我们让目标以为自己是当前 App 的，告诉它不是了（窗口画回没激活的样子）。
    func finish() {
        let undo = lock.withLock {
            defer { primed = false }
            return primed && !isFront
        }
        captured = nil
        pressedAt = nil
        guard undo, let event = Self.activationEvent(active: false, windowID: windowID) else { return }
        addressFields(event, windowID: windowID)
        post(event)
    }

    // MARK: - 激活

    private func primeIfNeeded() {
        let needed = lock.withLock {
            guard !isFront, !primed else { return false }
            primed = true
            return true
        }
        guard needed, let main = hooks.window(windowID) else { return }
        if let activation = Self.activationEvent(active: true, windowID: windowID) {
            addressFields(activation, windowID: windowID)
            post(activation)
        }
        // 「激活」之后的第一下按下会被当成「激活窗口的那一下」，不接受它的视图直接丢掉：先在窗口外面垫一下。
        primerNumber += 1
        let outside = CGPoint(x: main.bounds.minX + Self.primerPoint.x, y: main.bounds.minY + Self.primerPoint.y)
        for (type, pressure) in [(CGEventType.leftMouseDown, 1.0), (.leftMouseUp, 0.0)] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: outside,
                                      mouseButton: .left) else { continue }
            event.setIntegerValueField(.mouseEventNumber, value: primerNumber)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setDoubleValueField(.mouseEventPressure, value: pressure)
            address(event, to: main, at: outside)
            post(event)
        }
    }

    /// AppKit 内部的「App 被激活了 / 退到后台了」事件（`appKitDefined`，子类型 1 / 2）。
    static func activationEvent(active: Bool, windowID: UInt32) -> CGEvent? {
        NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowID),
                           context: nil, subtype: active ? 1 : 2, data1: 0, data2: 0)?.cgEvent
    }

    // MARK: - 寻址

    private func address(_ event: CGEvent, to window: Window, at point: CGPoint) {
        addressFields(event, windowID: window.id)
        hooks.setWindowLocation(event, CGPoint(x: point.x - window.bounds.minX, y: point.y - window.bounds.minY))
    }

    private func addressFields(_ event: CGEvent, windowID: UInt32) {
        let number = Int64(windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: number)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: number)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        if let field = Self.windowNumberField { event.setIntegerValueField(field, value: number) }
    }

    /// 这个点该投给目标进程的哪个窗口：菜单、弹出的面板在上面就给它们，否则给看的那个窗口。
    private func resolve(_ point: CGPoint, fresh: Bool) -> Window? {
        let now = hooks.now()
        let windows: [Window]
        if !fresh, let cached, now &- cached.at < Self.windowListLifetimeNanos {
            windows = cached.windows
        } else {
            windows = hooks.windows(pid)
            cached = (windows, now)
        }
        // 看的窗口不在屏幕上（别的桌面、最小化）时窗口表里没有它：照它最后的位置投。
        return Self.resolve(point: point, main: windowID, in: windows) ?? hooks.window(windowID)
    }

    /// 纯规则：`windows` 是目标进程在屏幕上的窗口（最上面的在前）。
    ///
    /// 排在看的窗口前面、盖着这个点的，只认「附属」的：菜单和浮层（层级不是 0），或者明显比看的窗口小
    /// （`attachmentAreaLimit`）、中心落在它里面的普通窗口（sheet、弹出面板、补全列表）。同一个 App 的另一个文档窗口
    /// 碰巧盖在上面时不认——画面里没有它，点击要落到看的窗口上。系统窗口表不给父子关系，只能按大小和位置猜：
    /// 同一个 App 的一个小窗口整个叠在看的窗口里面时会被认成附属。看的窗口不在表里返回 nil。
    static func resolve(point: CGPoint, main: UInt32, in windows: [Window]) -> Window? {
        guard let index = windows.firstIndex(where: { $0.id == main }) else { return nil }
        let target = windows[index]
        let attached = windows[..<index].first { window in
            guard window.alpha > 0.01, window.bounds.contains(point) else { return false }
            if window.layer != 0 { return true }
            return window.bounds.width <= target.bounds.width && window.bounds.height <= target.bounds.height
                && window.bounds.width * window.bounds.height
                    <= target.bounds.width * target.bounds.height * attachmentAreaLimit
                && target.bounds.contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY))
        }
        return attached ?? target
    }
}
