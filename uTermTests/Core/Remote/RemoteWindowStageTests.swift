import CoreGraphics
import XCTest
@testable import uTerm

/// 窗口模式下屏幕放不下主控端要的窗口大小时用的虚拟屏（`RemoteWindowStage`）：什么时候用、建多大。
/// 真的建屏、挪窗口要在装好的包上手动验（要窗口服务和辅助功能授权）。
final class RemoteWindowStageTests: XCTestCase {
    func test_stage_is_needed_only_when_the_screen_cannot_hold_the_window() {
        // 14 寸内建屏去掉菜单栏和程序坞大约 1512×900 点。
        let builtin = CGSize(width: 1512, height: 900)
        XCTAssertTrue(RemoteWindowStage.needsStage(fit: CGSize(width: 1426, height: 1003), visible: builtin), "横握「最清晰」：高度放不下")
        XCTAssertTrue(RemoteWindowStage.needsStage(fit: CGSize(width: 1003, height: 1426), visible: builtin), "竖握更放不下")
        XCTAssertFalse(RemoteWindowStage.needsStage(fit: CGSize(width: 951, height: 669), visible: builtin), "标准字号放得下：原地调")
        XCTAssertFalse(RemoteWindowStage.needsStage(fit: CGSize(width: 1426, height: 1003), visible: CGSize(width: 2560, height: 1380)),
                       "Studio Display 放得下")
        XCTAssertFalse(RemoteWindowStage.needsStage(fit: CGSize(width: 1512.4, height: 900), visible: builtin), "差不到一个点不算")
    }

    func test_in_place_fit_moves_the_window_up_only_when_it_would_run_past_the_visible_area() {
        // 2026-11-24 的现场：27 寸外接屏去掉菜单栏和程序坞是 y 30…1234，窗口上沿在 354，Duo 横握要 1426×1003。
        let visible = CGRect(x: 0, y: 30, width: 2304, height: 1204)
        let low = CGRect(x: 200, y: 354, width: 1200, height: 800)
        let moved = RemoteWindowStage.inPlaceFrame(window: low, fit: CGSize(width: 1426, height: 1003), visible: visible)
        XCTAssertEqual(moved, CGRect(x: 200, y: 231, width: 1426, height: 1003), "往上挪到下沿刚好贴着可用范围，左边不动")

        let high = CGRect(x: 200, y: 100, width: 1200, height: 800)
        XCTAssertEqual(RemoteWindowStage.inPlaceFrame(window: high, fit: CGSize(width: 1426, height: 1003), visible: visible).origin,
                       high.origin, "放得下就不挪")

        let right = CGRect(x: 1500, y: 100, width: 600, height: 400)
        XCTAssertEqual(RemoteWindowStage.inPlaceFrame(window: right, fit: CGSize(width: 1426, height: 1003), visible: visible).minX,
                       2304 - 1426, "右边伸出屏幕：往左挪")

        // 副屏在主屏左边（x 为负），菜单栏不在它上面。
        let side = CGRect(x: -2304, y: 0, width: 2304, height: 1296)
        let onSide = RemoteWindowStage.inPlaceFrame(window: CGRect(x: -900, y: 600, width: 800, height: 600),
                                                    fit: CGSize(width: 1426, height: 1003), visible: side)
        XCTAssertEqual(onSide, CGRect(x: -1426, y: 293, width: 1426, height: 1003))

        let tall = RemoteWindowStage.inPlaceFrame(window: low, fit: CGSize(width: 1426.4, height: 1500), visible: visible)
        XCTAssertEqual(tall.minY, visible.minY, "比可用范围还高（要建虚拟屏却没建成）：顶到上沿，尽量多露")
        XCTAssertEqual(tall.width, 1426, "大小按点取整")
    }

    func test_stage_holds_both_orientations_of_the_same_canvas() {
        let size = RemoteWindowStage.stageSize(for: CGSize(width: 1426, height: 1003))
        XCTAssertEqual(size.width, 1426)
        XCTAssertEqual(size.height, 1426 + RemoteWindowStage.menuBarReserve, "正方形加菜单栏：转屏不用重建")
        XCTAssertTrue(RemoteWindowStage.holds(CGSize(width: 1426, height: 1003), in: size))
        XCTAssertTrue(RemoteWindowStage.holds(CGSize(width: 1003, height: 1426), in: size))
        XCTAssertTrue(RemoteWindowStage.holds(CGSize(width: 1426, height: 535), in: size), "弹出键盘后变矮的也放得下")
        XCTAssertFalse(RemoteWindowStage.holds(CGSize(width: 1600, height: 900), in: size), "更大的设备来看：要重建")
    }

    func test_stage_size_is_even_and_bounded() {
        let odd = RemoteWindowStage.stageSize(for: CGSize(width: 1003.4, height: 700))
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertGreaterThanOrEqual(odd.width, 1004)
        let tiny = RemoteWindowStage.stageSize(for: CGSize(width: 300, height: 200))
        XCTAssertEqual(tiny.width, RemoteWindowStage.minimumSide, "2 倍模式每边要够大")
        let huge = RemoteWindowStage.stageSize(for: CGSize(width: 9000, height: 9000))
        XCTAssertEqual(huge.width, RemoteHeadlessDisplay.maximumPoints.width)
        XCTAssertEqual(huge.height, RemoteHeadlessDisplay.maximumPoints.height)
        XCTAssertFalse(RemoteWindowStage.holds(CGSize(width: 9000, height: 9000), in: huge), "超过上限：不建，原地尽量调")
    }

    func test_stage_display_is_not_mistaken_for_a_real_one_by_the_headless_logic() {
        // 没接显示器的 Mac 上那块顶替占位屏的虚拟屏在线时，窗口模式的虚拟屏出现不能被当成「接上真显示器了」。
        let online: [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32)] = [
            (1, RemoteHeadlessDisplay.virtualVendor, RemoteHeadlessDisplay.virtualModel),
            (2, RemoteHeadlessDisplay.virtualVendor, RemoteWindowStage.model),
        ]
        XCTAssertFalse(RemoteHeadlessDisplay.realDisplayAppeared(ours: 1, online: online))
        XCTAssertNotEqual(RemoteWindowStage.model, RemoteHeadlessDisplay.virtualModel)
    }
}
