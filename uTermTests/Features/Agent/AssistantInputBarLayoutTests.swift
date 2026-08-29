import XCTest
import UDesignKit
@testable import uTerm

final class AssistantInputBarLayoutTests: XCTestCase {
    func testAttachButtonUsesClickableHitTarget() {
        XCTAssertGreaterThanOrEqual(AssistantInputBarLayout.attachHitSize, 28)
        XCTAssertGreaterThanOrEqual(AssistantInputBarLayout.attachIconSize, 11)
    }

    func testSendButtonUsesFixedCenteredHeight() {
        XCTAssertGreaterThanOrEqual(AssistantInputBarLayout.sendButtonHeight, 24)
        XCTAssertLessThanOrEqual(AssistantInputBarLayout.keycapHeight,
                                 AssistantInputBarLayout.sendButtonHeight)
        XCTAssertEqual(AssistantInputBarLayout.sendContentAlignment, .center)
    }

    func testComposerUsesEqualEdgePadding() {
        XCTAssertEqual(UDComposerLayout.contentPadding, UD.Space.lg)
    }

    func testComposerRoutesReturnKeyToSendAction() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testsURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("uTerm/DesignKit/Comms/UDComposer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let handlesReturn = source.contains(".onSubmit")
            || source.contains(".onKeyPress(.return)")
            || source.contains(".keyboardShortcut(.return")
        XCTAssertTrue(handlesReturn,
                      "UDComposer must route Return to the send action instead of leaving focus on the send button.")
    }
}
