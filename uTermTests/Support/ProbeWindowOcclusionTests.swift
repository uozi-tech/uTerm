import AppKit
import XCTest
@testable import uTerm

/// 读画面的用例（Ghostty 的 surface）要窗口「看得见」：AppKit 报窗口被完全遮挡（`occlusionState` 不含 `.visible`）时，
/// GhosttyKit 停掉显示节拍、不出新帧。2026-11-10 连跑 10 轮读画面的用例，6 次失败全部紧跟在探针窗口被别的 App 的窗口
/// 盖住之后；读画面的探针窗口改成浮层（`keepsDrawing: true`）之后 10 轮 80 条全过、一次遮挡都没有。这里把那条修法钉住。
@MainActor
final class ProbeWindowOcclusionTests: XCTestCase {

    func testTransparentProbeWindowsFloatAboveOtherAppsAndLetClicksThrough() {
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                      contentView: NSView(), placement: .transparentOnScreen, keepsDrawing: true)
        defer { window.orderOut(nil) }
        XCTAssertEqual(window.level, .floating, "普通层级会被别的 App 的窗口盖住，Ghostty 随即停画")
        XCTAssertTrue(window.ignoresMouseEvents, "看不见又浮在上面，不能吃用户的点击")
        XCTAssertEqual(window.alphaValue, 0)
    }

    /// 不传 `keepsDrawing` 的窗口不变：悬停探针（`RowHoverTrackerProbeTests`）的追踪区读数跟着层级变。
    func testOtherProbeWindowsKeepTheNormalLevel() {
        for placement in [ProbeWindow.Placement.offScreen, .transparentOnScreen, .visibleOnScreen] {
            let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                          contentView: NSView(), placement: placement)
            defer { window.orderOut(nil) }
            XCTAssertEqual(window.level, .normal, "\(placement)")
            XCTAssertFalse(window.ignoresMouseEvents, "\(placement)")
        }
    }
}
