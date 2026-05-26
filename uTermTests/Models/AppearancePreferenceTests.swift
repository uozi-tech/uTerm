import XCTest
import SwiftUI
@testable import uTerm

final class AppearancePreferenceTests: XCTestCase {
    func test_allCases_order() {
        XCTAssertEqual(AppearancePreference.allCases, [.light, .dark, .system])
    }

    func test_rawValues() {
        XCTAssertEqual(AppearancePreference.light.rawValue,  "light")
        XCTAssertEqual(AppearancePreference.dark.rawValue,   "dark")
        XCTAssertEqual(AppearancePreference.system.rawValue, "system")
    }

    func test_init_unknown_returns_nil() {
        XCTAssertNil(AppearancePreference(rawValue: "garbage"))
        XCTAssertNil(AppearancePreference(rawValue: ""))
    }

    func test_localizedLabels() {
        XCTAssertEqual(AppearancePreference.light.localizedLabel,  "浅色")
        XCTAssertEqual(AppearancePreference.dark.localizedLabel,   "深色")
        XCTAssertEqual(AppearancePreference.system.localizedLabel, "跟随系统")
    }

    func test_colorScheme_mapping() {
        XCTAssertEqual(AppearancePreference.light.colorScheme,  .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme,   .dark)
        XCTAssertNil(AppearancePreference.system.colorScheme)
    }

    func test_id_equals_rawValue() {
        XCTAssertEqual(AppearancePreference.light.id,  "light")
        XCTAssertEqual(AppearancePreference.system.id, "system")
    }
}
