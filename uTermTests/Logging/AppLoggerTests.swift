import XCTest
@testable import uTerm

final class AppLoggerTests: XCTestCase {
    func test_shouldLog_default_info_passes_error_warn_info() {
        // currentSetting nil → 默认 .info → priority 2
        XCTAssertTrue(AppLogger.shouldLog(.error, currentSetting: nil))
        XCTAssertTrue(AppLogger.shouldLog(.warn,  currentSetting: nil))
        XCTAssertTrue(AppLogger.shouldLog(.info,  currentSetting: nil))
        XCTAssertFalse(AppLogger.shouldLog(.debug, currentSetting: nil))
    }

    func test_shouldLog_error_only_blocks_higher_levels() {
        let setting = LogLevel.error.rawValue
        XCTAssertTrue(AppLogger.shouldLog(.error,  currentSetting: setting))
        XCTAssertFalse(AppLogger.shouldLog(.warn,  currentSetting: setting))
        XCTAssertFalse(AppLogger.shouldLog(.info,  currentSetting: setting))
        XCTAssertFalse(AppLogger.shouldLog(.debug, currentSetting: setting))
    }

    func test_shouldLog_debug_passes_all() {
        let setting = LogLevel.debug.rawValue
        for call in LogLevel.allCases {
            XCTAssertTrue(AppLogger.shouldLog(call, currentSetting: setting),
                          "level \(call.rawValue) should pass when setting is debug")
        }
    }

    func test_shouldLog_warn_passes_error_and_warn_only() {
        let setting = LogLevel.warn.rawValue
        XCTAssertTrue(AppLogger.shouldLog(.error,  currentSetting: setting))
        XCTAssertTrue(AppLogger.shouldLog(.warn,   currentSetting: setting))
        XCTAssertFalse(AppLogger.shouldLog(.info,  currentSetting: setting))
        XCTAssertFalse(AppLogger.shouldLog(.debug, currentSetting: setting))
    }

    func test_shouldLog_corrupt_setting_falls_back_to_info() {
        // garbage rawValue → LogLevel(rawValue:) returns nil → fallback to .info
        XCTAssertTrue(AppLogger.shouldLog(.info,   currentSetting: "garbage"))
        XCTAssertFalse(AppLogger.shouldLog(.debug, currentSetting: "garbage"))
    }
}
