import CoreGraphics
import Foundation

/// 帘幕模式：等同系统「屏幕共享」里的帘幕。手机远程看这台 Mac 时，让 Mac 的物理屏显示为黑屏、并暂停
/// Mac 本机的键盘鼠标，使坐在 Mac 前的人既看不到画面、也不会和手机抢操作。手机那头照常看、照常操作。
///
/// 做法参考 RustDesk 的 macOS 隐私模式：显示器 gamma 表置零使物理屏变黑（手机是从 ScreenCaptureKit
/// 单独采集的，不受 gamma 影响），加一个 HID 层事件处理把本机键鼠事件挡下，并把光标钉住。进程异常退出时
/// 系统会自动恢复 gamma，所以不会把屏幕永久留黑。
///
/// 只在主线程用（事件处理要挂到主 runloop）。
@MainActor
final class RemoteCurtain {
    static let shared = RemoteCurtain()

    private(set) var isActive = false
    /// 本机连按三下 Esc 要求解除帘幕时回调（坐在 Mac 前的人拿回控制；之后 Mac 会锁屏，由他自己解锁）。
    var onLocalRelease: (() -> Void)?

    private var savedGamma: [CGDirectDisplayID: GammaTable] = [:]
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private struct GammaTable {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    func enable() {
        guard !isActive else { return }
        isActive = true
        blackoutAllDisplays()
        startInputBlock()
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayRegisterReconfigurationCallback(Self.reconfigured, nil)
        // 屏幕黑了，Mac 本机的扬声器也别再出声（传到手机的声音不受影响）。
        RemoteCurtainMute.shared.engage()
        AppLogger.info("远程桌面：帘幕已开启", category: RemoteLog.category)
    }

    func disable() {
        guard isActive else { return }
        isActive = false
        CGDisplayRemoveReconfigurationCallback(Self.reconfigured, nil)
        stopInputBlock()
        CGAssociateMouseAndMouseCursorPosition(1)
        restoreAllDisplays()
        RemoteCurtainMute.shared.release()
        AppLogger.info("远程桌面：帘幕已关闭", category: RemoteLog.category)
    }

    // MARK: 黑屏

    private func blackoutAllDisplays() {
        for display in Self.onlineDisplays() {
            let capacity = CGDisplayGammaTableCapacity(display)
            guard capacity > 0 else { continue }
            var red = [CGGammaValue](repeating: 0, count: Int(capacity))
            var green = red, blue = red
            var count: UInt32 = 0
            // 只在第一次黑屏这块屏时记原值：显示器重配置后再次置黑时，当前表已经是全零，再记就把原值冲掉了。
            if savedGamma[display] == nil,
               CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 0 {
                savedGamma[display] = GammaTable(red: Array(red.prefix(Int(count))),
                                                 green: Array(green.prefix(Int(count))),
                                                 blue: Array(blue.prefix(Int(count))))
            }
            let zeros = [CGGammaValue](repeating: 0, count: Int(capacity))
            _ = CGSetDisplayTransferByTable(display, capacity, zeros, zeros, zeros)
        }
    }

    private func restoreAllDisplays() {
        for (display, table) in savedGamma {
            _ = CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue)
        }
        savedGamma.removeAll()
        // 兜底：即便上面某块屏恢复失败，也让系统按色彩配置复位。
        CGDisplayRestoreColorSyncSettings()
    }

    /// 显示器热插拔 / 改分辨率后系统可能把 gamma 复位，重新置黑并记下新屏的原值。
    fileprivate func reapplyAfterReconfigure() {
        guard isActive else { return }
        blackoutAllDisplays()
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private static let reconfigured: CGDisplayReconfigurationCallBack = { _, flags, _ in
        guard flags.contains(.setModeFlag) || flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { RemoteCurtain.shared.reapplyAfterReconfigure() } }
    }

    // MARK: 本机输入暂停

    private func startInputBlock() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: Self.tapCallback, userInfo: nil) else {
            AppLogger.info("远程桌面：本机输入暂停未能建立（没有「辅助功能」授权？）", category: RemoteLog.category)
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopInputBlock() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func reenableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, _ in
        // 系统因超时或本机输入把处理停了，重新打开。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { MainActor.assumeIsolated { RemoteCurtain.shared.reenableTap() } }
            return Unmanaged.passUnretained(event)
        }
        // 手机注入的事件带标记，放行。
        if event.getIntegerValueField(.eventSourceUserData) == RemoteInjectedEvent.userDataTag {
            return Unmanaged.passUnretained(event)
        }
        // 本机物理键鼠：暂停（丢弃）。坐在 Mac 前的人连按三下 Esc 可强行解除帘幕、拿回控制。
        if event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue) {
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                DispatchQueue.main.async { MainActor.assumeIsolated { RemoteCurtain.shared.noteEscape() } }
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private var escapeTimes: [Date] = []

    /// 本机按下 Esc：短时间内连按三下就解除帘幕（坐在 Mac 前的人拿回控制）。
    fileprivate func noteEscape() {
        let now = Date()
        escapeTimes.append(now)
        escapeTimes.removeAll { now.timeIntervalSince($0) > 1.5 }
        if escapeTimes.count >= 3 {
            escapeTimes.removeAll()
            AppLogger.info("远程桌面：本机连按 Esc，解除帘幕", category: RemoteLog.category)
            onLocalRelease?()
        }
    }
}
