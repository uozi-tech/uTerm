import CoreGraphics
import XCTest
@testable import uTerm

/// 手机向 Mac 要多大的画面：比例按顶栏下面的画布，不按整块屏幕。
final class RemoteDesktopRequestSizeTests: XCTestCase {
    /// Duo 内屏横着（2026-11-15 截图量的）：屏幕 1000×703.5pt、2 倍，顶栏约 57pt（顶边距 16），下角圆角 55pt。
    private static let duoScreen = CGSize(width: 1000, height: 703.5)
    private static let duoBar: CGFloat = 57
    private static let duoCanvas = CGSize(width: 1000, height: 703.5 - 57)
    private static let bottom55 = RemoteDesktopCornerRadii(bottomLeft: 55, bottomRight: 55)

    private func duoRequest() -> RemoteDesktopRequestSize {
        .fitting(screen: Self.duoScreen, scale: 2, barHeight: Self.duoBar, topInset: 16, bottomCornerRadius: 55)
    }

    /// 无显示器的 Mac 按请求建出的虚拟屏，放进手机的画布里「适配屏幕」后的位置。
    private func fittedFrame(request: (width: Int, height: Int), canvas: CGSize,
                             corners: RemoteDesktopCornerRadii) -> CGRect {
        let display = RemoteHeadlessDisplay.virtualSize(viewerPixels: request)
        return RemoteDesktopViewport(contentSize: CGSize(width: display.width, height: display.height),
                                     viewSize: canvas, corners: corners).contentFrame
    }

    // MARK: - 正好铺满的那一块

    func test_fill_size_leaves_the_margin_only_under_rounded_corners() {
        let canvas = Self.duoCanvas
        let gap = RemoteDesktopCornerFit.gap
        let rounded = RemoteDesktopCornerFit.fillSize(view: canvas, corners: Self.bottom55)
        XCTAssertEqual(rounded, CGSize(width: canvas.width - gap * 2, height: canvas.height - gap * 2))
        XCTAssertEqual(RemoteDesktopCornerFit.fillSize(view: canvas, corners: .square), canvas, "直角屏：贴边铺满")

        // 这个比例的画面适配后就是那一块：四边各留 gap，没有多出来的黑边。
        let viewport = RemoteDesktopViewport(contentSize: rounded, viewSize: canvas, corners: Self.bottom55)
        let frame = viewport.contentFrame
        XCTAssertEqual(frame.minX, gap, accuracy: 1e-6)
        XCTAssertEqual(frame.minY, gap, accuracy: 1e-6)
        XCTAssertEqual(frame.width, rounded.width, accuracy: 1e-6)
        XCTAssertEqual(frame.height, rounded.height, accuracy: 1e-6)
    }

    // MARK: - Duo 内屏看无显示器的 Mac

    /// 回归：原先按整块屏幕的比例要，虚拟屏放进顶栏下面的画布，左右各空 70pt。
    func test_headless_display_fills_the_duo_canvas() {
        let request = duoRequest()
        let gap = RemoteDesktopCornerFit.gap
        let frame = fittedFrame(request: (request.width, request.height), canvas: Self.duoCanvas, corners: Self.bottom55)
        // 虚拟屏的点数取整，比例差不到一个点。
        XCTAssertEqual(frame.minX, gap, accuracy: 1)
        XCTAssertEqual(frame.maxX, Self.duoCanvas.width - gap, accuracy: 1)
        XCTAssertEqual(frame.minY, gap, accuracy: 1)
        XCTAssertEqual(frame.maxY, Self.duoCanvas.height - gap, accuracy: 1)

        // 对照：按整块屏幕要（原来的做法），同一块画布里左右空出一大截。
        let old = RemoteDesktopSession.requestedSize(longPixels: 2000, shortPixels: 1407)
        let oldFrame = fittedFrame(request: old, canvas: Self.duoCanvas, corners: Self.bottom55)
        XCTAssertGreaterThan(oldFrame.minX, 40)
    }

    func test_request_keeps_the_canvas_aspect_and_covers_the_screen_pixels() {
        let request = duoRequest()
        let fill = RemoteDesktopCornerFit.fillSize(view: Self.duoCanvas, corners: Self.bottom55)
        XCTAssertEqual(CGFloat(request.width) / CGFloat(request.height), fill.width / fill.height, accuracy: 0.001)
        XCTAssertEqual(request.height, 1407, "短边还是屏幕的像素")
        XCTAssertGreaterThanOrEqual(request.width, 2000)
    }

