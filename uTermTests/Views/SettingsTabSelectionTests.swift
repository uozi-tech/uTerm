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
    }
}
