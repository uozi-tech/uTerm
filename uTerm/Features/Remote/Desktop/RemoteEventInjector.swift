import CoreGraphics
import Foundation

/// 把手机的输入合成成 `CGEvent` 投进系统（调研 §3.6 / §3.7）。
///
/// 需要「辅助功能」授权（PostEvent 沿用 Accessibility 的授权）；没有授权时 `post` 静默无效，
/// 所以开流时先查 `CGPreflightPostEventAccess`，没授权就告诉手机「只能看」，根本不建这个对象。
///
/// 只在连接队列上调用（串行），按键状态（哪个键按着、上次点击位置）因此不用加锁。
nonisolated final class RemoteEventInjector: RemoteDesktopInputSink, @unchecked Sendable {
    private let display: RemoteDesktopDisplay
    private let source = CGEventSource(stateID: .hidSystemState)
    private var location: CGPoint
    private var pressed: Set<UInt8> = []
    /// 像素滚动只收整数：小数部分攒起来，下一次一起发，慢速滚动才不会丢。
    private var scrollRemainder = CGPoint.zero

    init(display: RemoteDesktopDisplay) {
        self.display = display
        location = CGPoint(x: display.bounds.midX, y: display.bounds.midY)
    }

    func inject(_ input: RemoteDesktopInput) {
        switch input {
        case .move(let x, let y):
            location = RemoteDesktopGeometry.globalPoint(x: x, y: y, displayBounds: display.bounds)
            let (type, button) = dragType()
            post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button))
        case .button(let button, let down, let clicks, let x, let y, let modifiers):
            location = RemoteDesktopGeometry.globalPoint(x: x, y: y, displayBounds: display.bounds)
            if down { pressed.insert(button.rawValue) } else { pressed.remove(button.rawValue) }
            let (type, cgButton) = Self.buttonEvent(button, down: down)
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                                mouseButton: cgButton)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clicks)))
            event?.flags = Self.flags(modifiers)
            post(event)
        case .scroll(let dx, let dy, let phase):
            let total = CGPoint(x: scrollRemainder.x + CGFloat(dx), y: scrollRemainder.y + CGFloat(dy))
            let wheelY = Int32(total.y.rounded(.towardZero)), wheelX = Int32(total.x.rounded(.towardZero))
            scrollRemainder = CGPoint(x: total.x - CGFloat(wheelX), y: total.y - CGFloat(wheelY))
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                      wheel1: wheelY, wheel2: wheelX, wheel3: 0) else { return }
            event.location = location
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            let (scrollPhase, momentumPhase) = Self.phases(phase)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
            if phase == .ended || phase == .momentumEnded { scrollRemainder = .zero }
            post(event)
        case .key(let code, let down, let modifiers):
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = Self.flags(modifiers)
            post(event)
        case .text(let text):
            typeText(text)
        }
    }

    /// 按 Unicode 直接注入（绕开 Mac 当前的输入法 / 键盘布局）。一个事件最多带 20 个 UTF-16 单元。
    private func typeText(_ text: String) {
        var units = Array(text.utf16)
        while !units.isEmpty {
            var chunk = Array(units.prefix(20))
            // 别把代理对切成两半。
            if chunk.count == 20, let last = chunk.last, UTF16.isLeadSurrogate(last) { chunk.removeLast() }
            units.removeFirst(chunk.count)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                post(event)
            }
        }
    }

    private func dragType() -> (CGEventType, CGMouseButton) {
        if pressed.contains(RemoteMouseButton.left.rawValue) { return (.leftMouseDragged, .left) }
        if pressed.contains(RemoteMouseButton.right.rawValue) { return (.rightMouseDragged, .right) }
        if pressed.contains(RemoteMouseButton.other.rawValue) { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    static func buttonEvent(_ button: RemoteMouseButton, down: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case .left: return (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: return (down ? .rightMouseDown : .rightMouseUp, .right)
        case .other: return (down ? .otherMouseDown : .otherMouseUp, .center)
        }
    }

    static func flags(_ modifiers: RemoteKeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// 手势阶段 → (`scrollPhase`, `momentumPhase`)。前者取 `NSEvent.Phase` 的位值（began 1 / changed 4 /
    /// ended 8），后者取 `CGMomentumScrollPhase`（begin 1 / continue 2 / end 3）。
    static func phases(_ phase: RemoteScrollPhase) -> (Int64, Int64) {
        switch phase {
        case .none: return (0, 0)
        case .began: return (1, 0)
        case .changed: return (4, 0)
        case .ended: return (8, 0)
        case .momentumBegan: return (0, 1)
        case .momentum: return (0, 2)
        case .momentumEnded: return (0, 3)
        }
    }
}
