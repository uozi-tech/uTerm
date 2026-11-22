import XCTest
@testable import uTerm

@MainActor
final class AppLanguageTests: XCTestCase {
    func test_allCases_order() {
        XCTAssertEqual(AppLanguage.allCases, [.system, .zhHans, .zhHant, .en, .ja, .ko])
    }

    func test_rawValues() {
        XCTAssertEqual(AppLanguage.system.rawValue, "system")
        XCTAssertEqual(AppLanguage.zhHans.rawValue, "zh-Hans")
        XCTAssertEqual(AppLanguage.zhHant.rawValue, "zh-Hant")
        XCTAssertEqual(AppLanguage.en.rawValue,     "en")
        XCTAssertEqual(AppLanguage.ja.rawValue,     "ja")
        XCTAssertEqual(AppLanguage.ko.rawValue,     "ko")
    }

    func test_init_unknown_returns_nil() {
        XCTAssertNil(AppLanguage(rawValue: "garbage"))
        XCTAssertNil(AppLanguage(rawValue: ""))
    }

    /// 语言名用各自的写法，不随界面语言变。
    func test_endonymLabels() {
        XCTAssertEqual(AppLanguage.zhHans.localizedLabel, "简体中文")
        XCTAssertEqual(AppLanguage.zhHant.localizedLabel, "繁體中文")
        XCTAssertEqual(AppLanguage.en.localizedLabel,     "English")
        XCTAssertEqual(AppLanguage.ja.localizedLabel,     "日本語")
        XCTAssertEqual(AppLanguage.ko.localizedLabel,     "한국어")
        XCTAssertFalse(AppLanguage.system.localizedLabel.isEmpty)
    }

    func test_locale_mapping() {
        XCTAssertNil(AppLanguage.system.locale)
        XCTAssertEqual(AppLanguage.zhHans.locale, Locale(identifier: "zh-Hans"))
        XCTAssertEqual(AppLanguage.ja.locale,     Locale(identifier: "ja"))
    }

    func test_id_equals_rawValue() {
        XCTAssertEqual(AppLanguage.system.id, "system")
        XCTAssertEqual(AppLanguage.zhHans.id, "zh-Hans")
    }

    func test_applyToBundleLocalization_writesAndClearsAppleLanguages() throws {
        let suite = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        AppLanguage.ja.applyToBundleLocalization(defaults: defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?[DefaultsKey.appleLanguages] as? [String], ["ja"])

        AppLanguage.system.applyToBundleLocalization(defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?[DefaultsKey.appleLanguages])
    }

    func test_applyStoredPreference_followsStoredChoice() throws {
        let suite = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("ko", forKey: DefaultsKey.appLanguage)
        AppLanguage.applyStoredPreference(defaults: defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?[DefaultsKey.appleLanguages] as? [String], ["ko"])

        defaults.set("garbage", forKey: DefaultsKey.appLanguage)
        AppLanguage.applyStoredPreference(defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?[DefaultsKey.appleLanguages])
    }
}
