import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// 用户对 app 主题的选择。UserDefaults key: `appearancePreference`。默认 `.system`。
///
/// 应用处 = `uTermApp` 把 `nsAppearance` 写到 `NSApplication.shared.appearance`：
///   .light  → NSAppearance(.aqua)
///   .dark   → NSAppearance(.darkAqua)
///   .system → nil（让 macOS 系统外观决定）
///
/// 写入处 = `GeneralSettingsView` 的"外观"区组 Picker。改动**立即生效**。
///
/// 为什么用 `NSApp.appearance` 而不是 Scene 的 `.preferredColorScheme(_:)`：
/// `.preferredColorScheme` 在「显式值 → nil（跟随系统）」这条切换上，
/// **不会** live-reset 已经打开的窗口——SwiftUI 给窗口盖的 `NSWindow.appearance`
/// override 残留着，于是窗口 material 跟到了系统浅色、但系统语义色文本
/// token 还 resolve 成深色变体（白字白底）。光改 `NSApp.appearance` 也压不住
/// 残留的 per-window override，所以 Scene 上必须**彻底去掉** `.preferredColorScheme`，
/// 让所有窗口 `appearance == nil`、统一跟随 `NSApp.appearance`，切回系统才会即时生效。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .light:  return String(localized: "浅色", comment: "外观：浅色主题")
        case .dark:   return String(localized: "深色", comment: "外观：深色主题")
        case .system: return String(localized: "跟随系统")
        }
    }

    /// 转 SwiftUI `ColorScheme`；nil = 跟随系统。保留作语义映射（如 preview）；
    /// app 实际应用的是 `nsAppearance`，原因见类型文档。
    var colorScheme: ColorScheme? {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }

    #if canImport(AppKit)
    /// 写到 `NSApplication.shared.appearance` 的值；nil = 跟随系统。
    /// 这是 app 真正应用的映射——见类型文档解释为何不用 `.preferredColorScheme`。
    var nsAppearance: NSAppearance? {
        switch self {
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
    #endif
}
