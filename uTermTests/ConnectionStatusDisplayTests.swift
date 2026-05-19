import XCTest
@testable import uTerm

final class ConnectionStatusDisplayTests: XCTestCase {
    func testIdle() {
        let d = ConnectionStatusDisplay(state: .idle)
        XCTAssertEqual(d.tint, .neutral)
        XCTAssertEqual(d.label, "未连接")
    }
    func testConnecting() {
        let d = ConnectionStatusDisplay(state: .connecting)
        XCTAssertEqual(d.tint, .warning)
        XCTAssertEqual(d.label, "连接中")
    }
    func testConnected() {
        let d = ConnectionStatusDisplay(state: .connected)
        XCTAssertEqual(d.tint, .success)
        XCTAssertEqual(d.label, "已连接")
    }
    func testDisconnected() {
        let d = ConnectionStatusDisplay(state: .disconnected)
        XCTAssertEqual(d.tint, .caution)
        XCTAssertEqual(d.label, "已断开")
    }
    func testFailed() {
        let d = ConnectionStatusDisplay(state: .failed("boom"))
        XCTAssertEqual(d.tint, .error)
        XCTAssertEqual(d.label, "连接失败")
    }
}
