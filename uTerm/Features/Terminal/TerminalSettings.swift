import AppKit

/// 一站读取所有终端设置的纯数据 struct。便于把当前 setting 一次性传给
/// `TerminalTheme.apply`、单元测试、TerminalPreview 等消费者。
///
/// 终端/编辑器字体（族/字号/行距）与配色不再可自定义：字体走系统等宽，
/// 字号/行距固定，配色固定 VS Code 家族（按外观取深/浅），均为 `static` 常量。
/// 仅光标 / 历史 / 选中即复制 仍由 `@AppStorage` 驱动；读取由调用方
/// （TerminalHostView / TerminalSettingsView）用 `@AppStorage` 单独完成。
nonisolated struct TerminalSettings: Equatable {
    /// 统一系统等宽字体族，不注册或打包自定义字体。
    static let fontName = "System Monospaced"
    static let fontSize: Double = 12
    static let lineHeight: Double = 1.0
    static let defaultScrollback = 3_000

    @MainActor
    static func textFont(ofSize size: CGFloat = CGFloat(fontSize)) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }

    var cursorShape: TerminalCursorShape
    var cursorBlink: Bool
    var scrollback: Int
    var copyOnSelect: Bool

    /// 用 UserDefaults 实际值 + 写死的 fallback 构造，对应 @AppStorage 默认。
    /// 这是测试时的便捷入口；生产代码直接用 @AppStorage 属性。
    static func read(from defaults: UserDefaults = .standard) -> TerminalSettings {
        TerminalSettings(
            cursorShape: TerminalCursorShape(
                rawValue: defaults.string(forKey: DefaultsKey.terminalCursorShape) ?? "block"
            ) ?? .block,
            cursorBlink: (defaults.object(forKey: DefaultsKey.terminalCursorBlink) as? Bool) ?? false,
            scrollback: (defaults.object(forKey: DefaultsKey.terminalScrollback) as? Int) ?? defaultScrollback,
            copyOnSelect: (defaults.object(forKey: DefaultsKey.terminalCopyOnSelect) as? Bool) ?? false
        )
    }

    /// 按 app 外观解析后的 color scheme（运行时构造，不存）。
    @MainActor
    func colorScheme(dark: Bool) -> TerminalColorScheme {
        TerminalColorScheme.resolve(dark: dark)
    }
}
