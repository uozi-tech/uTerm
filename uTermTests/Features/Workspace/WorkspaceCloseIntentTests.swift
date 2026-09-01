import XCTest
import AppKit
@testable import uTerm

@MainActor
final class WorkspaceCloseIntentTests: XCTestCase {

    private func ctx(_ r: FocusRegion, file: UUID? = nil, tab: UUID? = nil) -> CloseContext {
        CloseContext(focusedRegion: r, activeFileBufferID: file, activeTerminalTabID: tab)
    }

    func test_preview_withBuffer_closesThatBuffer() {
        let f = UUID()
        XCTAssertEqual(resolveCloseIntent(ctx(.preview, file: f, tab: UUID())), .closeFileBuffer(f))
    }

    func test_preview_noBuffer_fallsBackToTerminal() {
        let t = UUID()
        XCTAssertEqual(resolveCloseIntent(ctx(.preview, file: nil, tab: t)), .closeTerminalActiveTab(tabID: t))
    }

    func test_preview_nothing_closesWindow() {
        XCTAssertEqual(resolveCloseIntent(ctx(.preview)), .closeWindow)
    }

    func test_terminal_withTab_closesThatPane() {
        let t = UUID()
        XCTAssertEqual(resolveCloseIntent(ctx(.terminal, file: UUID(), tab: t)), .closeTerminalActiveTab(tabID: t))
    }

    func test_terminal_noTab_fallsBackToFile() {
        let f = UUID()
        XCTAssertEqual(resolveCloseIntent(ctx(.terminal, file: f, tab: nil)), .closeFileBuffer(f))
    }

    func test_unknown_bothPresent_prefersFile() {
        let f = UUID(); let t = UUID()
        XCTAssertEqual(resolveCloseIntent(ctx(.unknown, file: f, tab: t)), .closeFileBuffer(f))
    }

    func test_unknown_onlyTerminal_closesTerminal() {
        let t = UUID()
        XCTAssertEqual(resolveCloseIntent(ctx(.unknown, file: nil, tab: t)), .closeTerminalActiveTab(tabID: t))
    }

    func test_unknown_nothing_closesWindow() {
        XCTAssertEqual(resolveCloseIntent(ctx(.unknown)), .closeWindow)
    }

    // MARK: focusRegion(forFirstResponder:)

    func test_focusRegion_terminalTagged() {
        let v = NSView()
        v.identifier = .utermTerminalRegion
        XCTAssertEqual(WorkspaceCloseShortcut.focusRegion(forFirstResponder: v), .terminal)
    }

    func test_focusRegion_previewAncestorTagged() {
        let parent = NSView()
        parent.identifier = .utermPreviewRegion
        let child = NSView()
        parent.addSubview(child)
        XCTAssertEqual(WorkspaceCloseShortcut.focusRegion(forFirstResponder: child), .preview)
    }

    func test_focusRegion_untagged_isUnknown() {
        let parent = NSView()
        let child = NSView()
        parent.addSubview(child)
        XCTAssertEqual(WorkspaceCloseShortcut.focusRegion(forFirstResponder: child), .unknown)
    }

    func test_focusRegion_nil_isUnknown() {
        XCTAssertEqual(WorkspaceCloseShortcut.focusRegion(forFirstResponder: nil), .unknown)
    }
}
