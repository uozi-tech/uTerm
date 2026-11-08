import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// 手机注入的 CGEvent 在事件源上带的标记。帘幕模式用它把「手机的输入」从「Mac 本机的输入」里分出来，
/// 本机的拦掉、手机的放行。取一个不像默认值（0）的常数即可。
nonisolated enum RemoteInjectedEvent {
    static let userDataTag: Int64 = 0x7554_4552  // "uTER"
}

/// Mac 的锁屏状态。远程桌面靠它告诉手机「现在停在锁屏界面上」，并在手机解锁后回报结果。
nonisolated enum RemoteScreenLock {
    /// 当前是否停在锁屏界面。读会话字典里系统维护的那一位，读不到当作没锁。
    static func isLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Int { return locked != 0 }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
        return false
    }

    /// 把 Mac 重新锁回去（远控结束时用）。走 login 框架里的锁屏入口，和菜单栏「锁定屏幕」同一效果。
    static func lock() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return }
        typealias LockFn = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: LockFn.self)()
    }
}

/// 点亮显示器、并在远控期间顺带让系统别急着把屏幕关掉。只负责「唤醒」这一件事。
nonisolated final class RemoteDisplayWake: @unchecked Sendable {
    /// 告诉系统「用户有活动」，正在休眠的显示器会被点亮。远程桌面开流、收到手机输入时调用。
    static func nudge() {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("uTerm 远程桌面" as CFString, kIOPMUserActiveLocal, &assertion)
    }

    /// 点亮显示器并等它醒来（最多约 3 秒）。本来就醒着时立即返回。刚醒时 ScreenCaptureKit 还要一会儿才
    /// 把它列进可采集的显示器，所以醒来后再多等一小段。
    static func wake(display id: CGDirectDisplayID) async {
        guard CGDisplayIsAsleep(id) != 0 else { return }
        nudge()
        let deadline = Date().addingTimeInterval(3)
        while CGDisplayIsAsleep(id) != 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(400))
    }
}

/// 一次远程解锁的结果。
nonisolated enum RemoteUnlockAttempt: Equatable, Sendable {
    /// 已不在锁屏（解开了，或中途被 Mac 前的人解开了）。
    case unlocked
    /// 输完密码回车后仍锁着。Mac 读不到「锁屏拒绝了密码」的信号，所以不知道是密码不对还是没输进去。
    case stillLocked
    /// 有程序占着键盘（截图选区等），按 Esc 也没让开：没有输密码。
    case inputBlocked
}

