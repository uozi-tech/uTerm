import XCTest
@testable import uTerm

@MainActor
final class PaneModelTests: XCTestCase {
    func testTerminalKindHoldsTerminalSession() {
        let pane = PaneModel(serverProfileID: UUID(), kind: .terminal)
        guard case .terminal = pane.kind else {
            return XCTFail("应为 .terminal")
        }
        XCTAssertEqual(pane.kind.tag, .terminal)
    }

    func testFilesKindHoldsFileBrowserModel() {
        let pane = PaneModel(serverProfileID: UUID(), kind: .files)
        guard case .files = pane.kind else {
            return XCTFail("应为 .files")
        }
        XCTAssertEqual(pane.kind.tag, .files)
    }
}
