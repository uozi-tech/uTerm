import SwiftUI

/// 用户对 app 主题的选择。UserDefaults key: `appearancePreference`。默认 `.system`。
///
/// 读取处 = `uTermApp` 各 Scene 的 `.preferredColorScheme(_:)`：
///   .light  → ColorScheme.light
///   .dark   → ColorScheme.dark
///   .system → nil（让 macOS 系统外观决定）
///
/// 写入处 = `GeneralSettingsView` 的"外观"区组 Picker。改动**立即生效**——
/// SwiftUI 重渲染 Scene 时 NSWindow.appearance 跟着切。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .light:  return "浅色"
        case .dark:   return "深色"
        case .system: return "跟随系统"
        }
    }

    /// 转 SwiftUI `.preferredColorScheme(_:)` 的入参；nil = 跟随系统。
    var colorScheme: ColorScheme? {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }
}