/// 会抓住整个键盘、让锁屏输入框收不到按键的东西。现在只认截图选区：⌘⇧4 / ⌘⇧5 进入选区后，按键全归它，
/// 直到按 Esc 或选完（2026-11-08 mini 上一个这样的选区从 18:27 挂到 23:20，解锁时输的密码全被它吃掉）。
nonisolated enum RemoteKeyboardBlocker {
    static let processNames: Set<String> = ["screencapture", "screencaptureui"]

    /// 屏上有没有这类程序的大窗口（选区的遮罩铺满整块屏）。截完图右下角的缩略图是小窗口，不抓键盘，不算。
    /// 返回占着键盘的进程名；没有返回 nil。`processName` 按 pid 查进程名，测试换成假的。
    static func blocker(windows: [[String: Any]], screenArea: Double,
                        processName: (pid_t) -> String?) -> String? {
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let name = processName(pid), processNames.contains(name),
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if Double(bounds.width * bounds.height) >= screenArea * 0.5 { return name }
        }
        return nil
    }

    /// 当前屏上的。
    static func current() -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let main = CGDisplayBounds(CGMainDisplayID())
        return blocker(windows: list, screenArea: Double(main.width * main.height), processName: Self.processName)
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// 把手机发来的登录密码填进这台 Mac 的锁屏输入框，等同有人在 Mac 键盘上手动输入。密码来自用户自己配对过的
/// 手机、走加密信道传来，这里只在内存里用一次，不保存、不记日志。
///
/// 步骤照探针在本机验证过的做法：先按 Esc 让占着键盘的模态（截图选区等）退出，再按一下唤出输入框，清掉
/// 输入框里可能已有的字符，逐字符输入密码（用 Unicode 方式，不受当前键盘布局影响），回车，然后轮询锁屏
/// 状态判断是否已进入桌面。
nonisolated enum RemoteUnlockTypist {
    static func submit(password: String, pollSeconds: Double = 6) async -> RemoteUnlockAttempt {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = RemoteInjectedEvent.userDataTag

        func tap(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
                if !flags.isEmpty { event?.flags = flags }
                event?.post(tap: .cghidEventTap)
            }
        }
        func type(_ text: String) {
            for scalarChar in text {
                let units = Array(String(scalarChar).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    units.withUnsafeBufferPointer {
                        event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                    event?.post(tap: .cghidEventTap)
                }
            }
        }

        // 每组按键前都确认仍在锁屏：中途若被 Mac 前的人解开了，这些按键会落到前台 app 里——⌘A + Delete 会清掉
        // 它的内容，密码会被当普通文字打进去。所以一旦不在锁屏就立即停手（此时 Mac 已解锁，按成功处理）。
        guard RemoteScreenLock.isLocked() else { return .unlocked }
        // Esc：截图选区、Spotlight 这类模态抓着键盘时，后面的按键全归它；Esc 让它退出。锁屏输入框收到 Esc
        // 无害（后面还要 ⌘A 清空）。帘幕只认本机的 Esc，这里的事件带着注入标记，不会被当成本机要撤帘幕。
        tap(53)
        try? await Task.sleep(for: .milliseconds(300))
        if let blocker = RemoteKeyboardBlocker.current() {
            // 还占着：不输密码（输了也只会被它吃掉），如实告诉手机。
            AppLogger.notice("远程桌面：\(blocker) 占着键盘，按 Esc 也没让开，没有输密码", category: RemoteLog.category)
            return .inputBlocked
        }
        guard RemoteScreenLock.isLocked() else { return .unlocked }
        tap(51)  // Delete：先唤出输入框
        try? await Task.sleep(for: .milliseconds(400))
        guard RemoteScreenLock.isLocked() else { return .unlocked }
        tap(0, flags: .maskCommand)  // ⌘A 全选
        tap(51)  // Delete：清空输入框里本机可能已输入的字符
        try? await Task.sleep(for: .milliseconds(200))
        guard RemoteScreenLock.isLocked() else { return .unlocked }
        type(password)
        guard RemoteScreenLock.isLocked() else { return .unlocked }
        tap(36)  // Return 提交

        let deadline = Date().addingTimeInterval(pollSeconds)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            if !RemoteScreenLock.isLocked() { return .unlocked }
        }
        return RemoteScreenLock.isLocked() ? .stillLocked : .unlocked
    }
}

/// 远程桌面要用的「这台 Mac 的屏幕控制」：锁屏状态、唤醒、解锁、帘幕。抽成协议是为了让测试换成记录型假件，
/// 其余链路（服务端、连接、协议）跑同一份代码。
@MainActor
protocol RemoteScreenController: AnyObject {
    var isLocked: Bool { get }
    var isCurtained: Bool { get }
    /// 点亮显示器。
    func wake()
    /// 用密码解锁。
    func unlock(password: String) async -> RemoteUnlockAttempt
    /// 把 Mac 重新锁回去（远控结束时）。
    func lockScreen()
    func setCurtain(_ on: Bool)
    /// 本机要求解除帘幕时回调（如坐在 Mac 前的人连按 Esc）。
    var onLocalCurtainRelease: (() -> Void)? { get set }
}

/// 生产实现：接到前面几个系统能力上。
@MainActor
final class LiveRemoteScreenController: RemoteScreenController {
    var isLocked: Bool { RemoteScreenLock.isLocked() }
    var isCurtained: Bool { RemoteCurtain.shared.isActive }

    var onLocalCurtainRelease: (() -> Void)? {
        get { RemoteCurtain.shared.onLocalRelease }
        set { RemoteCurtain.shared.onLocalRelease = newValue }
    }

    func wake() { RemoteDisplayWake.nudge() }

    func unlock(password: String) async -> RemoteUnlockAttempt {
        await RemoteUnlockTypist.submit(password: password)
    }

    func lockScreen() { RemoteScreenLock.lock() }

    func setCurtain(_ on: Bool) {
        if on { RemoteCurtain.shared.enable() } else { RemoteCurtain.shared.disable() }
    }
}
