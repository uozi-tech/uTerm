@testable import uTermMobile
import XCTest

/// 终端 / 远程桌面弹键盘时选哪个输入法（`KeyboardLanguageMemory`）。
@MainActor
final class KeyboardLanguageMemoryTests: XCTestCase {
    private typealias Memory = KeyboardLanguageMemory
    private let installed = ["en-US", "zh-Hans", "emoji"]

    func testDefaultsToEnglishUntilTheUserSwitches() {
        XCTAssertEqual(Memory.pick(saved: nil, current: "zh-Hans", hasRemembered: false, available: installed), .english,
                       "没切过：命令行默认英文，哪怕系统上次用的是中文")
        XCTAssertEqual(Memory.pick(saved: "en-GB", current: "zh-Hans", hasRemembered: true, available: installed), .english,
                       "切回过英文：英文")
        XCTAssertEqual(Memory.pick(saved: nil, current: "zh-Hans", hasRemembered: false, available: ["zh-Hans"]), .current,
                       "系统里没有英文键盘：不指定")
    }

    /// 微信、搜狗这些第三方输入法拿不到能交还给系统的输入法对象：选过非英文后不指定，系统此刻的键盘就是它。
    func testKeepsTheKeyboardTheUserIsOnAfterChoosingANonEnglishOne() {
        XCTAssertEqual(Memory.pick(saved: "zh-Hans", current: "zh-Hans", hasRemembered: true, available: installed), .current)
        XCTAssertEqual(Memory.pick(saved: "zh-Hans", current: "ja-JP", hasRemembered: false, available: installed), .current,
                       "此刻是别的非英文键盘：也不动")
    }

    /// 选过中文，但别处把系统键盘换成了英文（或表情）：找回在这里选的那个。
    func testComesBackToTheChosenKeyboardWhenSomethingElseSwitchedToEnglish() {
        XCTAssertEqual(Memory.pick(saved: "zh-Hans", current: "en-US", hasRemembered: true, available: installed), .remembered)
        XCTAssertEqual(Memory.pick(saved: "zh-Hans", current: "emoji", hasRemembered: true, available: installed), .remembered)
        XCTAssertEqual(Memory.pick(saved: "zh-Hans", current: "en-US", hasRemembered: false, available: installed),
                       .language("zh-Hans"), "重开 App 后没有这次运行的记忆：按语言找系统键盘")
        XCTAssertEqual(Memory.pick(saved: "ja-JP", current: "en-US", hasRemembered: false, available: installed), .current,
                       "那个键盘已经删了：不指定")
    }

    func testEmojiAndDictationAreNotRememberedAsTheLanguage() {
        XCTAssertTrue(Memory.isRememberable(language: "zh-Hans"))
        XCTAssertFalse(Memory.isRememberable(language: "emoji"))
        XCTAssertFalse(Memory.isRememberable(language: "dictation"))
    }

    /// 记在偏好里：新开的标签、重开的 App 都读同一份；终端和远程桌面各一份。
    func testChoiceIsPersistedPerSurface() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "KeyboardLanguageMemoryTests"))
        defaults.removePersistentDomain(forName: "KeyboardLanguageMemoryTests")
        defer { defaults.removePersistentDomain(forName: "KeyboardLanguageMemoryTests") }
        let terminal = Memory(key: "terminal", defaults: defaults)
        let remote = Memory(key: "remote", defaults: defaults)
        XCTAssertNil(terminal.savedLanguage)

        terminal.record(nil)
        XCTAssertNil(terminal.savedLanguage, "拿不到键盘不记")
        defaults.set("zh-Hans", forKey: "terminal")
        XCTAssertEqual(Memory(key: "terminal", defaults: defaults).savedLanguage, "zh-Hans", "新的实例（重开 App）读到同一份")
        XCTAssertNil(remote.savedLanguage, "远程桌面另记")

        terminal.clear()
        XCTAssertNil(terminal.savedLanguage)
    }

    func testTerminalAndRemoteDesktopUseTheirOwnKeys() {
        XCTAssertEqual(DefaultsKey.mobileTerminalKeyboardLanguage, "mobile.terminal.keyboardLanguage")
        XCTAssertEqual(DefaultsKey.remoteDesktopKeyboardLanguage, "remote.desktop.keyboardLanguage",
                       "沿用旧键：已经切过中文的用户升级后照旧")
    }
}
