import XCTest
@testable import uTerm

@MainActor
final class PaneModelTests: XCTestCase {
    func testHoldsTerminalSession() {
        let server = UUID()
        let pane = PaneModel(serverProfileID: server)
        XCTAssertEqual(pane.serverProfileID, server)
        // session 是终端独占的不可变属性，单元测试只验证它存在。
        XCTAssertNotNil(pane.session)
    }
}
