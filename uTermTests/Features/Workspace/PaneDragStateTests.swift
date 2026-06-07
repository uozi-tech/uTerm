import XCTest
@testable import uTerm

@MainActor
final class PaneDragStateTests: XCTestCase {
    private func preview() -> PaneDragPreview {
        PaneDragPreview(name: "web", paneSize: CGSize(width: 200, height: 120),
                        grabOffset: CGSize(width: 10, height: 5))
    }

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

    func testBeginWithPreviewStoresIt() {
        let state = PaneDragState()
        let p = preview()
        state.begin(paneID: UUID(), preview: p)
        XCTAssertEqual(state.paneDragPreview, p)
        state.end()
    }

    func testBeginWithoutPreviewLeavesNilPreview() {
        let state = PaneDragState()
        state.begin(paneID: UUID())
        XCTAssertNil(state.paneDragPreview)
        state.end()
    }

    func testEndClearsAllState() {
        let state = PaneDragState()
        state.begin(paneID: UUID(), preview: preview())
        state.hover = DragHoverTarget(paneID: UUID(), zone: .center)
        state.end()
        XCTAssertNil(state.draggingPaneID)
        XCTAssertNil(state.hover)
        XCTAssertNil(state.paneDragPreview)
    }

    func testDropHighlightRequiresActiveDrag() {
        let pane = UUID()
        let hover = DragHoverTarget(paneID: pane, zone: .trailing)

        XCTAssertNil(paneDropHighlightZone(
            paneID: pane,
            draggingPaneID: nil,
            workspaceDragSource: nil,
            hover: hover))

        XCTAssertEqual(paneDropHighlightZone(
            paneID: pane,
            draggingPaneID: nil,
            workspaceDragSource: .tab(UUID()),
            hover: hover), .trailing)
    }
}
