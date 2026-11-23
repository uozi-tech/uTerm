//
//  TerminalMainTurnClock.swift
//  uTerm 本地补丁（不在上游）：主线程这一轮 run loop 是什么时候醒的。
//

#if canImport(UIKit)
    import Foundation
    import QuartzCore

    /// 系统滚动每帧在 `scrollViewDidScroll` 里等引擎把这一步画完（`systemScrollWaitForFrame`），等到什么时候为止得从
    /// 「这一轮从哪一刻开始」算：按下手指那一轮 UIKit 分发触摸就花掉好几毫秒，再整等一个预算这一帧就过了提交的时限。
    /// 一个 run loop 观察者记下每次醒来的时刻；一直没睡（一轮接一轮）时这个时刻偏早，预算只会更紧，不会更松。
    @MainActor
    enum TerminalMainTurnClock {
        nonisolated(unsafe) private static var wokeAt: CFTimeInterval = 0
        private static var installed = false

        static func install() {
            guard !installed else { return }
            installed = true
            wokeAt = CACurrentMediaTime()
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
                wokeAt = CACurrentMediaTime()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        /// 这一轮 run loop 醒来的时刻（`CACurrentMediaTime()`）。
        static var turnStart: CFTimeInterval { wokeAt }
    }
#endif
