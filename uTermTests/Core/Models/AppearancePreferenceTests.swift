import XCTest
import SwiftUI
import AppKit
@testable import uTerm

@MainActor
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

    /// `nsAppearance` 是真正被 app 应用的映射（写到 `NSApp.appearance`）。
    /// `.system` → nil（跟随系统）；这是修复"切到跟随系统不 live-update"的核心。
    func test_nsAppearance_mapping() {
        XCTAssertEqual(AppearancePreference.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearancePreference.dark.nsAppearance?.name,  .darkAqua)
        XCTAssertNil(AppearancePreference.system.nsAppearance)
    }

    func test_id_equals_rawValue() {
        XCTAssertEqual(AppearancePreference.light.id,  "light")
        XCTAssertEqual(AppearancePreference.system.id, "system")
    }
}
