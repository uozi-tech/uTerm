import XCTest
@testable import uTerm

final class SSHHostKeyPolicyTests: XCTestCase {
    func test_allCases_order() {
        XCTAssertEqual(SSHHostKeyPolicy.allCases, [.strict, .ask, .none])
    }

    func test_rawValues() {
        XCTAssertEqual(SSHHostKeyPolicy.strict.rawValue, "strict")
        XCTAssertEqual(SSHHostKeyPolicy.ask.rawValue,    "ask")
        XCTAssertEqual(SSHHostKeyPolicy.none.rawValue,   "none")
    }

    func test_init_unknown_returns_nil() {
        XCTAssertNil(SSHHostKeyPolicy(rawValue: "garbage"))
        XCTAssertNil(SSHHostKeyPolicy(rawValue: ""))
    }

    func test_localizedLabels() {
        XCTAssertEqual(SSHHostKeyPolicy.strict.localizedLabel, "严格")
        XCTAssertEqual(SSHHostKeyPolicy.ask.localizedLabel,    "询问")
        XCTAssertEqual(SSHHostKeyPolicy.none.localizedLabel,   "忽略")
    }

    func test_id_equals_rawValue() {
        XCTAssertEqual(SSHHostKeyPolicy.strict.id, "strict")
    }
}
