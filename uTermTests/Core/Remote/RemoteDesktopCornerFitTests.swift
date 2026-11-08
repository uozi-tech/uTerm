import AppKit
import XCTest
@testable import uTerm

/// 远程桌面「适配屏幕」避开圆角：真窗口里量得到圆角，几何对照图（改前 / 改后）给人眼验收。
@MainActor
final class RemoteDesktopCornerFitTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    /// 「适配屏幕」避开圆角：画面四角都在圆角弧线以内（手机铺满整屏的画布、Mac 的圆角窗口）。
    /// 两种几何：MacBook 内建屏（带刘海，1512×982）与 16:9 外接屏（2560×1440）。
    func test_viewport_fit_keeps_all_four_corners_out_of_rounded_corners() {
        let builtIn = CGSize(width: 1512, height: 982)
        let external = CGSize(width: 2560, height: 1440)
        // 手机横屏（Duo 内屏一类）：画布在顶栏下面、铺到屏幕底边，下面两个角是 55pt 的屏幕圆角。
        // Mac 窗口：窗口按屏幕比例对好（画布正好是显示器比例），四角 16pt。
        let cases: [(content: CGSize, view: CGSize, radius: CGFloat)] = [
            (builtIn, CGSize(width: 1000, height: 660), 55),
            (external, CGSize(width: 1000, height: 660), 55),
            (builtIn, CGSize(width: 402, height: 820), 55),   // 竖屏：上下留黑边
            (builtIn, CGSize(width: 1200, height: 1200 * 982 / 1512), 16),
            (external, CGSize(width: 1280, height: 720), 16),
        ]
        for (content, view, radius) in cases {
            let viewport = RemoteDesktopViewport(contentSize: content, viewSize: view, cornerRadius: radius)
            let plain = RemoteDesktopViewport(contentSize: content, viewSize: view)
            let frame = viewport.contentFrame
            let label = "\(content) in \(view) r=\(radius)"
            // 四个角离视图两边的距离一样（居中），且都在弧线以内。
            XCTAssertEqual(frame.midX, view.width / 2, accuracy: 1e-6, label)
            XCTAssertEqual(frame.midY, view.height / 2, accuracy: 1e-6, label)
            XCTAssertTrue(RemoteDesktopCornerFit.clears(dx: frame.minX, dy: frame.minY, radius: radius), label)
            // 等比，不超过普通适配；只缩到刚好避开为止（再大一点就进了弧线），面积损失有限。
            XCTAssertEqual(frame.width / frame.height, content.width / content.height, accuracy: 1e-6, label)
            XCTAssertLessThanOrEqual(viewport.fitScale, plain.fitScale + 1e-9, label)
            let bigger = viewport.fitScale * 1.002
            if bigger < plain.fitScale {
                XCTAssertFalse(RemoteDesktopCornerFit.clears(dx: (view.width - content.width * bigger) / 2,
                                                             dy: (view.height - content.height * bigger) / 2,
                                                             radius: radius), label)
            }
            XCTAssertGreaterThan(viewport.fitScale / plain.fitScale, 0.9, label)
        }
        // 两侧本来就留着足够黑边的（竖屏），不用缩。
        let portrait = RemoteDesktopViewport(contentSize: builtIn, viewSize: CGSize(width: 402, height: 820), cornerRadius: 55)
        XCTAssertGreaterThan(portrait.contentFrame.minY, 55 * RemoteDesktopCornerFit.continuousAllowance)
        XCTAssertEqual(portrait.fitScale, RemoteDesktopViewport(contentSize: builtIn, viewSize: CGSize(width: 402, height: 820)).fitScale,
                       accuracy: 1e-9)
        // 没有圆角就是原来的适配。
        XCTAssertEqual(RemoteDesktopCornerFit.scale(content: builtIn, view: CGSize(width: 874, height: 402), cornerRadius: 0),
                       402.0 / 982.0, accuracy: 1e-9)
        // 放大后可以铺进圆角（缩放下限仍是避开圆角的适配）。
        var zoomed = RemoteDesktopViewport(contentSize: builtIn, viewSize: CGSize(width: 1000, height: 660), cornerRadius: 55)
        zoomed.zoom(by: 2, anchor: CGPoint(x: 500, y: 330))
        XCTAssertLessThan(zoomed.contentFrame.minX, 0)
    }

    /// 和远程屏幕窗口同一种窗口（隐藏标题栏、内容铺满）：探针贴着窗口底边时量出窗口的圆角，挪开就没有。
    func test_corner_probe_reads_the_window_corner_radius() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("macOS 27 起才有同心圆角接口，之前走固定值") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        windows.append(window)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = content
        let probe = RemoteDesktopCornerProbeView(frame: NSRect(x: 0, y: 0, width: 900, height: 564))
        content.addSubview(probe)
        let inset = RemoteDesktopCornerProbeView(frame: NSRect(x: 40, y: 40, width: 820, height: 480))
        content.addSubview(inset)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        let radii = try XCTUnwrap(probe.effectiveCornerRadii)
        print("[corner-fit] window corner radii: tl \(radii.topLeft) tr \(radii.topRight) bl \(radii.bottomLeft) br \(radii.bottomRight)")
        XCTAssertGreaterThan(max(radii.bottomLeft, radii.bottomRight), 4, "贴着窗口底边的两个角要量出窗口圆角")
        let inner = try XCTUnwrap(inset.effectiveCornerRadii)
        XCTAssertLessThan(max(inner.bottomLeft, inner.bottomRight), max(radii.bottomLeft, radii.bottomRight),
                          "离窗口边越远，同心圆角越小")
    }

    // MARK: - 几何对照图

    /// 设置 `UTERM_REMOTE_SHOTS` 才画：每张图左边是改前（按矩形适配），右边是改后（避开圆角）。
    /// 画面用示意的 Mac 屏幕：顶上菜单栏（两头各一个标记）、底下 Dock（两端各一个标记），标记被切就看得出来。
    func test_render_corner_fit_geometry() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_REMOTE_SHOTS"] ?? env["TEST_RUNNER_UTERM_REMOTE_SHOTS"], !raw.isEmpty else {
            throw XCTSkip("设置 UTERM_REMOTE_SHOTS=<目录> 才画几何对照图")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let builtIn = CGSize(width: 1512, height: 982)
        let external = CGSize(width: 2560, height: 1440)
        // 手机横屏：顶栏 56pt 不画画面，画布铺到屏幕底边，屏幕四角 55pt。
        let phone = (screen: CGSize(width: 1000, height: 716), canvasTop: CGFloat(56), radius: CGFloat(55))
        let shots: [(String, CGSize, CGSize, CGFloat, CGFloat)] = [
            ("corner-fit-phone-builtin", builtIn, phone.screen, phone.canvasTop, phone.radius),
            ("corner-fit-phone-external", external, phone.screen, phone.canvasTop, phone.radius),
            // Mac 窗口：标题栏 36pt，画布按显示器比例对好，窗口四角 16pt。
            ("corner-fit-mac-window-builtin", builtIn,
             CGSize(width: 1200, height: 36 + 1200 * builtIn.height / builtIn.width), 36, 16),
            ("corner-fit-mac-window-external", external,
             CGSize(width: 1280, height: 36 + 1280 * external.height / external.width), 36, 16),
        ]
        for (name, content, screen, top, radius) in shots {
            let png = try render(content: content, screen: screen, canvasTop: top, radius: radius)
            try png.write(to: dir.appendingPathComponent("\(name).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(name).png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        print("[remote-shots] dir=\(dir.path)")
    }

    private func render(content: CGSize, screen: CGSize, canvasTop: CGFloat, radius: CGFloat) throws -> Data {
        let gap: CGFloat = 40
        let size = CGSize(width: screen.width * 2 + gap * 3, height: screen.height + gap * 2 + 24)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = context.cgContext
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        // 坐标翻成左上角原点后，文字也要按翻转的上下文画，不然是倒的。
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        cg.setFillColor(NSColor(white: 0.92, alpha: 1).cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        let canvas = CGSize(width: screen.width, height: screen.height - canvasTop)
        for (index, corners) in [CGFloat(0), radius].enumerated() {
            let origin = CGPoint(x: gap + CGFloat(index) * (screen.width + gap), y: gap + 24)
            let label = index == 0 ? "改前：按矩形适配" : "改后：避开圆角（r=\(Int(radius))）"
            (label as NSString).draw(at: CGPoint(x: origin.x, y: gap - 4),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
            cg.saveGState()
            // 屏幕 / 窗口的外形：圆角之外看不见。
            let outline = CGPath(roundedRect: CGRect(origin: origin, size: screen), cornerWidth: radius, cornerHeight: radius,
                                 transform: nil)
            cg.addPath(outline)
            cg.clip()
            cg.setFillColor(NSColor.black.cgColor)
            cg.fill(CGRect(origin: origin, size: screen))
            let viewport = RemoteDesktopViewport(contentSize: content, viewSize: canvas, cornerRadius: corners)
            let frame = viewport.contentFrame.offsetBy(dx: origin.x, dy: origin.y + canvasTop)
            drawMacScreen(in: frame, cg: cg)
            cg.restoreGState()
            cg.addPath(outline)
            cg.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
            cg.setLineWidth(2)
            cg.strokePath()
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// 示意的 Mac 屏幕：壁纸、菜单栏（左头苹果、右头时钟的位置画红块）、Dock（两端红块）。
    private func drawMacScreen(in frame: CGRect, cg: CGContext) {
        cg.setFillColor(NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.85, alpha: 1).cgColor)
        cg.fill(frame)
        let bar = frame.height * 0.035
        cg.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
        cg.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: bar))
        let mark = bar * 0.7
        cg.setFillColor(NSColor.systemRed.cgColor)
        cg.fill(CGRect(x: frame.minX + bar * 0.5, y: frame.minY + (bar - mark) / 2, width: mark, height: mark))
        cg.fill(CGRect(x: frame.maxX - bar * 0.5 - mark * 2, y: frame.minY + (bar - mark) / 2, width: mark * 2, height: mark))
        let dock = CGRect(x: frame.minX + frame.width * 0.02, y: frame.maxY - frame.height * 0.075,
                          width: frame.width * 0.96, height: frame.height * 0.065)
        cg.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor)
        cg.addPath(CGPath(roundedRect: dock, cornerWidth: dock.height * 0.25, cornerHeight: dock.height * 0.25, transform: nil))
        cg.fillPath()
        let icon = dock.height * 0.7
        cg.setFillColor(NSColor.systemRed.cgColor)
        cg.fill(CGRect(x: dock.minX + dock.height * 0.15, y: dock.midY - icon / 2, width: icon, height: icon))
        cg.fill(CGRect(x: dock.maxX - dock.height * 0.15 - icon, y: dock.midY - icon / 2, width: icon, height: icon))
    }
}
