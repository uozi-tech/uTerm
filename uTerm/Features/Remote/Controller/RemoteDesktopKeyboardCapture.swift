import AppKit
import CoreGraphics

/// 控制另一台 Mac 时截下本机的系统快捷键（⌘Tab、⌘空格、调度中心、⌘W / ⌘Q…）交给画布发过去。
///
/// 这些组合在本机由系统先拿走，窗口根本收不到，只能在事件流入口挂一个键盘事件钩子（`CGEventTap`，
/// 与帘幕暂停本机输入是同一种做法），要「辅助功能」授权。钩子只在屏幕窗口是前台、画布有焦点、
/// 有控制权、用户没关这个开关时挂着；一切到别的窗口 / app 立刻摘掉，不会把整台机器的键盘扣住。
/// 鼠标不截：随时能点到别的窗口离开。
@MainActor
final class RemoteDesktopKeyboardCapture {
    /// 截到的按键（已转成 NSEvent），交给画布照常处理。
    var onKey: ((NSEvent) -> Void)?
    private(set) var isActive = false
    /// 挂钩子失败（多半是没有「辅助功能」授权）。
    private(set) var failed = false

    // deinit 也要摘：钩子拿的是不持有的 self 指针，主人没调 `set(active: false)` 就释放时，留下的钩子会扣住
    // 整台机器的键盘，下一个按键还会访问已释放的对象。CFRunLoop 的增删可以在任何线程做。
    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var source: CFRunLoopSource?

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    /// 该不该挂：前台、有焦点、能控制、开关开着。纯函数，单测用。
    nonisolated static func shouldCapture(enabled: Bool, appActive: Bool, windowKey: Bool, canvasFocused: Bool,
                                          canControl: Bool) -> Bool {
        enabled && appActive && windowKey && canvasFocused && canControl
    }

    func set(active: Bool) {
        if active { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let box = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: Self.callback, userInfo: box) else {
            if !failed {
                AppLogger.info("远程桌面：系统快捷键截取未能建立（没有「辅助功能」授权？）", category: RemoteLog.category)
            }
            failed = true
            return
        }
        failed = false
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isActive = false
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func deliver(_ event: NSEvent) {
        onKey?(event)
    }

    /// 钩子挂在主线程的 run loop 上，回调就在主线程。截下的按键吞掉（返回 nil），不再给本机。
    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let capture = Unmanaged<RemoteDesktopKeyboardCapture>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { capture.reenable() }
            return Unmanaged.passUnretained(event)
        }
        // 回调本来就在主线程（钩子挂在主 run loop 上），事件不出这个线程。
        guard let converted = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        nonisolated(unsafe) let ns = converted
        MainActor.assumeIsolated { capture.deliver(ns) }
        return nil
    }
}
