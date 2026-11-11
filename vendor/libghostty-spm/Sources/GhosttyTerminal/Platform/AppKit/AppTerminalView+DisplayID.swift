//
//  AppTerminalView+DisplayID.swift
//  uTerm 本地补丁（上游没有这个文件）
//
//  把视图所在的显示器报给引擎（`ghostty_surface_set_display_id`），官方 macOS App 在窗口换屏时做同一件事。
//
//  为什么必须报：渲染器在 surface 出生时建 CVDisplayLink（按屏幕刷新出帧）。当时没有活动显示器——Mac 锁着、
//  显示器睡着，而终端是手机远控新开的、或藏久了被放掉后重建的——就建不成，渲染器退回「不按屏幕刷新、渲染线程
//  有消息就画」。引擎自己不会重试，重试的入口只有这个调用（`setMacOSDisplayID` → `syncDisplayLink` 里补建）。
//  不报的话这个 surface 一辈子没有 display link：渲染线程的帧（异步交给主线程上屏）和主线程同步画的帧互相不排队，
//  旧帧可能晚于新帧上屏，滚动时画面上下来回跳一行半行（用户实测，日志 `error creating display link; using
//  fallback rendering`）。
//
//  什么时候报：
//  - surface 新建之后、显示器换了：按「surface + 显示器」去重，布局和进窗口时顺带查一下；
//  - 显示器可能刚回来：窗口换屏、屏幕参数变化、屏幕唤醒、会话重新激活、窗口重新可见、窗口成为 key——不去重，
//    每次都报（link 没建成的那个 surface 手里的「surface + 显示器」并没有变）。引擎那边同一个显示器重复绑定是幂等的。
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit

    /// 上次报给引擎的显示器，和一共报了几次（测试读）。
    struct DisplayReportState {
        /// 上次报的时候是第几个 surface（`TerminalSurfaceCoordinator.surfaceGeneration`）。
        var surfaceGeneration: Int?
        var displayID: UInt32?
        var count = 0
        var observingWake = false
    }

    extension AppTerminalView {
        /// 视图所在窗口的显示器编号（`CGDirectDisplayID`）；窗口不在任何屏幕上时为 nil。
        var currentDisplayID: UInt32? {
            guard let screen = window?.screen,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return number.uint32Value
        }

        /// 把显示器报给引擎。`force` = false 时同一个 surface、同一个显示器不重复报。
        func reportDisplayID(force: Bool = false) {
            guard let surface, let id = currentDisplayID else { return }
            let generation = core.surfaceGeneration
            guard force || displayReport.surfaceGeneration != generation || displayReport.displayID != id else { return }
            displayReport.surfaceGeneration = generation
            displayReport.displayID = id
            displayReport.count += 1
            surface.setDisplayID(id)
        }

        /// 屏幕唤醒、会话重新激活（解锁）走的是 NSWorkspace 自己的通知中心。
        func observeScreenWake() {
            guard !displayReport.observingWake else { return }
            displayReport.observingWake = true
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(screenDidComeBack),
                               name: NSWorkspace.screensDidWakeNotification, object: nil)
            center.addObserver(self, selector: #selector(screenDidComeBack),
                               name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        }

        func stopObservingScreenWake() {
            guard displayReport.observingWake else { return }
            displayReport.observingWake = false
            let center = NSWorkspace.shared.notificationCenter
            center.removeObserver(self, name: NSWorkspace.screensDidWakeNotification, object: nil)
            center.removeObserver(self, name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        }

        @objc func screenDidComeBack(_: Notification) {
            reportDisplayID(force: true)
        }
    }

    public extension AppTerminalView {
        /// uTerm 测试用：一共把显示器报给引擎几次、最近一次报的是哪块。
        var uTermDisplayReports: (count: Int, displayID: UInt32?) {
            (displayReport.count, displayReport.displayID)
        }
    }
#endif
