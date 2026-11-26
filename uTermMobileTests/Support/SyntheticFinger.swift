import Darwin
import QuartzCore
import UIKit

/// 进程内合成的一根手指（KIF 的做法：私有的 `UITouch` 设置器 + IOKit 的 HID 数字化仪事件 + `UIApplication.sendEvent`）。
///
/// 别的滚动探针都绕开 UIKit 的手势和减速（直接改 contentOffset、调代理方法、用三次缓出的假减速），因为「`UITouch` 没有公开
/// 构造器」。可「松手那一刻速度连不连续」恰恰是 UIKit 自己的事：拖动的跟踪、`willEndDragging` 交出去的速度、改写
/// `targetContentOffset` 之后它怎么减速，假减速一样也量不到。这里让 UIKit 收到和真手指一样的触摸序列，滚动视图的拖动、
/// 减速、回弹全是 UIKit 的。只在模拟器上用（私有 API，只进测试 target）。
///
/// 用法：`down(at:)` → 每帧 `move(to:)` → `up()`，坐标是窗口坐标。时间戳取发送那一刻（和真触摸一样是开机以来的秒数）。
/// 用了它的用例要先把宿主的 `RealTouchWatch` 摘掉（它把任何触摸都当成有人碰了真机）。
@MainActor
final class SyntheticFinger {
    enum Failure: Error { case missing(String) }

    private let window: UIWindow
    private var touch: UITouch?

    init(window: UIWindow) throws {
        self.window = window
        _ = try Self.hid()
    }

    // MARK: 手势

    /// `tapCount`：这是连点里的第几下（双击的第二下传 2），同真触摸的 `UITouch.tapCount`。
    func down(at point: CGPoint, tapCount: Int = 1) throws {
        let touch = UITouch()
        let hit = window.hitTest(point, with: nil) ?? window
        touch.perform(NSSelectorFromString("setWindow:"), with: window)
        Self.call(touch, "_setLocationInWindow:resetPrevious:", as: SetLocation.self) { $0(touch, $1, point, true) }
        touch.perform(NSSelectorFromString("setView:"), with: hit)
        if touch.responds(to: NSSelectorFromString("setGestureView:")) {
            touch.perform(NSSelectorFromString("setGestureView:"), with: hit)
        }
        Self.call(touch, "setTapCount:", as: SetInt.self) { $0(touch, $1, tapCount) }
        if touch.responds(to: NSSelectorFromString("_setIsFirstTouchForView:")) {
            Self.call(touch, "_setIsFirstTouchForView:", as: SetBool.self) { $0(touch, $1, true) }
        }
        self.touch = touch
        try send(touch, phase: .began)
    }

    func move(to point: CGPoint) throws {
        guard let touch else { return }
        Self.call(touch, "_setLocationInWindow:resetPrevious:", as: SetLocation.self) { $0(touch, $1, point, false) }
        try send(touch, phase: .moved)
    }

    /// 停着不动（手指按住）：发一次位置不变的 moved，和真手指停住时一样会把速度拉向 0
    ///（实测发 stationary 不行：UIKit 的拖动速度只看 moved，停住多久松手速度都还是停之前的）。
    func hold() throws {
        guard let touch else { return }
        try send(touch, phase: .moved)
    }

    func up() throws {
        guard let touch else { return }
        try send(touch, phase: .ended)
        self.touch = nil
    }

    // MARK: 发送

    private func send(_ touch: UITouch, phase: UITouch.Phase) throws {
        let now = CACurrentMediaTime()
        Self.call(touch, "setPhase:", as: SetInt.self) { $0(touch, $1, phase.rawValue) }
        Self.call(touch, "setTimestamp:", as: SetDouble.self) { $0(touch, $1, now) }
        let hid = try Self.hidEvent(for: touch, phase: phase, in: window)
        defer { Unmanaged<CFTypeRef>.fromOpaque(hid).release() }
        Self.call(touch, "_setHidEvent:", as: SetPointer.self) { $0(touch, $1, hid) }
        guard let event = UIApplication.shared.perform(NSSelectorFromString("_touchesEvent"))?.takeUnretainedValue() as? UIEvent else {
            throw Failure.missing("_touchesEvent")
        }
        event.perform(NSSelectorFromString("_clearTouches"))
        Self.call(event, "_setHIDEvent:", as: SetPointer.self) { $0(event, $1, hid) }
        Self.call(event, "_addTouch:forDelayedDelivery:", as: AddTouch.self) { $0(event, $1, touch, false) }
        UIApplication.shared.sendEvent(event)
    }

