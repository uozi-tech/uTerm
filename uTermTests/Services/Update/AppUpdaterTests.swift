import XCTest
@testable import uTerm

@MainActor
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

    /// 更新源与公钥都配了才启动 Sparkle；公开构建两项都是空的。
    func test_isConfigured_needs_feed_and_key() {
        let feed = "https://dl.example.com/uTerm/appcast.xml"
        XCTAssertTrue(AppUpdater.isConfigured(["SUFeedURL": feed, "SUPublicEDKey": "abc="]))
        XCTAssertFalse(AppUpdater.isConfigured(nil))
        XCTAssertFalse(AppUpdater.isConfigured(["SUFeedURL": "", "SUPublicEDKey": ""]))
        XCTAssertFalse(AppUpdater.isConfigured(["SUFeedURL": feed]))
        XCTAssertFalse(AppUpdater.isConfigured(["SUFeedURL": feed, "SUPublicEDKey": "  "]))
        XCTAssertFalse(AppUpdater.isConfigured(["SUFeedURL": "$(UTERM_SU_FEED_URL)", "SUPublicEDKey": "abc="]))
        XCTAssertFalse(AppUpdater.isConfigured(["SUFeedURL": "http://dl.example.com/appcast.xml", "SUPublicEDKey": "abc="]),
                       "Sparkle 只接受 https 的更新源")
    }
}
