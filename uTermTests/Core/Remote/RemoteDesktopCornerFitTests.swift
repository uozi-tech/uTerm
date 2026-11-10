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

    private static let builtIn = CGSize(width: 1512, height: 982)
    private static let external = CGSize(width: 2560, height: 1440)

    /// 一个几何场景：画布尺寸与它四个角的外圆角。
    private struct Scene {
        var name: String
        var content: CGSize
        var canvas: CGSize
        var corners: RemoteDesktopCornerRadii
    }

    /// 手机横竖屏铺满整屏（四角都是 55pt 屏幕圆角）、Duo 内屏一类顶栏下面的画布（只有下面两个角）、
    /// Mac 窗口（窗口按屏幕比例对好，底角 16pt）；内建屏（1512×982，带刘海）与 16:9 外接屏各一遍。
    private static func scenes() -> [Scene] {
        var scenes: [Scene] = []
        let phone = RemoteDesktopCornerRadii(all: 55)
        let bottomOnly = RemoteDesktopCornerRadii(bottomLeft: 55, bottomRight: 55)
        let window = RemoteDesktopCornerRadii(bottomLeft: 16, bottomRight: 16)
        for (tag, content) in [("builtin", builtIn), ("external", external)] {
            scenes.append(Scene(name: "phone-landscape-\(tag)", content: content, canvas: CGSize(width: 874, height: 402), corners: phone))
            scenes.append(Scene(name: "phone-portrait-\(tag)", content: content, canvas: CGSize(width: 402, height: 874), corners: phone))
            scenes.append(Scene(name: "duo-inner-\(tag)", content: content, canvas: CGSize(width: 1000, height: 660), corners: bottomOnly))
            // 窗口按 `fittedFrame` 对好：标题栏 36pt，画布扣掉窄边后正好是显示器比例。
            let frame = RemoteDesktopCanvasNSView.fittedFrame(
                window: CGRect(x: 0, y: 0, width: 1236, height: 836), canvas: CGSize(width: 1236, height: 800),
                display: content, visible: CGRect(x: 0, y: 0, width: 4000, height: 4000),
                margin: RemoteDesktopCanvasNSView.fittedMargin(corners: window))
            scenes.append(Scene(name: "mac-window-\(tag)", content: content,
                                canvas: CGSize(width: frame.width, height: frame.height - 36), corners: window))
        }
        return scenes
    }

    /// 「适配屏幕」与屏幕 / 窗口圆角同心：画面离四边留一样宽的窄边铺满（紧的那个方向正好是窄边），
    /// 画面的角切成同心圆角、整个落在外面的圆角以内；只有直角的画布照旧铺满不留边。
    func test_fit_fills_with_uniform_margin_and_concentric_corners() {
        let gap = RemoteDesktopCornerFit.gap
        for scene in Self.scenes() {
            let viewport = RemoteDesktopViewport(contentSize: scene.content, viewSize: scene.canvas, corners: scene.corners)
            let frame = viewport.contentFrame
            let label = scene.name
            let dx = frame.minX, dy = frame.minY
            // 居中、等比。
            XCTAssertEqual(frame.midX, scene.canvas.width / 2, accuracy: 1e-6, label)
            XCTAssertEqual(frame.midY, scene.canvas.height / 2, accuracy: 1e-6, label)
            XCTAssertEqual(frame.width / frame.height, scene.content.width / scene.content.height, accuracy: 1e-6, label)
            // 普通适配下角落进弧线的：四边至少留窄边，紧的那个方向正好是窄边（铺满，不再为直角多缩）。
            // 角本来就在弧线外的：照旧铺满，紧的那个方向贴边。
            let full = min(scene.canvas.width / scene.content.width, scene.canvas.height / scene.content.height)
            let fullDx = (scene.canvas.width - scene.content.width * full) / 2
            let fullDy = (scene.canvas.height - scene.content.height * full) / 2
            let needsMargin = !RemoteDesktopCornerFit.clears(dx: fullDx, dy: fullDy, radius: scene.corners.max)
            XCTAssertEqual(min(dx, dy), needsMargin ? gap : 0, accuracy: 1e-6, label)
            if !needsMargin { XCTAssertEqual(viewport.fitScale, full, accuracy: 1e-9, label) }
            print("[corner-fit] \(label): margin \(needsMargin ? gap : 0) dx \(dx) dy \(dy) "
                  + "radius \(viewport.pictureCorners.radius) scale \(viewport.fitScale) / full \(full)")
            // 画面的每个角都在外圆角以内（按圆弧逐点量）。
            let picture = viewport.pictureCorners
            XCTAssertTrue(Self.pictureInsideCanvas(frame: frame, picture: picture, canvas: scene.canvas, corners: scene.corners),
                          "\(label) 画面角出了外圆角")
            // 外圆角里有角时，画面的角是圆的；直角那几个角（Duo 顶栏下面的上沿、Mac 窗口上沿）画面也是直角。
            let distance = max(dx, dy)
            for (outer, cut) in [(scene.corners.topLeft, picture.topLeft), (scene.corners.topRight, picture.topRight),
                                 (scene.corners.bottomLeft, picture.bottomLeft), (scene.corners.bottomRight, picture.bottomRight)] {
                XCTAssertEqual(cut, outer - distance > 0.5, "\(label) 外圆角 \(outer) 离 \(distance)")
            }
            if picture.radius > 0 {
                XCTAssertEqual(picture.radius, scene.corners.max - distance, accuracy: 1e-6, label)
            }
        }
        // Mac 窗口对好比例后四边一样宽，画面圆角正好同心：16 − 8 = 8。
        let window = Self.scenes().first { $0.name == "mac-window-builtin" }!
        let viewport = RemoteDesktopViewport(contentSize: window.content, viewSize: window.canvas, corners: window.corners)
        XCTAssertEqual(viewport.contentFrame.minX, RemoteDesktopCornerFit.gap, accuracy: 0.5)
        XCTAssertEqual(viewport.contentFrame.minY, RemoteDesktopCornerFit.gap, accuracy: 0.5)
        XCTAssertEqual(viewport.pictureCorners.radius, 16 - RemoteDesktopCornerFit.gap, accuracy: 0.5)
        XCTAssertTrue(viewport.pictureCorners.bottomLeft && viewport.pictureCorners.bottomRight)
        XCTAssertFalse(viewport.pictureCorners.topLeft || viewport.pictureCorners.topRight)
        // 没有圆角就是原来的适配：铺满、不留边、直角。
        let plain = RemoteDesktopViewport(contentSize: Self.builtIn, viewSize: CGSize(width: 874, height: 402))
        XCTAssertEqual(plain.fitScale, 402.0 / 982.0, accuracy: 1e-9)
        XCTAssertTrue(plain.pictureCorners.isSquare)
        // 放大后可以铺进圆角，出了画布的角不切。
        var zoomed = RemoteDesktopViewport(contentSize: Self.builtIn, viewSize: CGSize(width: 874, height: 402),
                                           corners: RemoteDesktopCornerRadii(all: 55))
        zoomed.zoom(by: 2, anchor: CGPoint(x: 437, y: 201))
        XCTAssertLessThan(zoomed.contentFrame.minX, 0)
        XCTAssertTrue(zoomed.pictureCorners.isSquare)
    }

    /// 只在 86e1b171 那版也要缩的场景里让出窄边，且最多让出一圈窄边：比普通适配小不超过 2×gap。
    func test_concentric_fit_only_gives_up_the_margin() {
        for scene in Self.scenes() where scene.corners.max > 0 {
            let viewport = RemoteDesktopViewport(contentSize: scene.content, viewSize: scene.canvas, corners: scene.corners)
            let full = min(scene.canvas.width / scene.content.width, scene.canvas.height / scene.content.height)
            let old = Self.squareCornerScale(content: scene.content, view: scene.canvas, radius: scene.corners.max)
            let gap = RemoteDesktopCornerFit.gap
            let floor = full * min((scene.canvas.width - gap * 2) / scene.canvas.width,
                                   (scene.canvas.height - gap * 2) / scene.canvas.height)
            XCTAssertGreaterThanOrEqual(viewport.fitScale, floor - 1e-9, scene.name)
            if old >= full - 1e-9 { XCTAssertEqual(viewport.fitScale, full, accuracy: 1e-9, "\(scene.name) 本来不用缩") }
        }
    }

    /// Mac 窗口按屏幕比例对好时把窄边算进去：画布扣掉四边窄边后正好是显示器比例。
    func test_fitted_window_leaves_room_for_the_margin() {
        let fitted = RemoteDesktopCanvasNSView.fittedFrame(
            window: CGRect(x: 100, y: 100, width: 1280, height: 838), canvas: CGSize(width: 1280, height: 802),
            display: Self.builtIn, visible: CGRect(x: 0, y: 0, width: 3000, height: 3000), margin: 8)
        let canvasHeight = fitted.height - 36
        XCTAssertEqual((canvasHeight - 16) / (fitted.width - 16), Self.builtIn.height / Self.builtIn.width, accuracy: 0.002)
        XCTAssertEqual(fitted.maxY, 938, "上沿不动")
    }

    /// 画面圆角矩形是否整个在画布圆角矩形以内（圆弧模型）：沿画面四个角的弧线取点逐个量。
    private static func pictureInsideCanvas(frame: CGRect, picture: RemoteDesktopPictureCorners, canvas: CGSize,
                                            corners: RemoteDesktopCornerRadii) -> Bool {
        // 外圆角圆心：角在左上 → 圆心 (r, r)，依此类推；点落在圆心与角之间的那个方块里时，必须在圆内。
        let arcs = [(corners.topLeft, CGPoint(x: corners.topLeft, y: corners.topLeft), CGPoint(x: -1, y: -1)),
                    (corners.topRight, CGPoint(x: canvas.width - corners.topRight, y: corners.topRight), CGPoint(x: 1, y: -1)),
                    (corners.bottomLeft, CGPoint(x: corners.bottomLeft, y: canvas.height - corners.bottomLeft), CGPoint(x: -1, y: 1)),
                    (corners.bottomRight, CGPoint(x: canvas.width - corners.bottomRight, y: canvas.height - corners.bottomRight),
                     CGPoint(x: 1, y: 1))]
        func inside(_ p: CGPoint) -> Bool {
            let eps: CGFloat = 1e-6
            guard p.x >= -eps, p.y >= -eps, p.x <= canvas.width + eps, p.y <= canvas.height + eps else { return false }
            for (r, c, out) in arcs where r > 0 {
                let beyond = (p.x - c.x) * out.x > 0 && (p.y - c.y) * out.y > 0
                if beyond, hypot(p.x - c.x, p.y - c.y) > r + eps { return false }
            }
            return true
        }
        let cuts = [(picture.topLeft, CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: 1, y: 1)),
                    (picture.topRight, CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: -1, y: 1)),
                    (picture.bottomLeft, CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: 1, y: -1)),
                    (picture.bottomRight, CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: -1, y: -1))]
        for (cut, corner, toward) in cuts {
            let r = cut ? picture.radius : 0
            let center = CGPoint(x: corner.x + toward.x * r, y: corner.y + toward.y * r)
            for step in 0...32 {
                let angle = CGFloat(step) / 32 * .pi / 2
                let p = CGPoint(x: center.x - toward.x * r * cos(angle), y: center.y - toward.y * r * sin(angle))
                if !inside(p) { return false }
            }
        }
        return true
    }

    /// 86e1b171 的适配：等比居中，直角落在圆弧以内（连续曲率按放大 1.2 倍的圆弧算）。只给对照图和比较用。
    private static func squareCornerScale(content: CGSize, view: CGSize, radius: CGFloat) -> CGFloat {
        let full = min(view.width / content.width, view.height / content.height)
        func fits(_ s: CGFloat) -> Bool {
            let dx = (view.width - content.width * s) / 2, dy = (view.height - content.height * s) / 2
            let r = radius * 1.2 + 1
            if dx >= r || dy >= r { return true }
            return (r - dx) * (r - dx) + (r - dy) * (r - dy) <= r * r
        }
        guard radius > 0, !fits(full) else { return full }
        var low: CGFloat = 0, high = full
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
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

    /// 设置 `UTERM_REMOTE_SHOTS` 才画：每张图左边是改前（86e1b171：缩到直角落进圆弧以内），右边是改后
    ///（同心圆角 + 四边一样宽的窄边铺满）。画面用示意的 Mac 屏幕：顶上菜单栏（两头各一个标记）、
    /// 底下 Dock（两端各一个标记），标记被切就看得出来。
    func test_render_corner_fit_geometry() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_REMOTE_SHOTS"] ?? env["TEST_RUNNER_UTERM_REMOTE_SHOTS"], !raw.isEmpty else {
            throw XCTSkip("设置 UTERM_REMOTE_SHOTS=<目录> 才画几何对照图")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scene in Self.scenes() {
            // Duo 顶栏下面的画布上面还有 56pt 顶栏，Mac 窗口上面是 36pt 标题栏：外形画整块屏幕 / 窗口。
            let top: CGFloat = scene.name.hasPrefix("duo") ? 56 : scene.name.hasPrefix("mac") ? 36 : 0
            let outerRadius = scene.corners.max
            let png = try render(scene: scene, canvasTop: top, outerRadius: outerRadius)
            let name = "corner-fit-\(scene.name)"
            try png.write(to: dir.appendingPathComponent("\(name).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(name).png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        print("[remote-shots] dir=\(dir.path)")
    }

    private func render(scene: Scene, canvasTop: CGFloat, outerRadius: CGFloat) throws -> Data {
        let screen = CGSize(width: scene.canvas.width, height: scene.canvas.height + canvasTop)
        let gap: CGFloat = 40
        let size = CGSize(width: screen.width * 2 + gap * 3, height: screen.height + gap * 2 + 24)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                                 pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
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
        for index in 0..<2 {
            let origin = CGPoint(x: gap + CGFloat(index) * (screen.width + gap), y: gap + 24)
            let canvasOrigin = CGPoint(x: origin.x, y: origin.y + canvasTop)
            let label: String
            let frame: CGRect
            let picture: RemoteDesktopPictureCorners
            if index == 0 {
                let scale = Self.squareCornerScale(content: scene.content, view: scene.canvas, radius: scene.corners.max)
                let pictureSize = CGSize(width: scene.content.width * scale, height: scene.content.height * scale)
                frame = CGRect(x: (scene.canvas.width - pictureSize.width) / 2, y: (scene.canvas.height - pictureSize.height) / 2,
                               width: pictureSize.width, height: pictureSize.height)
                picture = .square
                label = "改前：直角缩进圆弧"
            } else {
                let viewport = RemoteDesktopViewport(contentSize: scene.content, viewSize: scene.canvas, corners: scene.corners)
                frame = viewport.contentFrame
                picture = viewport.pictureCorners
                label = "改后：同心 r=\(Int(picture.radius.rounded()))，边 \(Int(RemoteDesktopCornerFit.gap))"
            }
            (label as NSString).draw(at: CGPoint(x: origin.x, y: gap - 4),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
            cg.saveGState()
            // 屏幕 / 窗口的外形：圆角之外看不见。手机四角都圆；Duo 内屏与 Mac 窗口只有下面两个角落在画布上，
            // 但外形本身四角都圆。
            let outline = CGPath(roundedRect: CGRect(origin: origin, size: screen), cornerWidth: outerRadius,
                                 cornerHeight: outerRadius, transform: nil)
            cg.addPath(outline)
            cg.clip()
            cg.setFillColor(NSColor.black.cgColor)
            cg.fill(CGRect(origin: origin, size: screen))
            if canvasTop > 0 {
                cg.setFillColor(NSColor(white: 0.18, alpha: 1).cgColor)
                cg.fill(CGRect(origin: origin, size: CGSize(width: screen.width, height: canvasTop)))
            }
            let placed = frame.offsetBy(dx: canvasOrigin.x, dy: canvasOrigin.y)
            cg.saveGState()
            cg.addPath(Self.roundedPath(placed, picture))
            cg.clip()
            drawMacScreen(in: placed, cg: cg)
            cg.restoreGState()
            cg.restoreGState()
            cg.addPath(outline)
            cg.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
            cg.setLineWidth(2)
            cg.strokePath()
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// 只在 `picture` 选中的角上切圆角的路径（左上角原点坐标）。
    private static func roundedPath(_ rect: CGRect, _ picture: RemoteDesktopPictureCorners) -> CGPath {
        let path = CGMutablePath()
        let r = picture.isSquare ? 0 : picture.radius
        let tl = picture.topLeft ? r : 0, tr = picture.topRight ? r : 0
        let bl = picture.bottomLeft ? r : 0, br = picture.bottomRight ? r : 0
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
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