    /// 接着显示器的 Mac 只拿这个框定视频尺寸：不比按整块屏幕要的时候小。
    func test_stream_on_a_real_display_is_not_smaller_than_before() {
        let request = duoRequest()
        let old = RemoteDesktopSession.requestedSize(longPixels: 2000, shortPixels: 1407)
        for display in [CGSize(width: 3840, height: 2160), CGSize(width: 3024, height: 1964), CGSize(width: 5120, height: 2160)] {
            let now = RemoteDesktopGeometry.streamSize(displayPixels: display, maxWidth: request.width, maxHeight: request.height)
            let before = RemoteDesktopGeometry.streamSize(displayPixels: display, maxWidth: old.width, maxHeight: old.height)
            XCTAssertGreaterThanOrEqual(now.width, before.width, "\(display)")
            XCTAssertGreaterThanOrEqual(now.height, before.height, "\(display)")
        }
    }

    // MARK: - 方向

    /// 竖着开和横着开要的一样：竖握时顶边距里多出来的（灵动岛 59pt）横过来就没有了。
    func test_portrait_start_asks_for_the_landscape_canvas() {
        let row: CGFloat = 40
        let landscape = RemoteDesktopRequestSize.fitting(
            screen: CGSize(width: 874, height: 402), scale: 3, barHeight: 16 + row, topInset: 16, bottomCornerRadius: 55)
        let portrait = RemoteDesktopRequestSize.fitting(
            screen: CGSize(width: 402, height: 874), scale: 3, barHeight: 59 + row, topInset: 59, bottomCornerRadius: 55)
        XCTAssertEqual(portrait, landscape)
        XCTAssertEqual(RemoteDesktopRequestSize.landscapeCanvas(screen: CGSize(width: 402, height: 874),
                                                                barHeight: 59 + row, topInset: 59),
                       CGSize(width: 874, height: 402 - 16 - row))
        // 竖握的顶边距本来就不大（直角屏）：照原样。
        XCTAssertEqual(RemoteDesktopRequestSize.landscapeCanvas(screen: CGSize(width: 375, height: 667),
                                                                barHeight: 14 + row, topInset: 14),
                       CGSize(width: 667, height: 375 - 14 - row))

        // 横着的手机：建出的虚拟屏铺满画布。
        let canvas = CGSize(width: 874, height: 402 - 16 - row)
        let corners = Self.bottom55
        let gap = RemoteDesktopCornerFit.gap
        let frame = fittedFrame(request: (landscape.width, landscape.height), canvas: canvas, corners: corners)
        XCTAssertEqual(frame.minX, gap, accuracy: 1)
        XCTAssertEqual(frame.maxX, canvas.width - gap, accuracy: 1)
        XCTAssertEqual(frame.maxY, canvas.height - gap, accuracy: 1)
    }

    // MARK: - 边界

    func test_small_square_screen_still_asks_for_1080p() {
        // 直角屏的小手机（667×375pt、2 倍）：画布 667×321，贴边铺满。
        let request = RemoteDesktopRequestSize.fitting(
            screen: CGSize(width: 667, height: 375), scale: 2, barHeight: 54, topInset: 14, bottomCornerRadius: 0)
        XCTAssertEqual(request.height, 1080)
        XCTAssertEqual(CGFloat(request.width) / CGFloat(request.height), 667.0 / 321.0, accuracy: 0.001)
        let frame = fittedFrame(request: (request.width, request.height), canvas: CGSize(width: 667, height: 321), corners: .square)
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(frame.maxX, 667, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 321, accuracy: 0.5)
    }

    func test_unmeasured_canvas_falls_back_to_the_screen_pixels() {
        let box = RemoteDesktopSession.requestedSize(longPixels: 2000, shortPixels: 1407)
        for bar in [CGFloat(703.5), 2000] {
            let request = RemoteDesktopRequestSize.fitting(screen: Self.duoScreen, scale: 2, barHeight: bar, topInset: 16,
                                                           bottomCornerRadius: 55)
            XCTAssertEqual(request, RemoteDesktopRequestSize(width: box.width, height: box.height))
        }
        let empty = RemoteDesktopRequestSize.fitting(screen: .zero, scale: 2, barHeight: 0, topInset: 0, bottomCornerRadius: 0)
        XCTAssertEqual(empty, RemoteDesktopRequestSize(width: 1920, height: 1080))
    }
}
