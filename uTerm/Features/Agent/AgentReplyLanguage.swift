import Foundation

/// 给大模型的提示词本身是中文写的；模型的回答要落在用户的界面语言上，靠这里给出的语言名。
///
/// 界面语言取 `Bundle.main.preferredLocalizations`（已经考虑了「设置 › 外观 › 语言」与系统的 App 语言），
/// 所以和 uTerm 此刻显示的文案一致。两端共享。
nonisolated enum AgentReplyLanguage {
    /// 界面语言的名字，用它自己的写法（模型都认得）。
    static var displayName: String {
        displayName(for: Bundle.main.preferredLocalizations.first ?? "zh-Hans")
    }

    static func displayName(for localization: String) -> String {
        let id = localization.lowercased()
        if id.hasPrefix("zh-hant") || id == "zh-tw" || id == "zh-hk" { return "繁體中文" }
        if id.hasPrefix("zh") { return "简体中文" }
        if id.hasPrefix("ja") { return "日本語" }
        if id.hasPrefix("ko") { return "한국어" }
        if id.hasPrefix("en") { return "English" }
        return "English"
    }
}
