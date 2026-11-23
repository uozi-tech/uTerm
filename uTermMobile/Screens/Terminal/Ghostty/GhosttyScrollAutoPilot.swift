#if DEBUG
import Darwin
import GhosttyTerminal
import QuartzCore
import UIKit

/// 调试（只在 Debug 构建里）：App 自己按脚本滚终端，几种做法（`UTermScrollTrace.ScrollWakeupSyncDraw`）轮着来，配
/// `GhosttyScrollDebugSwitch` 的录制把每一步写进 `Documents/scroll-trace-auto.txt`。手指是进程内合成的真触摸
///（下面的 `DebugSyntheticFinger`，和测试 target 的 `SyntheticFinger` 同一份实现），拖动、减速、回弹、对齐全是 UIKit 的。
/// 给装不了 XCTest 的环境用（vphone 里的包没有签名），真机上也能无人值守地录。
/// 启动参数 / 偏好：`-GhosttySyncDrawDuringScroll auto:moving,touching,always`（要配 `-LiveActivityDebugDemo scroll`）。
@MainActor
enum GhosttyScrollAutoPilot {
    static func start(policies: [UTermScrollTrace.ScrollWakeupSyncDraw]) {
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = true
            var found: UITerminalView?
            for _ in 0 ..< 150 {
                found = terminalView()
                if found?.uTermCellPixels != nil, found?.window != nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(4))
            guard let view = found, let window = view.window, let finger = try? DebugSyntheticFinger(window: window) else {
                UTermScrollTrace.note("auto-failed", 1)
                return
            }
            let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let reach = min(view.bounds.height * 0.35, 220)
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
            /// 手指按 `speed`（点 / 秒）匀速走 `seconds` 秒后动着抬手；`direction` 为 +1 时手指往下（内容往回滚）。
            func gesture(speed: Double, seconds: Double, direction: Double) async {
                let duration = min(seconds, Double(2 * reach) / speed)
                let startY = center.y - CGFloat(direction * speed * duration / 2)
                UTermScrollTrace.note("auto-gesture", speed * direction)
                var begin: Double?
                await DebugFrameTicker().run { link in
                    do {
                        guard let start = begin else {
                            try finger.down(at: CGPoint(x: center.x, y: startY))
                            begin = link.targetTimestamp
                            return true
                        }
                        let elapsed = min(duration, link.targetTimestamp - start)
                        try finger.move(to: CGPoint(x: center.x, y: startY + CGFloat(direction * speed * elapsed)))
                        if elapsed >= duration {
                            try finger.up()
                            return false
                        }
                        return true
                    } catch {
                        UTermScrollTrace.note("auto-failed", 2)
                        return false
                    }
                }
            }
            for (index, policy) in policies.enumerated() {
                UTermScrollTrace.scrollWakeupSyncDraw = policy
                UTermScrollTrace.note("auto-policy", Double(UTermScrollTrace.ScrollWakeupSyncDraw.allCases.firstIndex(of: policy) ?? -1))
                // 先往回甩一大段，后面成对的来回都有余地（一上来在最底下）。
                if index == 0 {
                    await gesture(speed: 5000, seconds: 0.1, direction: 1)
                    await pause(4)
                }
                for speed in [60.0, 200] {
                    for direction in [1.0, -1] {
                        await gesture(speed: speed, seconds: speed < 100 ? 2 : 1, direction: direction)
                        await pause(1.5)
                    }
                }
                for speed in [600.0, 1500, 3000, 6000] {
                    for direction in [1.0, -1] {
                        await gesture(speed: speed, seconds: 0.1, direction: direction)
                        await pause(4)
                    }
                }
            }
            UTermScrollTrace.note("auto-done", 1)
        }
    }

    private static func terminalView() -> UITerminalView? {
        func search(_ view: UIView) -> UITerminalView? {
            if let terminal = view as? UITerminalView { return terminal }
            for sub in view.subviews {
                if let terminal = search(sub) { return terminal }
            }
            return nil
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                if let terminal = search(window) { return terminal }
            }
        }
        return nil
    }
}

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
final class DebugSyntheticFinger {
    enum Failure: Error { case missing(String) }

    private let window: UIWindow
    private var touch: UITouch?

    init(window: UIWindow) throws {
        self.window = window
        _ = try Self.hid()
    }

    // MARK: 手势

    func down(at point: CGPoint) throws {
        let touch = UITouch()
        let hitMark = CACurrentMediaTime()
        let hit = window.hitTest(point, with: nil) ?? window
        UTermScrollTrace.noteSpan("finger-hittest", start: hitMark, milliseconds: (CACurrentMediaTime() - hitMark) * 1000)
        touch.perform(NSSelectorFromString("setWindow:"), with: window)
        Self.call(touch, "_setLocationInWindow:resetPrevious:", as: SetLocation.self) { $0(touch, $1, point, true) }
        touch.perform(NSSelectorFromString("setView:"), with: hit)
        if touch.responds(to: NSSelectorFromString("setGestureView:")) {
            touch.perform(NSSelectorFromString("setGestureView:"), with: hit)
        }
        Self.call(touch, "setTapCount:", as: SetInt.self) { $0(touch, $1, 1) }
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
        let sendMark = CACurrentMediaTime()
        UIApplication.shared.sendEvent(event)
        UTermScrollTrace.noteSpan("finger-send-\(phase.rawValue)", start: sendMark, milliseconds: (CACurrentMediaTime() - sendMark) * 1000)
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
final class DebugFrameTicker: NSObject {
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
#endif
