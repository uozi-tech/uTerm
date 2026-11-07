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
}

/// 把手机发来的登录密码填进这台 Mac 的锁屏输入框，等同有人在 Mac 键盘上手动输入。密码来自用户自己配对过的
/// 手机、走加密信道传来，这里只在内存里用一次，不保存、不记日志。
///
/// 步骤照探针在本机验证过的做法：先按一下唤出输入框，清掉输入框里可能已有的字符，逐字符输入密码（用
/// Unicode 方式，不受当前键盘布局影响），回车，然后轮询锁屏状态判断是否已进入桌面。
nonisolated enum RemoteUnlockTypist {
    /// 返回输入并回车后 Mac 是否已不在锁屏。
    static func submit(password: String, pollSeconds: Double = 6) async -> Bool {
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

        tap(51)  // Delete：先唤出输入框
        try? await Task.sleep(for: .milliseconds(400))
        tap(0, flags: .maskCommand)  // ⌘A 全选
        tap(51)  // Delete：清空输入框里本机可能已输入的字符
        try? await Task.sleep(for: .milliseconds(200))
        type(password)
        tap(36)  // Return 提交

        let deadline = Date().addingTimeInterval(pollSeconds)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            if !RemoteScreenLock.isLocked() { return true }
        }
        return !RemoteScreenLock.isLocked()
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
    /// 用密码解锁；成功返回 true。
    func unlock(password: String) async -> Bool
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

    func unlock(password: String) async -> Bool {
        await RemoteUnlockTypist.submit(password: password)
    }

    func lockScreen() { RemoteScreenLock.lock() }

    func setCurtain(_ on: Bool) {
        if on { RemoteCurtain.shared.enable() } else { RemoteCurtain.shared.disable() }
    }
}
