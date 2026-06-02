import XCTest
@testable import uTerm

@MainActor
final class AppLanguageTests: XCTestCase {
    func test_allCases_order() {
        XCTAssertEqual(AppLanguage.allCases, [.system, .zhHans, .en])
    }

    func test_rawValues() {
        XCTAssertEqual(AppLanguage.system.rawValue, "system")
        XCTAssertEqual(AppLanguage.zhHans.rawValue, "zh-Hans")
        XCTAssertEqual(AppLanguage.en.rawValue,     "en")
    }

    func test_init_unknown_returns_nil() {
        XCTAssertNil(AppLanguage(rawValue: "garbage"))
        XCTAssertNil(AppLanguage(rawValue: ""))
    }

    func test_localizedLabels() {
        XCTAssertEqual(AppLanguage.system.localizedLabel, "跟随系统")
        XCTAssertEqual(AppLanguage.zhHans.localizedLabel, "简体中文")
        XCTAssertEqual(AppLanguage.en.localizedLabel,     "English")
    }

    func test_locale_mapping() {
        XCTAssertNil(AppLanguage.system.locale)
        XCTAssertEqual(AppLanguage.zhHans.locale, Locale(identifier: "zh-Hans"))
        XCTAssertEqual(AppLanguage.en.locale,     Locale(identifier: "en"))
    }

    func test_id_equals_rawValue() {
        XCTAssertEqual(AppLanguage.system.id, "system")
        XCTAssertEqual(AppLanguage.zhHans.id, "zh-Hans")
    }
}
