import Foundation

/// 用户对 app 显示语言的选择。UserDefaults key: `appLanguage`。默认 `.system`。
///
/// 两处生效：
///   - 本进程的 `AppleLanguages`（`applyToBundleLocalization`）：`String(localized:)` 与
///     `Text("…")` 查文案目录时按它挑语言。Bundle 在启动时决议语言，所以**重启 uTerm 后生效**
///     （设置页的说明已标明）；启动时再对一遍，iCloud / 局域网同步过来的选择下次启动也会生效。
///   - `uTermApp` 各 Scene 的 `.environment(\.locale, _:)`（`LocaleOverride`）：日期、数字的格式。
///     `.system` 不挂，走系统的 `Locale.current`。
///
/// 写入处 = 设置 › 外观 › 语言。只有 mac 有入口；iOS 用系统设置里的「App 语言」。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case ko

    var id: String { rawValue }

    /// 语言名用它自己的写法（「English」「日本語」），换了语言也认得出来；只有「跟随系统」随界面语言。
    var localizedLabel: String {
        switch self {
        case .system: return String(localized: "跟随系统", comment: "界面语言选项：跟随系统语言")
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en:     return "English"
        case .ja:     return "日本語"
        case .ko:     return "한국어"
        }
    }

    /// 转 SwiftUI `.environment(\.locale, _:)` 的入参；nil = 跟随系统（不挂 modifier）。
    var locale: Locale? {
        switch self {
        case .system: return nil
        default: return Locale(identifier: rawValue)
        }
    }

    /// 写本进程（app 自己的偏好域）的 `AppleLanguages`；`.system` 删掉它，回到系统的语言顺序。
    /// 下次启动起效。
    func applyToBundleLocalization(defaults: UserDefaults = .standard) {
        switch self {
        case .system:
            defaults.removeObject(forKey: DefaultsKey.appleLanguages)
        default:
            if defaults.stringArray(forKey: DefaultsKey.appleLanguages) != [rawValue] {
                defaults.set([rawValue], forKey: DefaultsKey.appleLanguages)
            }
        }
    }

    /// 启动时按已存的选择对一遍 `AppleLanguages`。
    static func applyStoredPreference(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: DefaultsKey.appLanguage).flatMap(AppLanguage.init(rawValue:)) ?? .system
        stored.applyToBundleLocalization(defaults: defaults)
    }
}
