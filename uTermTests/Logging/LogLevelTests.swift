import XCTest
@testable import uTerm

final class LogLevelTests: XCTestCase {
    func test_allCases_order() {
        XCTAssertEqual(LogLevel.allCases, [.error, .warn, .info, .debug])
    }

    func test_priority_ascending() {
        XCTAssertLessThan(LogLevel.error.priority, LogLevel.warn.priority)
        XCTAssertLessThan(LogLevel.warn.priority,  LogLevel.info.priority)
        XCTAssertLessThan(LogLevel.info.priority,  LogLevel.debug.priority)
    }

    func test_priority_values() {
        XCTAssertEqual(LogLevel.error.priority, 0)
        XCTAssertEqual(LogLevel.warn.priority,  1)
        XCTAssertEqual(LogLevel.info.priority,  2)
        XCTAssertEqual(LogLevel.debug.priority, 3)
    }

    func test_rawValues() {
        XCTAssertEqual(LogLevel.error.rawValue, "error")
        XCTAssertEqual(LogLevel.warn.rawValue,  "warn")
        XCTAssertEqual(LogLevel.info.rawValue,  "info")
        XCTAssertEqual(LogLevel.debug.rawValue, "debug")
    }

    func test_init_unknown_returns_nil() {
        XCTAssertNil(LogLevel(rawValue: "trace"))
        XCTAssertNil(LogLevel(rawValue: ""))
    }

    func test_localizedLabels() {
        XCTAssertEqual(LogLevel.error.localizedLabel, "Error")
        XCTAssertEqual(LogLevel.warn.localizedLabel,  "Warn")
        XCTAssertEqual(LogLevel.info.localizedLabel,  "Info")
        XCTAssertEqual(LogLevel.debug.localizedLabel, "Debug")
    }
}
