import XCTest

final class AssistantCommandReturnShortcutTests: XCTestCase {
    func testAssistantRegistersCommandReturnAndRoutesPendingApprovalFirst() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Agent/Views/AssistantView.swift"),
                                encoding: .utf8)

        XCTAssertTrue(
            source.contains(".keyboardShortcut(.return, modifiers: .command)"),
            "The workspace assistant must register the Command-Return shortcut it advertises.")
        XCTAssertTrue(
            source.contains("model.state == .awaitingApproval"),
            "Command-Return must prioritize a pending tool approval.")
        XCTAssertTrue(
            source.contains("model.approveAndRun(id: id)"),
            "Command-Return must execute the pending tool through the model state machine.")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
