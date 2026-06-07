import XCTest
@testable import uTerm

@MainActor
final class StartupBehaviorTests: XCTestCase {
    func test_allCases_order_and_count() {
        XCTAssertEqual(StartupBehavior.allCases, [.welcome, .restore, .lastHost])
    }

    func test_rawValues() {
        XCTAssertEqual(StartupBehavior.welcome.rawValue,  "welcome")
        XCTAssertEqual(StartupBehavior.restore.rawValue,  "restore")
        XCTAssertEqual(StartupBehavior.lastHost.rawValue, "last-host")
    }

    func test_init_from_unknown_raw_returns_nil() {
        XCTAssertNil(StartupBehavior(rawValue: "garbage"))
        XCTAssertNil(StartupBehavior(rawValue: ""))
    }

    func test_init_from_known_rawValues() {
        XCTAssertEqual(StartupBehavior(rawValue: "welcome"),   .welcome)
        XCTAssertEqual(StartupBehavior(rawValue: "restore"),   .restore)
        XCTAssertEqual(StartupBehavior(rawValue: "last-host"), .lastHost)
    }

    func test_localizedLabels() {
        XCTAssertEqual(StartupBehavior.welcome.localizedLabel,  "欢迎页")
        XCTAssertEqual(StartupBehavior.restore.localizedLabel,  "上次会话")
        XCTAssertEqual(StartupBehavior.lastHost.localizedLabel, "上次主机")
    }

    func test_id_equals_rawValue() {
        XCTAssertEqual(StartupBehavior.welcome.id,  "welcome")
        XCTAssertEqual(StartupBehavior.lastHost.id, "last-host")
    }
}
