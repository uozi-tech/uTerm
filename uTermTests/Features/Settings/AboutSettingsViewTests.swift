import XCTest
@testable import uTerm

@MainActor
final class AboutSettingsViewTests: XCTestCase {
    // ── versionString ────────────────────────────────────────────
    func test_version_full() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "503",
        ]
        XCTAssertEqual(AboutSettingsView.versionString(from: info), "v1.0 (503)")
    }

    func test_version_missing_both_fields_no_fallback() {
        XCTAssertEqual(AboutSettingsView.versionString(from: [:]), "v ()")
        XCTAssertEqual(AboutSettingsView.versionString(from: nil), "v ()")
    }

    func test_version_only_short_missing() {
        let info: [String: Any] = ["CFBundleVersion": "503"]
        XCTAssertEqual(AboutSettingsView.versionString(from: info), "v (503)")
    }

    func test_version_only_build_missing() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0"]
        XCTAssertEqual(AboutSettingsView.versionString(from: info), "v1.0 ()")
    }

    // ── copyrightString ──────────────────────────────────────────
    func test_copyright_uses_provided_year() throws {
        var components = DateComponents()
        components.year = 2030
        components.month = 6
        components.day = 1
        let date = try XCTUnwrap(Calendar.current.date(from: components))
        XCTAssertEqual(
            AboutSettingsView.copyrightString(now: date),
            "© 2030 柚子星云科技（深圳）有限公司"
        )
    }

    func test_copyright_uses_current_year_by_default() {
        let currentYear = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(
            AboutSettingsView.copyrightString,
            "© \(currentYear) 柚子星云科技（深圳）有限公司"
        )
    }
}
