import AppKit
import CoreGraphics
import Foundation

/// 把手机的输入合成成 `CGEvent` 投进系统（调研 §3.6 / §3.7）。
///
/// 需要「辅助功能」授权（PostEvent 沿用 Accessibility 的授权）；没有授权时 `post` 静默无效，
/// 所以开流时先查 `CGPreflightPostEventAccess`，没授权就告诉手机「只能看」，根本不建这个对象。
///
/// 鼠标事件按 macOS 27 的要求成组：一次按下到抬起之间的按下、拖动、抬起带同一个
/// `mouseEventNumber`。不设的话编号由系统逐个分配，macOS 27 不把抬起认作那次按下的结束，
/// 点击变成按住不放、窗口也拖不动（Chromium 远程桌面同样的修复：4e33c976af，2026-10）。
///
/// 两条投递路：
/// - 全局输入通道（`.cghidEventTap`）：看整块显示器时用。等于真的动了鼠标，Mac 上的指针跟着走。
/// - 按进程投递（`windowTarget` 不为 nil，见 `RemoteWindowInputTarget`）：只看一个窗口、主控端要了「独立键鼠」时用。
///   Mac 上的指针不动，手机上的指针画在 `virtualPointer`。
///
/// 只看一个窗口又走全局通道时（主控端关了独立键鼠、或者建不了投递目标），按下之前先看一眼这个点上最上面的窗口是不是
/// 别的 App 的：是就先把要看的窗口提到最前再点，免得点到别人头上（`pressGuard`）。
///
/// 只在连接队列上调用（串行），按键状态（哪个键按着、上次点击位置）因此不用加锁。
nonisolated final class RemoteEventInjector: RemoteDesktopInputSink, @unchecked Sendable {
    /// 归一化坐标对应的那块范围（全局坐标）。整块显示器时不变；只看一个窗口时跟着窗口走（`updateBounds`）。
    private var bounds: CGRect
    private let source: CGEventSource? = RemoteEventInjector.makeSource()
    /// 按进程投递的目标。nil = 走全局输入通道。
    private let windowTarget: RemoteWindowInputTarget?
    /// 走全局通道、只看一个窗口时，每次按下之前调一下（参数是按下的位置，全局坐标）。
    private let pressGuard: (@Sendable (CGPoint) -> Void)?
    /// 全局输入通道的出口（测试换成记录器，免得真的去动这台机器的鼠标）。
    private let hidPost: @Sendable (CGEvent) -> Void
    private var location: CGPoint
    private var pressed: Set<UInt8> = []
    /// 当前这次按键的编号：每次按下加一，之后的拖动与抬起沿用。
    private var mouseEventNumber: Int64 = 0
    /// 当前这次按键的连点次数与修饰键：拖动事件也要带上，和按下一致。
    private var clickState: Int64 = 1
    private var pressedFlags: CGEventFlags = []
    /// 像素滚动只收整数：小数部分攒起来，下一次一起发，慢速滚动才不会丢。
    private var scrollRemainder = CGPoint.zero

    init(display: RemoteDesktopDisplay, windowTarget: RemoteWindowInputTarget? = nil,
         pressGuard: (@Sendable (CGPoint) -> Void)? = nil,
         hidPost: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        bounds = display.bounds
        location = CGPoint(x: display.bounds.midX, y: display.bounds.midY)
        self.windowTarget = windowTarget
        self.pressGuard = windowTarget == nil ? pressGuard : nil
        self.hidPost = hidPost
    }

    /// 生产用的那一个：只看一个窗口时，`independent` 决定走按进程投递还是全局通道加「先提到最前」。
    @MainActor
    static func live(display: RemoteDesktopDisplay, independent: Bool) -> RemoteEventInjector {
        guard let windowID = display.windowID else { return RemoteEventInjector(display: display) }
        if independent, let target = RemoteWindowInputTarget.live(windowID: windowID, source: makeSource()) {
            return RemoteEventInjector(display: display, windowTarget: target)
        }
        return RemoteEventInjector(display: display, pressGuard: { point in
            RemoteDesktopWindows.uncover(id: windowID, at: point)
        })
    }

    static func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        // 帘幕模式靠这个标记认出「手机注入的事件」并放行，本机键鼠则拦掉。
        source?.userData = RemoteInjectedEvent.userDataTag
        return source
    }

    /// 按进程投递时 Mac 上的指针不动：手机上的指针画在我们自己记的位置。
    var virtualPointer: CGPoint? { windowTarget == nil ? nil : location }

    func updateBounds(_ bounds: CGRect) {
        self.bounds = bounds
    }

    func inject(_ input: RemoteDesktopInput) {
        switch input {
        case .move:
            postMouse(mouseEvent(for: input), phase: pressed.isEmpty ? .hover : .drag)
        case .button(_, let down, _, _, _, _):
            if down, let pressGuard, case .button(_, _, _, let x, let y, _) = input {
                pressGuard(RemoteDesktopGeometry.globalPoint(x: x, y: y, displayBounds: bounds))
            }
            postMouse(mouseEvent(for: input), phase: down ? .down : .up)
        case .scroll(let dx, let dy, let phase):
            // 增量来自手机：非有限值或超出 Int32 的值转换时会直接崩掉整个 App，先夹住。
            let total = CGPoint(x: Self.clampScroll(scrollRemainder.x + CGFloat(dx)),
                                y: Self.clampScroll(scrollRemainder.y + CGFloat(dy)))
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
            if let windowTarget { windowTarget.deliverScroll(event, at: location) } else { post(event) }
        case .key(let code, let down, let modifiers):
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            if let event { event.flags = Self.keyFlags(intrinsic: event.flags, modifiers: modifiers) }
            postKey(event)
        case .text(let text):
            typeText(text)
        }
    }

    func releaseButtons() {
        for button in pressed.compactMap(RemoteMouseButton.init(rawValue:)) {
            let (type, cgButton) = Self.buttonEvent(button, down: false)
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                                mouseButton: cgButton)
            stampPress(event, flags: pressedFlags)
            postMouse(event, phase: .up)
        }
        pressed = []
        // 停流时调的：顺手把「让目标以为自己是当前 App」撤掉。
        windowTarget?.finish()
    }

    /// 指针移动 / 按键对应的鼠标事件（不投递），并更新按键状态。其余输入返回 nil。
    func mouseEvent(for input: RemoteDesktopInput) -> CGEvent? {
        switch input {
        case .move(let x, let y):
            location = RemoteDesktopGeometry.globalPoint(x: x, y: y, displayBounds: bounds)
            let (type, button) = dragType()
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                                mouseButton: button)
            if !pressed.isEmpty { stampPress(event, flags: pressedFlags) }
            return event
        case .button(let button, let down, let clicks, let x, let y, let modifiers):
            location = RemoteDesktopGeometry.globalPoint(x: x, y: y, displayBounds: bounds)
            let flags = Self.flags(modifiers)
            if down {
                // 另一个键已按着时（左键拖动中再按右键）不开新的一组：抬起要和最早那次按下配对。
                if pressed.isEmpty { mouseEventNumber += 1 }
                pressed.insert(button.rawValue)
                clickState = Int64(max(1, clicks))
                pressedFlags = flags
            } else {
                pressed.remove(button.rawValue)
            }
            let (type, cgButton) = Self.buttonEvent(button, down: down)
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                                mouseButton: cgButton)
            stampPress(event, flags: flags)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clicks)))
            return event
        case .scroll, .key, .text:
            return nil
        }
    }

    private func stampPress(_ event: CGEvent?, flags: CGEventFlags) {
        event?.setIntegerValueField(.mouseEventNumber, value: mouseEventNumber)
        event?.setIntegerValueField(.mouseEventClickState, value: clickState)
        event?.flags = flags
    }

    /// 写剪贴板再按 ⌘V。图片按原始格式放（PNG / JPEG 各自的 UTI），收图的 app 自己挑能读的；
    /// 不转 TIFF——几 MB 的截图转一次要上百毫秒，而这里是连接队列。
    func paste(_ content: RemoteDesktopPaste) {
        switch content {
        case .text(let text):
            RemotePasteboard.write(text: text)
        case .png(let data):
            RemotePasteboard.write(TerminalImage(format: .png, data: data))
        case .jpeg(let data):
            RemotePasteboard.write(TerminalImage(format: .jpeg, data: data))
        }
        pressPaste()
    }

    /// 文件按「文件」放进剪贴板（同在访达里拷贝）：聊天、邮件、访达这类 app 粘贴出来就是这个视频。
    func pasteFile(at url: URL) {
        RemotePasteboard.write(file: url)
        pressPaste()
    }

    private func pressPaste() {
        for down in [true, false] {
            inject(.key(code: RemoteKeyMap.Key.v, down: down, modifiers: .command))
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
                postKey(event)
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
        guard let event else { return }
        hidPost(event)
    }

    private func postMouse(_ event: CGEvent?, phase: RemoteWindowInputTarget.MousePhase) {
        guard let event else { return }
        if let windowTarget { windowTarget.deliverMouse(event, at: location, phase: phase) } else { post(event) }
    }

    private func postKey(_ event: CGEvent?) {
        guard let event else { return }
        if let windowTarget { windowTarget.deliverKey(event) } else { post(event) }
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

    /// 按键事件的标志：修饰键 + 这个键自带的标志。`CGEvent` 给方向键自带 fn 与小键盘、给 F 键与
    /// home / end / 翻页 / 向前删除自带 fn，和真键盘一样；系统快捷键是连这些一起登记的（⌃← 切换桌面
    /// 登记成 ⌃fn←），只填修饰键会对不上，按了没反应。
    static func keyFlags(intrinsic: CGEventFlags, modifiers: RemoteKeyModifiers) -> CGEventFlags {
        intrinsic.intersection([.maskSecondaryFn, .maskNumericPad]).union(flags(modifiers))
    }

    /// 单次滚动像素上限：远大于任何真实手势，又远小于 Int32 上限。
    static func clampScroll(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, -100_000), 100_000)
    }

    /// 手势阶段 → (`scrollPhase`, `momentumPhase`)。前者取 `CGScrollPhase`（began 1 / changed 2 / ended 4），
    /// 它和 `NSEvent.Phase` 的位值不同：写 4 时 app 读到的是 ended。后者取 `CGMomentumScrollPhase`
    /// （begin 1 / continue 2 / end 3）。
    static func phases(_ phase: RemoteScrollPhase) -> (Int64, Int64) {
        switch phase {
        case .none: return (0, 0)
        case .began: return (1, 0)
        case .changed: return (2, 0)
        case .ended: return (4, 0)
        case .momentumBegan: return (0, 1)
        case .momentum: return (0, 2)
        case .momentumEnded: return (0, 3)
        }
    }
}
