import SwiftUI
import AppKit

/// 让**所有**窗口（含已打开的、含 Settings）即时跟着主题偏好切——含切回「跟随系统」。
/// 两路并用、缺一不可：
///   1. `.environment(\.colorScheme,)` —— 驱动 SwiftUI 环境，让 chrome 的 `UD.dyn`
///      动态色**即时**重算配色（switching 的关键，详见 `body` 内注释）。
///   2. `NSApp.appearance`（onChange）—— 切系统 chrome：titlebar / 滚动条 / 系统控件 / 焦点环。
///
/// 为何不用 Scene 的 `.preferredColorScheme`（它一把抓上面两件事）：见 `AppearancePreference`
/// 类型文档——它会顺带写 per-window `NSWindow.appearance`，在「显式 → 跟随系统」切换上
/// 残留 override（白字白底）。`.environment(\.colorScheme,)` 只改环境值、不碰 NSWindow.appearance。
///
/// 初始值在 `uTermApp.init()` 里设；这里只负责用户在运行时改设置后的 live 同步。
/// `NSApp.appearance` 是 app 级全局状态，任一挂了本 modifier 的存活窗口接到
/// `onChange` 即可，新开的窗口自动跟随，无需逐窗口处理。
struct AppAppearanceSync: ViewModifier {
    let preference: AppearancePreference
    /// 环境里来自窗口 `effectiveAppearance` 的 ambient colorScheme。`.system` 模式下
    /// 原样透传它（跟随系统），让 `.environment` 始终在场——切主题不改视图结构
    /// identity（否则 if/else 分支切换会重挂 content、丢状态）。
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        content
            // 「即时切换」的关键：chrome 的 `UD.dyn` 动态色按 `\.colorScheme` 环境
            // resolve（见 `UD.dyn`），改这个 env 会立刻让用到它的视图重算配色。
            // 而光改 `NSApp.appearance` 只更新窗口 `effectiveAppearance`（titlebar /
            // 滚动条 / 系统控件），**不会**及时把新 colorScheme 灌进 SwiftUI 环境，
            // 内容色因此滞后——这正是「颜色没有及时切换」的根因（c437e67 删掉
            // `.preferredColorScheme` 后只剩 `NSApp.appearance` 一路）。
            .environment(\.colorScheme, preference.colorScheme ?? systemScheme)
            .onChange(of: preference) { _, new in
                NSApplication.shared.appearance = new.nsAppearance
            }
    }
}

/// 条件性挂 `.environment(\.locale, _:)` 的 modifier：`.system` 模式下
/// 不挂任何修改，让 SwiftUI 走默认 `Locale.current`；其它模式下覆盖。
struct LocaleOverride: ViewModifier {
    let locale: Locale?
    func body(content: Content) -> some View {
        if let locale {
            content.environment(\.locale, locale)
        } else {
            content
        }
    }
}
