import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Mac 上等着验证身份的系统框：管理员授权（SecurityAgent）与 App 调 LocalAuthentication（coreautha）。
///
/// 指纹在 Mac 的传感器和安全隔区里本地比对，转不过去；远控能做的是让框改用密码、把登录密码打进去，或取消它。
/// 2026-11-20 探针实测（调研文档 §18）：两种框都收沙盒进程的模拟点击与按键；沙盒里 AX 读不到它们（-25204），
/// 所以不靠按钮文字，按固定的交互来：点框的标题区让它到前台；LocalAuthentication 的框里回车 = 默认按钮「使用密码…」，
/// 之后密码框自己获得焦点；SecurityAgent 的框一到前台焦点就在密码框里。
nonisolated struct RemoteAuthPromptWindow: Equatable, Sendable {
    var id: CGWindowID
    var pid: pid_t
    var bounds: CGRect
    var kind: RemoteDesktopAuthPrompt.Kind

    var prompt: RemoteDesktopAuthPrompt { RemoteDesktopAuthPrompt(id: id, kind: kind) }
}

/// 一次回应验证框的结果。
nonisolated enum RemoteAuthPromptAttempt: Equatable, Sendable {
    /// 填完密码后框关了。
    case accepted
    /// 填完密码后框还在（密码不对）。
    case rejected
    /// 取消掉了。
    case cancelled
    /// 那个框已经不在了。
    case gone
    /// 没能把框切到前台、或没找到获得焦点的密码框：没有输密码。
    case notFocused
}

/// 在屏上找验证框。
nonisolated enum RemoteAuthPromptDetector {
    /// 进程名 → 框的种类。按进程名认（`proc_name`），不按窗口属主名：属主名会被本地化（程序坞就叫「程序坞」）。
    static let processKinds: [String: RemoteDesktopAuthPrompt.Kind] = [
        "SecurityAgent": .authorization,
        "coreautha": .localAuthentication,
    ]
    /// 比这小的窗口不算（两种框实测都是 260pt 宽、250pt 以上高）。
    static let minimumSide: CGFloat = 100

    /// `windows` 按 `CGWindowListCopyWindowInfo` 的顺序（从前到后），取最前面的一个。
    static func find(windows: [[String: Any]], processName: (pid_t) -> String?) -> RemoteAuthPromptWindow? {
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  (window[kCGWindowLayer as String] as? Int ?? 0) > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= minimumSide, bounds.height >= minimumSide,
                  let name = processName(pid), let kind = processKinds[name] else { continue }
            return RemoteAuthPromptWindow(id: id, pid: pid, bounds: bounds, kind: kind)
        }
        return nil
    }

    static func current() -> RemoteAuthPromptWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return find(windows: list, processName: RemoteKeyboardBlocker.processName)
    }
}

