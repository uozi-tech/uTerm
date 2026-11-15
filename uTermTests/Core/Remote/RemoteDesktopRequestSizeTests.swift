import CoreGraphics
import XCTest
@testable import uTerm

/// 手机向 Mac 要多大的画面：比例按顶栏下面的画布，不按整块屏幕；手机上「适配屏幕」贴边铺满。
final class RemoteDesktopRequestSizeTests: XCTestCase {
    /// Duo 内屏横着（2026-11-15 截图量的）：屏幕 1000×703.5pt、2 倍，顶栏约 57pt（顶边距 16），下角圆角 55pt。
    private static let duoScreen = CGSize(width: 1000, height: 703.5)
    private static let duoBar: CGFloat = 57
    private static let duoCanvas = CGSize(width: 1000, height: 703.5 - 57)
    private static let bottom55 = RemoteDesktopCornerRadii(bottomLeft: 55, bottomRight: 55)

    private func duoRequest() -> RemoteDesktopRequestSize {
        .fitting(screen: Self.duoScreen, scale: 2, barHeight: Self.duoBar, topInset: 16)
    }

    /// 无显示器的 Mac 按请求建出的虚拟屏，放进手机的画布里「适配屏幕」后的视口。
    private func phoneViewport(request: (width: Int, height: Int), scale: Double, canvas: CGSize,
                               corners: RemoteDesktopCornerRadii) -> RemoteDesktopViewport {
        let display = RemoteHeadlessDisplay.virtualSize(viewerPixels: request, pointScale: scale)
        return RemoteDesktopViewport(contentSize: CGSize(width: display.width, height: display.height),
                                     viewSize: canvas, corners: corners, bleedsIntoCorners: true)
    }

    private func assertFills(_ viewport: RemoteDesktopViewport, _ canvas: CGSize, file: StaticString = #filePath,
                             line: UInt = #line) {
        // 虚拟屏的点数取整，比例差不到一个点。
        let frame = viewport.contentFrame
        XCTAssertEqual(frame.minX, 0, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.maxX, canvas.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.minY, 0, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.maxY, canvas.height, accuracy: 1, file: file, line: line)
        XCTAssertTrue(viewport.pictureCorners.isSquare, "直角：落进屏幕圆角的那一点由屏幕自己切", file: file, line: line)
    }

    // MARK: - 手机上贴边铺满

