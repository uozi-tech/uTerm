import XCTest
@testable import uTerm

@MainActor
final class PaneDragStateTests: XCTestCase {
    func testBeginSetsDraggingPaneID() {
        let state = PaneDragState()
        let pane = UUID()
        state.begin(paneID: pane)
        XCTAssertEqual(state.draggingPaneID, pane)
        state.end()
    }

    func testBeginClearsPriorHover() {
        let state = PaneDragState()
        state.hover = DragHoverTarget(paneID: UUID(), zone: .top)
        state.begin(paneID: UUID())
        XCTAssertNil(state.hover)
        state.end()
    }

    func testEndClearsAllState() {
        let state = PaneDragState()
        state.begin(paneID: UUID())
        state.hover = DragHoverTarget(paneID: UUID(), zone: .center)
        state.end()
        XCTAssertNil(state.draggingPaneID)
        XCTAssertNil(state.hover)
    }
}