/// 回应验证框：切到前台、改用密码、填密码、确认；或者取消。密码来自主控端、走加密信道传来，只在内存里用一次，
/// 不保存、不记日志。
///
/// **任何一个按键发出去之前都核对**：框还是同一个、它的进程在前台、（打密码时）安全输入开着。框弹出来时常常不在
/// 前台（探针实测），直接发键会打进当时的前台 App；中途 Mac 前的人点走了也一样。核对不过就停手、报 `notFocused`。
nonisolated enum RemoteAuthPromptTypist {
    /// 系统能力，测试换成假的。在主线程上用：前台 App 靠主线程 run loop 上的通知更新。
    @MainActor
    struct Environment {
        var window: () -> RemoteAuthPromptWindow?
        var frontPID: () -> pid_t?
        var secureInput: () -> Bool
        var click: (CGPoint) -> Void
        var key: (CGKeyCode, CGEventFlags) -> Void
        /// 打一个字符（Unicode 方式，不受键盘布局影响）。
        var type: (Character) -> Void
        var sleep: (Duration) async -> Void
    }

    static let escape: CGKeyCode = 53
    static let returnKey: CGKeyCode = 36
    static let tab: CGKeyCode = 48
    static let delete: CGKeyCode = 51
    static let keyA: CGKeyCode = 0

    /// 点框的哪里让它到前台：标题区（顶边往下 30pt、水平居中）。那里是说明文字，不是按钮或输入框。
    static func focusPoint(_ bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.minY + 30)
    }

    @MainActor
    static func answer(promptID: UInt32, action: RemoteDesktopAuthPromptRequest.Action, password: String?,
                       environment env: Environment) async -> RemoteAuthPromptAttempt {
        guard let window = env.window(), window.id == promptID else { return .gone }
        // 填密码却没带密码：什么都不动。
        if action == .fill, password?.isEmpty ?? true { return .notFocused }
        func sameWindow() -> Bool { env.window()?.id == window.id }
        func inFront() -> Bool { sameWindow() && env.frontPID() == window.pid }
        func readyForPassword() -> Bool { inFront() && env.secureInput() }
        /// 每 100ms 看一次，最多等 `limit`。
        func wait(_ limit: Duration, until condition: () -> Bool) async -> Bool {
            var waited: Duration = .zero
            while !condition() {
                guard waited < limit else { return false }
                await env.sleep(.milliseconds(100))
                waited += .milliseconds(100)
            }
            return true
        }

        // 1. 切到前台。
        if !inFront() {
            env.click(focusPoint(window.bounds))
            _ = await wait(.seconds(1)) { inFront() || !sameWindow() }
        }
        guard sameWindow() else { return .gone }
        guard inFront() else { return .notFocused }

        // 取消：Esc（两种框都认）。
        if action == .cancel {
            env.key(escape, [])
            return await wait(.seconds(2)) { !sameWindow() } ? .cancelled : .notFocused
        }
        let password = password ?? ""

        // 2. 让密码框获得焦点。
        if !env.secureInput() {
            switch window.kind {
            case .localAuthentication:
                // Touch ID 那一页：回车 = 默认按钮「使用密码…」，之后密码框自己获得焦点。
                env.key(returnKey, [])
            case .authorization, .other:
                // 焦点停在用户名框：Tab 到密码框。
                env.key(tab, [])
            }
            _ = await wait(.milliseconds(1500)) { readyForPassword() || !sameWindow() }
        }
        guard sameWindow() else { return .gone }
        guard readyForPassword() else { return .notFocused }

        // 3. 清掉框里已有的字符，逐字打密码（每个字之前都核对一次），回车。
        env.key(keyA, .maskCommand)
        env.key(delete, [])
        for character in password {
            // 每个字之间让一下主线程：前台 App 靠主线程 run loop 上的通知更新，不让的话核对读到的是旧值。
            await env.sleep(.milliseconds(15))
            guard readyForPassword() else { return sameWindow() ? .notFocused : .gone }
            env.type(character)
        }
        guard readyForPassword() else { return sameWindow() ? .notFocused : .gone }
        env.key(returnKey, [])

        // 4. 框关了 = 通过；还在 = 密码不对（两种框输错都会抖一下、留在原处）。
        return await wait(.seconds(4)) { !sameWindow() } ? .accepted : .rejected
    }
}

@MainActor
extension RemoteAuthPromptTypist.Environment {
    /// 接到真实系统上。事件带 `RemoteInjectedEvent.userDataTag`：帘幕开着时也放行。
    static var live: Self {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = RemoteInjectedEvent.userDataTag
        let mouse = RemoteAuthPromptMouseCounter()
        return Self(
            window: { RemoteAuthPromptDetector.current() },
            frontPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            secureInput: { IsSecureEventInputEnabled() },
            click: { point in
                let origin = CGEvent(source: nil)?.location
                CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                // macOS 27 按 `mouseEventNumber` 把按下与抬起认成一次点击（见 `RemoteEventInjector`）。
                let number = mouse.next()
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                        mouseButton: .left)
                    event?.setIntegerValueField(.mouseEventNumber, value: number)
                    event?.setIntegerValueField(.mouseEventClickState, value: 1)
                    event?.post(tap: .cghidEventTap)
                }
                // 指针放回原处：远端的人没动鼠标，指针不该跳到框上。
                if let origin {
                    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: origin,
                            mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            },
            key: { code, flags in
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                    event?.flags = flags
                    event?.post(tap: .cghidEventTap)
                }
            },
            type: { character in
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.flags = []
                    units.withUnsafeBufferPointer {
                        event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                    event?.post(tap: .cghidEventTap)
                }
            },
            sleep: { try? await Task.sleep(for: $0) })
    }
}

/// 模拟点击用的 `mouseEventNumber`，取一段远离 `RemoteEventInjector`（从 0 往上数）的号。
nonisolated private final class RemoteAuthPromptMouseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1 << 30

    func next() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
