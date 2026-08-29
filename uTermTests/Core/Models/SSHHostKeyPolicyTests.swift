import XCTest
@testable import uTerm

// USSHKit 也有个 public 的同名类型；本文件只 import uTerm，typealias 明确钉住 app 侧的那个，
// 免得日后谁补上 `@testable import USSHKit` 就变歧义。
private typealias SSHHostKeyPolicy = uTerm.SSHHostKeyPolicy

@MainActor
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
