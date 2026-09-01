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

    // `testComposerRoutesReturnKeyToSendAction` 已迁往 uAppKit 的 UDesignKitTests：
    // 它守的是 UDComposer 的源文本，而 UDesignKit 已收编进共享包、按 tag 取用，
    // 从 uTerm 按相对路径去兄弟目录找源码既找不到、也重新引入了刚拆掉的耦合。
}
