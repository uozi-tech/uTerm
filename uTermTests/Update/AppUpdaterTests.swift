import XCTest
@testable import uTerm

final class AppUpdaterTests: XCTestCase {
    func test_currentVersionString_full() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "503",
        ]
        XCTAssertEqual(AppUpdater.currentVersionString(from: info), "v1.0 (503)")
    }

    func test_currentVersionString_missing_falls_back_empty() {
        XCTAssertEqual(AppUpdater.currentVersionString(from: [:]), "v ()")
        XCTAssertEqual(AppUpdater.currentVersionString(from: nil), "v ()")
    }

    func test_currentVersionString_only_short() {
        let info: [String: Any] = ["CFBundleShortVersionString": "2.0"]
        XCTAssertEqual(AppUpdater.currentVersionString(from: info), "v2.0 ()")
    }

    func test_currentVersionString_only_build() {
        let info: [String: Any] = ["CFBundleVersion": "503"]
        XCTAssertEqual(AppUpdater.currentVersionString(from: info), "v (503)")
    }
}
