import XCTest
@testable import uTerm

final class SettingsTabSelectionTests: XCTestCase {
    func test_key_is_stable_for_menu_and_settings_view() {
        XCTAssertEqual(SettingsTabSelection.key, "settingsTabSelection")
    }

    func test_about_menu_target_selects_about_tab() {
        XCTAssertEqual(SettingsTabSelection.aboutMenuTarget, SettingsTab.about.rawValue)
        XCTAssertEqual(SettingsTabSelection.tab(from: SettingsTabSelection.aboutMenuTarget), .about)
    }

    func test_invalid_stored_tab_falls_back_to_general() {
        XCTAssertEqual(SettingsTabSelection.tab(from: "missing"), .general)
        XCTAssertEqual(SettingsTabSelection.tab(from: nil), .general)
        XCTAssertEqual(SettingsTabSelection.tab(from: ""), .general)
    }

    /// 「高级」拆成了 连接 / 同步 / 诊断：旧版本记住的 "advanced" 落到「连接」。
    func test_legacy_advanced_maps_to_connection() {
        XCTAssertEqual(SettingsTabSelection.tab(from: "advanced"), .connection)
    }

    /// 旧版本写过的其余 rawValue 原样可解析（这些值存在用户偏好里）。
    func test_legacy_raw_values_still_parse() {
        let legacy: [(String, SettingsSection)] = [
            ("general", .general), ("providers", .providers), ("terminal", .terminal),
            ("remote", .remote), ("cli", .cli), ("about", .about),
        ]
        for (raw, section) in legacy {
            XCTAssertEqual(SettingsTabSelection.tab(from: raw), section, raw)
        }
    }

    func test_every_section_round_trips() {
        for section in SettingsSection.allCases {
            XCTAssertEqual(SettingsTabSelection.tab(from: section.rawValue), section)
        }
    }
}
