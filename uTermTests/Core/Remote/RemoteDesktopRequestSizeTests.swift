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

    /// 2026-11-15 Duo 实测：Mac 的虚拟屏 1920×1230 点，画布 1000×646.5pt，宽高比差 0.9%。原来画面铺满宽度、
    /// 底下留 6pt 黑条，下角还进了屏幕圆角；现在拉成画布的比例，整块铺满。
    func test_nearly_matching_picture_is_stretched_to_fill() {
        let canvas = Self.duoCanvas
        let content = CGSize(width: 1920, height: 1230)
        var viewport = RemoteDesktopViewport(contentSize: content, viewSize: canvas, corners: Self.bottom55,
                                             bleedsIntoCorners: true)
        XCTAssertEqual(viewport.contentFrame.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(viewport.contentFrame.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(viewport.contentFrame.width, canvas.width, accuracy: 1e-6)
        XCTAssertEqual(viewport.contentFrame.height, canvas.height, accuracy: 1e-6)
        XCTAssertTrue(viewport.pictureCorners.isSquare)
        // 触点照样对应整块显示器：画布的四个角就是显示器的四个角。
        let far = viewport.normalized(viewPoint: CGPoint(x: canvas.width, y: canvas.height))
        XCTAssertEqual(far.x, 1, accuracy: 1e-9)
        XCTAssertEqual(far.y, 1, accuracy: 1e-9)
        let middle = viewport.viewPoint(normalized: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(middle.x, canvas.width / 2, accuracy: 1e-6)
        XCTAssertEqual(middle.y, canvas.height / 2, accuracy: 1e-6)
        // 手指横扫过整块画布（增益 1 的速度），光标也正好横穿整块显示器。
        let swept = RemoteTrackpad.advance(CGPoint(x: 0, y: 0), by: CGSize(width: canvas.width, height: canvas.height),
                                           speed: 150, viewport: viewport)
        XCTAssertEqual(swept.x, 1, accuracy: 1e-9)
        XCTAssertEqual(swept.y, 1, accuracy: 1e-9)
        // 放大后同样拉着，两个方向一样放大，拖不出边界。
        viewport.setZoom(2)
        XCTAssertEqual(viewport.contentFrame.width, canvas.width * 2, accuracy: 1e-6)
        XCTAssertEqual(viewport.contentFrame.height, canvas.height * 2, accuracy: 1e-6)
        viewport.pan(by: CGSize(width: 10_000, height: 10_000))
        XCTAssertEqual(viewport.contentFrame.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(viewport.contentFrame.minY, 0, accuracy: 1e-6)

        // 比例反过来差一丝（画面比画布高一点）：同样拉满。
        let taller = RemoteDesktopViewport(contentSize: CGSize(width: 1920, height: 1260), viewSize: canvas,
                                           corners: Self.bottom55, bleedsIntoCorners: true)
        XCTAssertEqual(taller.contentFrame.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(taller.contentFrame.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(taller.contentFrame.width, canvas.width, accuracy: 1e-6)
        XCTAssertEqual(taller.contentFrame.height, canvas.height, accuracy: 1e-6)
    }

    /// 差得多的不拉（Duo 看 16:9 外接屏，差 15%）：照旧铺满宽度、挪开下角；Mac 窗口从不拉。
    func test_stretch_only_for_small_mismatches_on_the_phone() {
        let canvas = Self.duoCanvas
        let external = RemoteDesktopViewport(contentSize: CGSize(width: 2560, height: 1440), viewSize: canvas,
                                             corners: Self.bottom55, bleedsIntoCorners: true)
        XCTAssertEqual(external.pictureSize, CGSize(width: 2560, height: 1440))
        XCTAssertEqual(external.contentFrame.width / external.contentFrame.height, 2560.0 / 1440.0, accuracy: 1e-9)
        // 差 3%：超过容差，不拉。
        let off = CGSize(width: canvas.width * 1.03, height: canvas.height)
        let notStretched = RemoteDesktopViewport(contentSize: off, viewSize: canvas, corners: Self.bottom55,
                                                 bleedsIntoCorners: true)
        XCTAssertEqual(notStretched.pictureSize, off)
        // Mac 窗口（不贴边）：差一丝也不拉。
        let window = RemoteDesktopViewport(contentSize: CGSize(width: 1920, height: 1230), viewSize: canvas,
                                           corners: Self.bottom55)
        XCTAssertEqual(window.pictureSize, CGSize(width: 1920, height: 1230))
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

    /// 点按钮时就开流用的记忆：按屏幕大小和像素倍数分开记，横竖不混；最多留几条。
    func testRequestSizeMemoryIsKeyedByScreenAndOrientation() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "uTerm.tests.requestSizeMemory.\(UUID().uuidString)"))
        typealias Memory = RemoteDesktopRequestSizeMemory
        let landscape = CGSize(width: 1000, height: 703.5), portrait = CGSize(width: 703.5, height: 1000)
        XCTAssertNil(Memory.load(screen: landscape, scale: 2, defaults: defaults))
        Memory.save(RemoteDesktopRequestSize(width: 3104, height: 2007), screen: landscape, scale: 2, defaults: defaults)
        XCTAssertEqual(Memory.load(screen: landscape, scale: 2, defaults: defaults),
                       RemoteDesktopRequestSize(width: 3104, height: 2007))
        XCTAssertNil(Memory.load(screen: portrait, scale: 2, defaults: defaults), "竖着的另算")
        XCTAssertNil(Memory.load(screen: landscape, scale: 3, defaults: defaults), "像素倍数不同另算")
        Memory.save(RemoteDesktopRequestSize(width: 3100, height: 2000), screen: landscape, scale: 2, defaults: defaults)
        XCTAssertEqual(Memory.load(screen: landscape, scale: 2, defaults: defaults)?.width, 3100, "后量出来的为准")
        for index in 0..<20 {
            Memory.save(RemoteDesktopRequestSize(width: index, height: 1), screen: CGSize(width: 300 + index, height: 600),
                        scale: 2, defaults: defaults)
        }
        let kept = (0..<20).filter { Memory.load(screen: CGSize(width: 300 + $0, height: 600), scale: 2, defaults: defaults) != nil }
        XCTAssertLessThanOrEqual(kept.count, 8)
    }
}
