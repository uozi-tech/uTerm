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
        // UDComposer 已随 DesignKit 收编进共享包；Xcode 以本地包引用
        // `../uTable/Packages/UDesignKit` 挂它，源码守卫按同一相对路径找过去。
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Agent
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // uTermTests
            .deletingLastPathComponent()   // <uTerm repo root>
        let sourceURL = repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent("uTable/Packages/UDesignKit/Sources/UDesignKit/Comms/UDComposer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let handlesReturn = source.contains(".onSubmit")
            || source.contains(".onKeyPress(.return)")
            || source.contains(".keyboardShortcut(.return")
        XCTAssertTrue(handlesReturn,
                      "UDComposer must route Return to the send action instead of leaving focus on the send button.")
    }
}