    /// 画面的角躲不开屏幕圆角时：Mac 窗口留一圈窄边、切同心圆角；手机贴边铺满、直角。
    func test_phone_bleeds_into_corners_where_the_mac_window_keeps_a_margin() {
        let canvas = Self.duoCanvas
        let gap = RemoteDesktopCornerFit.gap
        let window = RemoteDesktopViewport(contentSize: canvas, viewSize: canvas, corners: Self.bottom55)
        XCTAssertEqual(window.contentFrame.minY, gap, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(window.contentFrame.minX, gap)
        XCTAssertFalse(window.pictureCorners.isSquare)

        let phone = RemoteDesktopViewport(contentSize: canvas, viewSize: canvas, corners: Self.bottom55,
                                          bleedsIntoCorners: true)
        XCTAssertEqual(phone.contentFrame, CGRect(origin: .zero, size: canvas))
        XCTAssertEqual(phone.fitScale, 1, accuracy: 1e-9)
        XCTAssertTrue(phone.pictureCorners.isSquare)
        // 触点映射跟着：画布的角就是显示器的角。
        let corner = phone.normalized(viewPoint: CGPoint(x: canvas.width, y: canvas.height))
        XCTAssertEqual(corner.x, 1, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 1, accuracy: 1e-9)
    }

    /// 留着黑边、挪得开的照旧挪（Duo 内屏看 16:9 外接屏）：铺满宽度、往上挪到下角躲开弧线，不去贴底。
    func test_bleeding_still_shifts_a_letterboxed_picture_clear_of_the_corners() {
        let canvas = Self.duoCanvas
        let content = CGSize(width: 2560, height: 1440)
        let phone = RemoteDesktopViewport(contentSize: content, viewSize: canvas, corners: Self.bottom55,
                                          bleedsIntoCorners: true)
        let window = RemoteDesktopViewport(contentSize: content, viewSize: canvas, corners: Self.bottom55)
        XCTAssertEqual(phone.contentFrame, window.contentFrame)
        XCTAssertEqual(phone.contentFrame.width, canvas.width, accuracy: 1e-6)
        XCTAssertEqual(canvas.height - phone.contentFrame.maxY, RemoteDesktopCornerFit.clearance(other: 0, radius: 55),
                       accuracy: 1e-6)

        // 黑边不够挪开（画布比画面只高一点）：宽度照样铺满，贴着直角的上沿放，不缩一圈。
        let nearly = CGSize(width: canvas.width, height: canvas.height - 20)
        let tight = RemoteDesktopViewport(contentSize: nearly, viewSize: canvas, corners: Self.bottom55,
                                          bleedsIntoCorners: true)
        XCTAssertEqual(tight.contentFrame, CGRect(origin: .zero, size: nearly))
        XCTAssertTrue(tight.pictureCorners.isSquare)
    }

    // MARK: - Duo 内屏看无显示器的 Mac

    /// 回归：原先按整块屏幕的比例要，虚拟屏放进顶栏下面的画布，左右各空 70pt。
    func test_headless_display_fills_the_duo_canvas() {
        let request = duoRequest()
        assertFills(phoneViewport(request: (request.width, request.height), scale: 2, canvas: Self.duoCanvas,
                                  corners: Self.bottom55), Self.duoCanvas)
        // 老的 Mac 不认像素倍数（按老下限建更大的虚拟屏）：一样铺满。
        let display = RemoteHeadlessDisplay.virtualSize(viewerPixels: (request.width, request.height))
        assertFills(RemoteDesktopViewport(contentSize: CGSize(width: display.width, height: display.height),
                                          viewSize: Self.duoCanvas, corners: Self.bottom55, bleedsIntoCorners: true),
                    Self.duoCanvas)

        // 对照：按整块屏幕要（原来的做法），同一块画布里左右空出一截。
        let old = RemoteDesktopSession.requestedSize(longPixels: 2000, shortPixels: 1407)
        let oldFrame = phoneViewport(request: old, scale: 2, canvas: Self.duoCanvas, corners: Self.bottom55).contentFrame
        XCTAssertGreaterThan(oldFrame.minX, 30)
    }

    func test_request_keeps_the_canvas_aspect_and_covers_the_screen_pixels() {
        let request = duoRequest()
        XCTAssertEqual(CGFloat(request.width) / CGFloat(request.height), Self.duoCanvas.width / Self.duoCanvas.height,
                       accuracy: 0.001)
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
            screen: CGSize(width: 874, height: 402), scale: 3, barHeight: 16 + row, topInset: 16)
        let portrait = RemoteDesktopRequestSize.fitting(
            screen: CGSize(width: 402, height: 874), scale: 3, barHeight: 59 + row, topInset: 59)
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
        assertFills(phoneViewport(request: (landscape.width, landscape.height), scale: 3, canvas: canvas,
                                  corners: Self.bottom55), canvas)
    }

    // MARK: - 边界

    func test_small_square_screen_still_asks_for_1080p() {
        // 直角屏的小手机（667×375pt、2 倍）：画布 667×321。
        let request = RemoteDesktopRequestSize.fitting(screen: CGSize(width: 667, height: 375), scale: 2, barHeight: 54,
                                                       topInset: 14)
        XCTAssertEqual(request.height, 1080)
        XCTAssertEqual(CGFloat(request.width) / CGFloat(request.height), 667.0 / 321.0, accuracy: 0.001)
        let canvas = CGSize(width: 667, height: 321)
        assertFills(phoneViewport(request: (request.width, request.height), scale: 2, canvas: canvas, corners: .square),
                    canvas)
    }

    func test_unmeasured_canvas_falls_back_to_the_screen_pixels() {
        let box = RemoteDesktopSession.requestedSize(longPixels: 2000, shortPixels: 1407)
        for bar in [CGFloat(703.5), 2000] {
            let request = RemoteDesktopRequestSize.fitting(screen: Self.duoScreen, scale: 2, barHeight: bar, topInset: 16)
            XCTAssertEqual(request, RemoteDesktopRequestSize(width: box.width, height: box.height))
        }
        let empty = RemoteDesktopRequestSize.fitting(screen: .zero, scale: 2, barHeight: 0, topInset: 0)
        XCTAssertEqual(empty, RemoteDesktopRequestSize(width: 1920, height: 1080))
    }
}
