import XCTest
@testable import uTermMobile

/// 捏合 / 平移之后光标留在画面里：否则下一次移动或点击都发生在看不见的地方。
@MainActor
final class RemoteDesktopPointerTests: XCTestCase {
    private let view = CGSize(width: 400, height: 300)

    /// 放大 4 倍，画面停在左上角：光标在右下角的话已经跑到画面外了。
    private func zoomedIntoTopLeft() -> RemoteDesktopViewport {
        var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 1600, height: 1000), viewSize: view)
        viewport.zoom(by: 4, anchor: .zero)
        return viewport
    }

    private let outside = CGPoint(x: 0.9, y: 0.9)

    func testPointerLeftOutsideIsPulledBackInsideTheMargin() {
        let viewport = zoomedIntoTopLeft()
        XCTAssertGreaterThan(viewport.viewPoint(normalized: outside).x, view.width, "前提：捏合后光标在画面外")

        let kept = RemoteDesktopCanvasView.pointerKeptInView(outside, viewport: viewport, canControl: true, cursorVisible: true)

        let onScreen = viewport.viewPoint(normalized: kept)
        XCTAssertEqual(onScreen.x, view.width - 48, accuracy: 0.5)
        XCTAssertEqual(onScreen.y, view.height - 48, accuracy: 0.5)
    }

    /// 没跑出画面就不算移动，也就不会多发一条指针消息（发不发看 `lastSentPointer != pointer`）。
    func testPointerAlreadyVisibleStaysExactlyWhereItIs() {
        let viewport = zoomedIntoTopLeft()
        let visible = viewport.normalized(viewPoint: CGPoint(x: 200, y: 150))

        let kept = RemoteDesktopCanvasView.pointerKeptInView(visible, viewport: viewport, canControl: true, cursorVisible: true)

        XCTAssertEqual(kept, visible)
    }

    func testViewOnlySessionNeverMovesTheMacPointer() {
        let kept = RemoteDesktopCanvasView.pointerKeptInView(outside, viewport: zoomedIntoTopLeft(),
                                                             canControl: false, cursorVisible: true)
        XCTAssertEqual(kept, outside, "只能看：指针跟着 Mac 报回的位置走")
    }

    func testCursorOnAnotherDisplayIsLeftAlone() {
        let kept = RemoteDesktopCanvasView.pointerKeptInView(outside, viewport: zoomedIntoTopLeft(),
                                                             canControl: true, cursorVisible: false)
        XCTAssertEqual(kept, outside, "光标在别的屏上，不能把它拽回这块屏")
    }

    func testFittedViewportLeavesThePointerAlone() {
        let fitted = RemoteDesktopViewport(contentSize: CGSize(width: 1600, height: 1000), viewSize: view)
        let kept = RemoteDesktopCanvasView.pointerKeptInView(outside, viewport: fitted, canControl: true, cursorVisible: true)
        XCTAssertEqual(kept, outside, "没放大时整块屏都看得见")
    }
}
