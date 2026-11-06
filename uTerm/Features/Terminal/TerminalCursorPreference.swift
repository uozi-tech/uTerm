import Foundation

/// 终端光标的样式：形状 + 闪烁。两端终端视图记下「上次装进视图的样式」，只在变了才重装——
/// 装光标会盖掉程序自己设的（vim 插入模式的竖线），不能每次视图更新都装。
nonisolated struct TerminalCursorLook: Equatable, Sendable {
    var shape: TerminalCursorShape
    var blink: Bool
}

/// 光标两项偏好（`terminalCursorShape` / `terminalCursorBlink`，两端同步）的读取与默认值，只写一份。
/// 默认稳定块光标（不闪烁）；存了认不得的 rawValue 回落到块。
nonisolated enum TerminalCursorPreference {
    static let defaultShape: TerminalCursorShape = .block
    static let defaultBlink = false

    static func shape(rawValue: String?) -> TerminalCursorShape {
        rawValue.flatMap(TerminalCursorShape.init(rawValue:)) ?? defaultShape
    }

    static func read(from defaults: UserDefaults = .standard) -> TerminalCursorLook {
        TerminalCursorLook(
            shape: shape(rawValue: defaults.string(forKey: DefaultsKey.terminalCursorShape)),
            blink: (defaults.object(forKey: DefaultsKey.terminalCursorBlink) as? Bool) ?? defaultBlink
        )
    }
}
