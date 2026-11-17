import UIKit

/// 终端、远程桌面弹键盘时用哪个输入法：第一次用英文；用户在这里切到别的（中文写提交说明、跟 Claude Code 说话），
/// 之后一直是他选的，新开标签、重新连接、重开 App 都不再翻回英文。终端与远程桌面各记各的。
///
/// 记的是语言（存偏好），不是某个键盘：微信、搜狗这些第三方输入法拿不到能交还给系统的输入法对象，
/// 所以记成「不是英文」时我们不指定，交给系统弹用户手上正在用的那个键盘。
@MainActor
final class KeyboardLanguageMemory {
    static let terminal = KeyboardLanguageMemory(key: DefaultsKey.mobileTerminalKeyboardLanguage)
    static let remoteDesktop = KeyboardLanguageMemory(key: DefaultsKey.remoteDesktopKeyboardLanguage)

    private let key: String
    private let defaults: UserDefaults
    /// 这次运行里在这里选过的非英文键盘。当前键盘被别处换成英文后，靠它找回来（对系统键盘有效）。
    private var remembered: UITextInputMode?

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    var savedLanguage: String? { defaults.string(forKey: key) }

    /// 给 `textInputMode` 用：`current` 是系统此刻的键盘（`super.textInputMode`）。
    func inputMode(current: UITextInputMode?) -> UITextInputMode? {
        let modes = UITextInputMode.activeInputModes
        switch Self.pick(saved: savedLanguage, current: current?.primaryLanguage, hasRemembered: remembered != nil,
                         available: modes.compactMap(\.primaryLanguage)) {
        case .english: return modes.first { $0.primaryLanguage?.hasPrefix("en") == true } ?? current
        case .current: return current
        case .remembered: return remembered ?? current
        case .language(let language): return modes.first { $0.primaryLanguage == language } ?? current
        }
    }

    /// 用户在这里切了键盘（只在自己是第一响应者时调）。表情和听写不算选了语言。
    func record(_ mode: UITextInputMode?) {
        guard let language = mode?.primaryLanguage, Self.isRememberable(language: language) else { return }
        remembered = Self.isEnglish(language) ? nil : mode
        defaults.set(language, forKey: key)
    }

    /// 忘掉记过的（测试用：测试宿主和正式版共用一份偏好）。
    func clear() {
        remembered = nil
        defaults.removeObject(forKey: key)
    }

    // MARK: 规则（纯函数）

    nonisolated enum Pick: Equatable {
        /// 系统的英文键盘。
        case english
        /// 不指定，系统此刻是哪个就是哪个（第三方输入法只能走这条）。
        case current
        /// 这次运行里在这里选过的那个键盘。
        case remembered
        /// 系统列表里这个语言的键盘。
        case language(String)
    }

    nonisolated static func pick(saved: String?, current: String?, hasRemembered: Bool, available: [String]) -> Pick {
        guard let saved, !isEnglish(saved) else {
            return available.contains(where: isEnglish) ? .english : .current
        }
        // 用户选过别的语言：系统此刻就是一个非英文键盘（多半就是他那个，第三方输入法也在内），不动它。
        if let current, isRememberable(language: current), !isEnglish(current) { return .current }
        if hasRemembered { return .remembered }
        if available.contains(saved) { return .language(saved) }
        return .current
    }

    nonisolated static func isRememberable(language: String) -> Bool {
        language != "emoji" && language != "dictation"
    }

    nonisolated static func isEnglish(_ language: String) -> Bool { language.hasPrefix("en") }
}