    // MARK: ObjC 私有方法

    private typealias SetLocation = @convention(c) (AnyObject, Selector, CGPoint, Bool) -> Void
    private typealias SetInt = @convention(c) (AnyObject, Selector, Int) -> Void
    private typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias SetDouble = @convention(c) (AnyObject, Selector, Double) -> Void
    private typealias SetPointer = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Void
    private typealias AddTouch = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void

    private static func call<T>(_ object: NSObject, _ name: String, as _: T.Type, _ body: (T, Selector) -> Void) {
        let selector = NSSelectorFromString(name)
        guard let imp = object.method(for: selector) else { return }
        body(unsafeBitCast(imp, to: T.self), selector)
    }

    // MARK: IOKit 的 HID 事件

    private typealias CreateDigitizer = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, UInt8, UInt8, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias CreateFinger = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, UInt8, UInt8, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias Append = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32) -> Void
    private typealias SetInteger = @convention(c) (UnsafeMutableRawPointer, UInt32, Int) -> Void

    private struct HID {
        let digitizer: CreateDigitizer
        let finger: CreateFinger
        let append: Append
        let setInteger: SetInteger
    }

    nonisolated(unsafe) private static var cached: HID?

    private static func hid() throws -> HID {
        if let cached { return cached }
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            throw Failure.missing("IOKit")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw Failure.missing(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        let hid = HID(digitizer: try symbol("IOHIDEventCreateDigitizerEvent", CreateDigitizer.self),
                      finger: try symbol("IOHIDEventCreateDigitizerFingerEvent", CreateFinger.self),
                      append: try symbol("IOHIDEventAppendEvent", Append.self),
                      setInteger: try symbol("IOHIDEventSetIntegerValue", SetInteger.self))
        cached = hid
        return hid
    }

    /// 手（父事件）+ 一根手指（子事件），同 KIF 的 `kif_IOHIDEventWithTouches`。
    private static func hidEvent(for touch: UITouch, phase: UITouch.Phase, in window: UIWindow) throws -> UnsafeMutableRawPointer {
        let hid = try hid()
        let time = mach_absolute_time()
        // kIOHIDDigitizerTransducerTypeHand = 3；kIOHIDDigitizerEventTouch = 1 << 1。
        guard let hand = hid.digitizer(kCFAllocatorDefault, time, 3, 0, 0, 1 << 1, 0, 0, 0, 0, 0, 0, 0, 0, 0) else {
            throw Failure.missing("IOHIDEventCreateDigitizerEvent")
        }
        // kIOHIDEventFieldDigitizerIsDisplayIntegrated = (kIOHIDEventTypeDigitizer 11 << 16) + 25。
        let displayIntegrated = UInt32(11 << 16 + 25)
        hid.setInteger(hand, displayIntegrated, 1)
        // 移动：kIOHIDDigitizerEventPosition (1 << 2)；按下 / 抬起：Range | Touch。
        let mask: UInt32 = phase == .moved || phase == .stationary ? 1 << 2 : (1 << 0) | (1 << 1)
        let touching: UInt8 = phase == .ended || phase == .cancelled ? 0 : 1
        let location = touch.location(in: window)
        guard let finger = hid.finger(kCFAllocatorDefault, time, 0, 2, mask, Double(location.x), Double(location.y), 0,
                                      Double(touching), 0, touching, touching, 0) else {
            Unmanaged<CFTypeRef>.fromOpaque(hand).release()
            throw Failure.missing("IOHIDEventCreateDigitizerFingerEvent")
        }
        hid.setInteger(finger, displayIntegrated, 1)
        hid.append(hand, finger, 0)
        Unmanaged<CFTypeRef>.fromOpaque(finger).release()
        return hand
    }
}

/// 每个显示帧调一次 `step(timestamp)`，直到它返回 false（同 `GhosttySystemScrollJitterTests.Ticker`，这里要 vsync 时刻）。
@MainActor
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var step: (@MainActor (CADisplayLink) -> Bool)?
    private var done: CheckedContinuation<Void, Never>?

    func run(_ step: @escaping @MainActor (CADisplayLink) -> Bool) async {
        self.step = step
        await withCheckedContinuation { continuation in
            done = continuation
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        if step?(link) != true {
            link.invalidate()
            self.link = nil
            done?.resume()
            done = nil
        }
    }
}
