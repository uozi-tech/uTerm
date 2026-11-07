import AppKit

/// 本机键鼠事件 → 远程桌面输入（`RemoteDesktopInput`）。全是纯函数，画布只负责把 NSEvent 的字段喂进来。
///
/// 与手机不同，Mac 控 Mac 是绝对坐标：本机指针在画面上的位置就是那台 Mac 的指针位置，不做触控板式的相对移动。
/// 键盘发原始虚拟键码（两台 Mac 同一套键码），文字由那台 Mac 自己的输入法与键盘布局决定。
nonisolated enum RemoteDesktopEventMapper {
    /// 鼠标滚轮（非连续滚动）一格 `scrollingDeltaY` 换算多少像素。系统给的「行」已带滚轮加速，这里只乘行高。
    static let lineScrollPixels: CGFloat = 10

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> RemoteKeyModifiers {
        var result: RemoteKeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }

    /// 视图点 → 显示器归一化坐标，夹在 0...1：指针在黑边上时贴着最近的屏幕边。
    static func normalized(_ point: CGPoint, in viewport: RemoteDesktopViewport) -> (x: Float, y: Float) {
        let p = viewport.normalized(viewPoint: point)
        return (Float(min(1, max(0, p.x))), Float(min(1, max(0, p.y))))
    }

    /// 指针是否落在画面上（不在黑边里）。
    static func isOnDisplay(_ point: CGPoint, in viewport: RemoteDesktopViewport) -> Bool {
        let p = viewport.normalized(viewPoint: point)
        return (0...1).contains(p.x) && (0...1).contains(p.y)
    }

    /// 鼠标按键事件的类型 → 哪个键、按下还是抬起。拖动与移动不在这里（都发 `.move`）。
    static func button(for type: NSEvent.EventType) -> (button: RemoteMouseButton, down: Bool)? {
        switch type {
        case .leftMouseDown: return (.left, true)
        case .leftMouseUp: return (.left, false)
        case .rightMouseDown: return (.right, true)
        case .rightMouseUp: return (.right, false)
        case .otherMouseDown: return (.other, true)
        case .otherMouseUp: return (.other, false)
        default: return nil
        }
    }

    /// 滚动。`scrollingDeltaX/Y` 原样传（方向已按本机「自然滚动」设置换算过，注入到那台 Mac 时不会再反一次）；
    /// 鼠标滚轮给的是行，乘行高换成像素。`mayBegin`（手指刚碰到触控板）不发：还没有滚动，发了那边会提前停住惯性。
    static func scroll(dx: CGFloat, dy: CGFloat, precise: Bool,
                       phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> RemoteDesktopInput? {
        guard let mapped = scrollPhase(phase: phase, momentumPhase: momentumPhase) else { return nil }
        let factor = precise ? 1 : lineScrollPixels
        return .scroll(dx: Float(dx * factor), dy: Float(dy * factor), phase: mapped)
    }

    static func scrollPhase(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> RemoteScrollPhase? {
        if !momentumPhase.isEmpty {
            if momentumPhase.contains(.began) { return .momentumBegan }
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { return .momentumEnded }
            return .momentum
        }
        if phase.isEmpty { return RemoteScrollPhase.none }
        if phase.contains(.mayBegin) { return nil }
        if phase.contains(.began) { return .began }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        return .changed
    }

    /// 修饰键的虚拟键码 → 它对应的修饰位。
    static func modifier(forKeyCode code: UInt16) -> NSEvent.ModifierFlags? {
        switch code {
        case 0x38, 0x3C: return .shift
        case 0x3B, 0x3E: return .control
        case 0x3A, 0x3D: return .option
        case 0x37, 0x36: return .command
        case 0x39: return .capsLock
        case 0x3F: return .function
        default: return nil
        }
    }

    /// `flagsChanged`：某个修饰键按下或抬起。看新的修饰位里还有没有它，判断是按下还是抬起。
    /// 大写锁定每按一次才来一个事件（开 / 关），在那边完整按一下。左右两个同名键同时按着时抬起其中一个，
    /// 修饰位仍在，会被当成按下：那边多收一次按下无害，最后一个抬起时一起放开。
    static func modifierKey(code: UInt16, flags: NSEvent.ModifierFlags) -> [RemoteDesktopInput] {
        guard let flag = modifier(forKeyCode: code) else { return [] }
        let mods = modifiers(flags)
        if flag == .capsLock {
            return [.key(code: code, down: true, modifiers: mods), .key(code: code, down: false, modifiers: mods)]
        }
        return [.key(code: code, down: flags.contains(flag), modifiers: mods)]
    }

    /// ⌘V 这种组合：本机剪贴板里有东西时改成「粘贴到那台 Mac」（那边写进剪贴板再按 ⌘V），不直接转发按键。
    static let vKeyCode: UInt16 = 0x09

    static func isPasteShortcut(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.command, .control, .option, .shift])
        return code == vKeyCode && relevant == .command
    }
}
