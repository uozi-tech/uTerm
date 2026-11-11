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
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// 把手机发来的登录密码填进这台 Mac 的锁屏输入框，等同有人在 Mac 键盘上手动输入。密码来自用户自己配对过的
/// 手机、走加密信道传来，这里只在内存里用一次，不保存、不记日志。
///
/// 步骤：键盘被截图选区占着才按 Esc；动一下鼠标、按一下 Shift 把屏保 / 只显示时钟的锁屏叫醒；按 Delete 唤出
/// 输入框并等它出来；清掉输入框里可能已有的字符；逐字符输入密码（用 Unicode 方式，不受当前键盘布局影响）；回车；
/// 轮询锁屏状态判断是否已进入桌面。
///
/// 帘幕（黑屏 + 拦本机输入的事件钩子）开着时注入的按键进不了密码框：loginwindow 每个键都走「输入框没显示」
/// 那条路（日志 `View is hidden password field length = 0`），回车提交的是空密码（2026-11-09 真机实测，
/// 同一台 Mac 上经远程桌面手动输入、帘幕关着时一切正常）。所以打字时帘幕必须是关的；`beforeSubmit` 在回车前
/// 挂上帘幕，锁屏一消失物理屏已经是黑的。Esc 也只在真有截图选区时才按：锁屏上 Esc 会把刚弹出的输入框收回去。
nonisolated enum RemoteUnlockTypist {
    /// 输密码前的一步。
    enum Step: Equatable {
        case key(CGKeyCode, CGEventFlags = [])
        case wait(milliseconds: Int)
        /// 动一下鼠标（屏保只认鼠标或按键才退）。
        case nudgeMouse
    }

    static let escape: CGKeyCode = 53
    static let delete: CGKeyCode = 51
    static let shift: CGKeyCode = 56
    static let returnKey: CGKeyCode = 36
    static let keyA: CGKeyCode = 0

    /// 叫醒锁屏、唤出并清空输入框的按键序列（不含打密码与回车）。Esc 已在调用前单独处理。
    static func preparation() -> [Step] {
        [
            // 屏保 / 时钟界面：鼠标一动、Shift 一按就退，Shift 不会在输入框里留下字符。
            .nudgeMouse, .key(shift), .wait(milliseconds: 600),
            // Delete 唤出输入框（空框里按 Delete 无害）。动画要几百毫秒，第二下保证焦点已在框里。
            .key(delete), .wait(milliseconds: 700),
            .key(delete), .wait(milliseconds: 300),
            // ⌘A + Delete 清掉本机可能已输入的字符。
            .key(keyA, .maskCommand), .key(delete), .wait(milliseconds: 200),
        ]
    }

    static func submit(password: String, pollSeconds: Double = 6,
                       beforeSubmit: @MainActor () -> Void = {}) async -> RemoteUnlockAttempt {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = RemoteInjectedEvent.userDataTag

        func tap(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
                // 显式给修饰键：不给就沿用事件源里的状态，可能带着前一个 ⌘A 的 Command。
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
        }
        func nudgeMouse() {
            let origin = CGEvent(source: nil)?.location ?? .zero
            for point in [CGPoint(x: origin.x + 1, y: origin.y), origin] {
                CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                        mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        func type(_ text: String) {
            for scalarChar in text {
                let units = Array(String(scalarChar).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.flags = []
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
        if RemoteKeyboardBlocker.current() != nil {
            // 截图选区抓着键盘时后面的按键全归它；Esc 让它退出。帘幕只认本机的 Esc，这里的事件带着注入标记，
            // 不会被当成本机要撤帘幕。
            tap(escape)
            try? await Task.sleep(for: .milliseconds(300))
            if let blocker = RemoteKeyboardBlocker.current() {
                // 还占着：不输密码（输了也只会被它吃掉），如实告诉手机。
                AppLogger.notice("远程桌面：\(blocker) 占着键盘，按 Esc 也没让开，没有输密码", category: RemoteLog.category)
                return .inputBlocked
            }
        }
        RemoteDisplayWake.nudge()
        for step in preparation() {
            guard RemoteScreenLock.isLocked() else { return .unlocked }
            switch step {
            case let .key(code, flags): tap(code, flags: flags)
            case let .wait(milliseconds): try? await Task.sleep(for: .milliseconds(milliseconds))
            case .nudgeMouse: nudgeMouse()
            }
        }
        guard RemoteScreenLock.isLocked() else { return .unlocked }
        type(password)
        guard RemoteScreenLock.isLocked() else { return .unlocked }
        await beforeSubmit()
        tap(returnKey)

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
    /// 用密码解锁。打完密码、按回车之前调用 `beforeSubmit`（挂帘幕）：帘幕开着时按键进不了密码框。
    func unlock(password: String, beforeSubmit: @escaping @MainActor () -> Void) async -> RemoteUnlockAttempt
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

    func unlock(password: String, beforeSubmit: @escaping @MainActor () -> Void) async -> RemoteUnlockAttempt {
        await RemoteUnlockTypist.submit(password: password, beforeSubmit: beforeSubmit)
    }

    func lockScreen() { RemoteScreenLock.lock() }

    func setCurtain(_ on: Bool) {
        if on { RemoteCurtain.shared.enable() } else { RemoteCurtain.shared.disable() }
    }
}
