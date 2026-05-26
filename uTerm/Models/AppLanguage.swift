import Foundation

/// 用户对 app 显示语言的选择。UserDefaults key: `appLanguage`。默认 `.system`。
///
/// 读取处 = `uTermApp` 各 Scene 的 `.environment(\.locale, _:)`（经 LocaleOverride
/// ViewModifier 条件性挂）：
///   .system → 不挂 modifier（让 SwiftUI 走默认 Locale.current = macOS 系统语言）
///   .zhHans → Locale(identifier: "zh-Hans")
///   .en     → Locale(identifier: "en")
///
/// 写入处 = `GeneralSettingsView` 的"外观"区组下"语言" Picker。
/// 改 setting 后**需重启 app 生效**（macOS 本地化在 launch 时决议；运行时切
/// 部分 UI 不刷新）—— UI hint 已标明。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .en:     return "English"
        }
    }

    /// 转 SwiftUI `.environment(\.locale, _:)` 的入参；nil = 跟随系统（不挂 modifier）。
    var locale: Locale? {
        switch self {
        case .system: return nil
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .en:     return Locale(identifier: "en")
        }
    }
}
