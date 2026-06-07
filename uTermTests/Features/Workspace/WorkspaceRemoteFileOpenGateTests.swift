import XCTest
@testable import uTerm

final class WorkspaceRemoteFileOpenGateTests: XCTestCase {
    func testSmallFileOpensDirectly() {
        XCTAssertEqual(WorkspaceRemoteFileOpenGate.decision(forSize: 5 * 1024 * 1024), .openDirectly)
    }

    func testFileOverFiveMegabytesRequiresConfirmation() {
        XCTAssertEqual(WorkspaceRemoteFileOpenGate.decision(forSize: 5 * 1024 * 1024 + 1), .confirmLargeFile)
    }

    func testFileOverFiftyMegabytesIsBlocked() {
        XCTAssertEqual(WorkspaceRemoteFileOpenGate.decision(forSize: 50 * 1024 * 1024 + 1), .block)
    }
}
