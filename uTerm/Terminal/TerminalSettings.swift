import Foundation

/// 一站读取所有终端设置的纯数据 struct。便于把当前 setting 一次性传给
/// `TerminalTheme.apply`、单元测试、TerminalPreview 等消费者。
///
/// 各字段对应一个 `@AppStorage` key；本 struct **不**绑定 SwiftUI，
/// 只是值类型。读取由调用方（TerminalHostView / TerminalSettingsView）
/// 用 `@AppStorage` 单独完成，再传给本结构构造器。
struct TerminalSettings: Equatable {
    var fontName: String
    var fontSize: Double
    var lineHeight: Double
    var colorSchemeID: TerminalColorSchemeID
    var cursorShape: TerminalCursorShape
    var cursorBlink: Bool
    var scrollback: Int
    var copyOnSelect: Bool

    /// 用 UserDefaults 实际值 + 写死的 fallback 构造，对应 @AppStorage 默认。
    /// 这是测试时的便捷入口；生产代码直接用 @AppStorage 属性。
    static func read(from defaults: UserDefaults = .standard) -> TerminalSettings {
        TerminalSettings(
            fontName: defaults.string(forKey: "terminalFontName") ?? "Menlo",
            fontSize: (defaults.object(forKey: "terminalFontSize") as? Double) ?? 11,
            lineHeight: (defaults.object(forKey: "terminalLineHeight") as? Double) ?? 1.0,
            colorSchemeID: TerminalColorSchemeID(
                rawValue: defaults.string(forKey: "terminalColorScheme") ?? "vscode-dark"
            ) ?? .vscodeDark,
            cursorShape: TerminalCursorShape(
                rawValue: defaults.string(forKey: "terminalCursorShape") ?? "block"
            ) ?? .block,
            cursorBlink: (defaults.object(forKey: "terminalCursorBlink") as? Bool) ?? false,
            scrollback: (defaults.object(forKey: "terminalScrollback") as? Int) ?? 3000,
            copyOnSelect: (defaults.object(forKey: "terminalCopyOnSelect") as? Bool) ?? false
        )
    }

    /// 解析后的 color scheme（运行时构造，不存）。
    var colorScheme: TerminalColorScheme {
        TerminalColorScheme.scheme(for: colorSchemeID)
    }
}
