import XCTest
import SwiftTerm
@testable import uTerm

@MainActor
final class TerminalContainerViewTests: XCTestCase {

    /// SwiftUI can defer a `TerminalHostView`'s `dismantleNSView` until *after*
    /// the next host view has already re-adopted the shared terminal view
    /// (tab switch away-and-back). The stale container must not rip the live
    /// terminal view out of the new container — doing so orphans the view and
    /// the pane renders black.
    func testStaleContainerDetachDoesNotStealTerminalFromNewContainer() {
        let terminalView = CopyableTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let staleContainer = TerminalContainerView(terminalView: terminalView)
        XCTAssertTrue(terminalView.superview === staleContainer)

        // The new container re-adopts the same shared terminal view.
        let liveContainer = TerminalContainerView(terminalView: terminalView)
        XCTAssertTrue(terminalView.superview === liveContainer)

        // The stale container's deferred dismantle runs now.
        staleContainer.detachTerminal()

        // The terminal view must still belong to the live container.
        XCTAssertTrue(terminalView.superview === liveContainer)
    }

    /// When the terminal view is still parented to this container, detaching
    /// must unparent it as before.
    func testDetachUnparentsTerminalStillOwnedByThisContainer() {
        let terminalView = CopyableTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let container = TerminalContainerView(terminalView: terminalView)
        XCTAssertTrue(terminalView.superview === container)

        container.detachTerminal()

        XCTAssertNil(terminalView.superview)
    }
}
