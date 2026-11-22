import Foundation

/// 设置的分区（两端共用一份信息架构）。
///
/// macOS 设置窗按它画侧栏 / tab，iOS 设置根页按它排分组。`rawValue` 存在
/// `DefaultsKey.settingsTabSelection` 里（mac 记住上次打开的页），**已有的值不改**；
/// 改名的旧值在 `SettingsTabSelection.legacyRawValues` 里映射。
nonisolated enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case appearance
    case terminal
    case providers
    case connection
    case security
    case sync
    case remote
    case cli
    case diagnostics
    case about

    /// 分区在哪一端有页面。
    enum Availability: Sendable {
        case macOS
        case iOS
        case both

        func includes(_ platform: SettingsPlatform) -> Bool {
            switch self {
            case .both: return true
            case .macOS: return platform == .macOS
            case .iOS: return platform == .iOS
            }
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return String(localized: "通用", comment: "设置分区")
        case .appearance:  return String(localized: "外观", comment: "设置分区")
        case .terminal:    return String(localized: "终端", comment: "设置分区")
        case .providers:   return String(localized: "模型服务")
        case .connection:  return String(localized: "连接", comment: "设置分区")
        case .security:    return String(localized: "安全", comment: "设置分区")
        case .sync:        return String(localized: "同步", comment: "设置分区")
        case .remote:      return String(localized: "远程控制")
        case .cli:         return String(localized: "命令行与技能")
        case .diagnostics: return String(localized: "诊断", comment: "设置分区")
        case .about:       return String(localized: "关于", comment: "设置分区")
        }
    }

    /// 侧栏里的名字（侧栏只有 200pt 宽）：「命令行与技能」在有的语言里放不下，侧栏用短一点的写法，
    /// 页面标题仍用 `title`。
    var sidebarTitle: String {
        switch self {
        case .cli: return String(localized: "settings.sidebar.cli", defaultValue: "命令行与技能",
                                 comment: "设置侧栏里「命令行与技能」的短名字（侧栏窄，放不下时用缩写，如 CLI）")
        default: return title
        }
    }

    /// SF Symbol，两两不同（`SettingsCatalogTests` 钉住）。
    var symbol: String {
        switch self {
        case .general:     return "gearshape"
        case .appearance:  return "paintpalette"
        case .terminal:    return "terminal"
        case .providers:   return "sparkles"
        case .connection:  return "network"
        case .security:    return "lock.shield"
        case .sync:        return "arrow.triangle.2.circlepath.icloud"
        case .remote:      return "iphone.radiowaves.left.and.right"
        case .cli:         return "apple.terminal"
        case .diagnostics: return "stethoscope"
        case .about:       return "info.circle"
        }
    }

    /// 「通用」放的是启动与更新、「命令行与技能」是本机 IPC，两者只有 macOS 有；其余两端都有。
    var availability: Availability {
        switch self {
        case .general, .cli: return .macOS
        default: return .both
        }
    }
}

/// 两端平台标识（设置清单与分区可用性用）。
nonisolated enum SettingsPlatform: Hashable, Sendable {
    case macOS
    case iOS

    #if os(macOS)
    static let current = SettingsPlatform.macOS
    #else
    static let current = SettingsPlatform.iOS
    #endif
}

/// 旧名：macOS 设置窗早先叫它 tab。
typealias SettingsTab = SettingsSection

/// macOS 设置窗记住的分区（`@AppStorage(SettingsTabSelection.key)`）。
/// 「关于」菜单与命令面板写这个键再打开设置窗，深链到对应分区。
nonisolated enum SettingsTabSelection {
    static let key = DefaultsKey.settingsTabSelection
    static let aboutMenuTarget = SettingsSection.about.rawValue

    /// 已经不存在的旧 rawValue → 现在的分区。「高级」拆成了 连接 / 同步 / 诊断，落到「连接」。
    static let legacyRawValues: [String: SettingsSection] = [
        "advanced": .connection,
    ]

    static func tab(from rawValue: String?) -> SettingsSection {
        guard let rawValue else { return .general }
        return SettingsSection(rawValue: rawValue) ?? legacyRawValues[rawValue] ?? .general
    }
}
