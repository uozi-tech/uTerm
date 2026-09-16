import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 中央上下分栏的高度规则。回归背景：以前只按比例 clamp（0.15…0.85），把终端区
/// 拖到顶后预览区装不下「标签条 + 空态 + 状态条」，组外壳整体居中溢出，标签条被
/// 顶出窗口顶部。
final class WorkspaceCenterLayoutTests: XCTestCase {

    /// 720pt 最小窗高去掉底部状态栏后的中央列高度。
    private let minWindowCenter: CGFloat = 697

    func test_topHeight_squeezedRatio_keepsPreviewMinimum() {
        // 旧下限 0.15 × 697 ≈ 105pt —— 就是截图里出事的高度。
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: minWindowCenter, ratio: 0.15),
                       WorkspaceCenterLayout.minPreviewHeight)
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: minWindowCenter, ratio: 0),
                       WorkspaceCenterLayout.minPreviewHeight)
    }

    func test_topHeight_expandedRatio_keepsTerminalMinimum() {
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: minWindowCenter, ratio: 0.9),
                       minWindowCenter - WorkspaceCenterLayout.minTerminalHeight)
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: minWindowCenter, ratio: 1),
                       minWindowCenter - WorkspaceCenterLayout.minTerminalHeight)
    }

    func test_topHeight_ratioInsideBounds_passesThrough() {
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: 1000, ratio: 0.5), 500, accuracy: 0.001)
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: 1000, ratio: 0.667), 667, accuracy: 0.001)
    }

    func test_topHeight_tooShortForBothMinimums_splitsEvenly() {
        let total: CGFloat = 200   // < 140 + 140
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: total, ratio: 0.1), 100, accuracy: 0.001)
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: total, ratio: 0.9), 100, accuracy: 0.001)
    }

    func test_topHeight_zeroTotal_isZero() {
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: 0, ratio: 0.667), 0)
    }

    func test_fractionBounds_matchHeightClamp() {
        let bounds = WorkspaceCenterLayout.fractionBounds(total: minWindowCenter)
        XCTAssertEqual(bounds.lowerBound * Double(minWindowCenter),
                       Double(WorkspaceCenterLayout.minPreviewHeight), accuracy: 0.001)
        XCTAssertEqual((1 - bounds.upperBound) * Double(minWindowCenter),
                       Double(WorkspaceCenterLayout.minTerminalHeight), accuracy: 0.001)
        // 拖动条拖到任一端，换算回来的高度与布局 clamp 的结果一致，手柄不会与分界错位。
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: minWindowCenter, ratio: bounds.lowerBound),
                       WorkspaceCenterLayout.minPreviewHeight, accuracy: 0.001)
        XCTAssertEqual(WorkspaceCenterLayout.topHeight(total: minWindowCenter, ratio: bounds.upperBound),
                       minWindowCenter - WorkspaceCenterLayout.minTerminalHeight, accuracy: 0.001)
    }

    func test_fractionBounds_neverInverted() {
        for total in stride(from: CGFloat(1), through: 2000, by: 37) {
            let bounds = WorkspaceCenterLayout.fractionBounds(total: total)
            XCTAssertLessThanOrEqual(bounds.lowerBound, bounds.upperBound, "total=\(total)")
        }
    }

    /// 预览区空态必须肯被压扁：给的高度小于内容时仍按给的高度定尺寸（溢出部分裁掉），
    /// 不能按内容高度撑出去 —— 后者正是把组标签条顶出窗口的那条链路的起点。
    @MainActor
    func test_previewEmptyBody_acceptsHeightBelowItsContent() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uTermTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RecentFilesStore(rootDirectory: tmp, fileName: "r.json")
        let model = FilePreviewModel(recentsStore: store, sftpProvider: { MockSFTP() })
        let host = NSHostingController(rootView: EmptyBody(model: model))

        for height: CGFloat in [20, 60, 100] {
            let size = host.sizeThatFits(in: CGSize(width: 600, height: height))
            XCTAssertLessThanOrEqual(size.height, height + 0.5, "proposed height \(height)")
        }
    }
}
