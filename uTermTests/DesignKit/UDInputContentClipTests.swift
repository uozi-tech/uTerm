import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// `UDTextField` 把文本裁到内容框，挡住 AppKit text field / field editor 比 SwiftUI
/// 内容框宽出来的那 2 ~ 4.5pt —— 长密码聚焦滚动时首字会画进内边距、糊到圆角描边上。
final class UDInputContentClipTests: XCTestCase {
    private let fieldRect = CGRect(x: 0, y: 0, width: 200, height: 34)

    /// 内容框语义：内缩一个水平内边距，正好落在文本槽位的左右边界上。
    func testClipMatchesContentBoxHorizontally() {
        let clip = UDInputContentClip(horizontalInset: UDTextField.horizontalPadding)
            .path(in: fieldRect).boundingRect

        XCTAssertEqual(clip.minX, UDTextField.horizontalPadding, accuracy: 0.001)
        XCTAssertEqual(clip.maxX, fieldRect.maxX - UDTextField.horizontalPadding, accuracy: 0.001)
    }

    /// 纵向不能裁：裁剪盒一旦收到单行文字高，CJK / emoji 的字形就会被削。
    func testClipKeepsFullFieldHeight() {
        let clip = UDInputContentClip(horizontalInset: UDTextField.horizontalPadding)
            .path(in: fieldRect).boundingRect

        XCTAssertEqual(clip.minY, fieldRect.minY, accuracy: 0.001)
        XCTAssertEqual(clip.height, fieldRect.height, accuracy: 0.001)
    }

    func testHorizontalPaddingIsPositiveSoTextNeverTouchesTheBorder() {
        XCTAssertGreaterThan(UDTextField.horizontalPadding, 0)
    }

    /// `UDSearchField` 把裁剪套在只有一行文字高的槽位上，靠 `verticalOutset` 撑到整行控件高。
    func testVerticalOutsetGrowsTheClipBoxWithoutMovingItHorizontally() {
        let slot = CGRect(x: 0, y: 0, width: 200, height: 16)
        let clip = UDInputContentClip(horizontalInset: 0, verticalOutset: 16)
            .path(in: slot).boundingRect

        XCTAssertEqual(clip.minX, slot.minX, accuracy: 0.001)
        XCTAssertEqual(clip.maxX, slot.maxX, accuracy: 0.001)
        XCTAssertEqual(clip.minY, slot.minY - 16, accuracy: 0.001)
        XCTAssertEqual(clip.height, slot.height + 32, accuracy: 0.001)
    }

    /// `UDTextField` 的密码框尾部要放显隐钮，裁剪改套在字段槽位上（横向不再内缩），
    /// 靠 `verticalOutset` 半个控件高把裁剪盒撑回整行 —— 34 高的控件用 17。
    func testVerticalOutsetOfHalfControlHeightCoversTheWholeRow() {
        let slot = CGRect(x: 0, y: 0, width: 200, height: 16)
        let clip = UDInputContentClip(horizontalInset: 0, verticalOutset: 17)
            .path(in: slot).boundingRect

        XCTAssertGreaterThanOrEqual(clip.height, fieldRect.height)
        XCTAssertEqual(clip.midY, slot.midY, accuracy: 0.001)
    }

    /// 默认不外扩。
    func testVerticalOutsetDefaultsToZero() {
        let clip = UDInputContentClip(horizontalInset: 0).path(in: fieldRect).boundingRect

        XCTAssertEqual(clip, fieldRect)
    }
}
