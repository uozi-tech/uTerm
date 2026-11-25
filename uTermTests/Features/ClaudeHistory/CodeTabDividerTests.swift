import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// Code 标签页侧栏与右边之间那条可拖分隔线（`ColumnResizer`）。右边是跑着的会话：顶上一行标题（不带底色），
/// 下面是终端（Ghostty 的 NSView，从分隔线右边紧挨着开始）。
///
/// 实测（2026-11-25）：悬停时线加粗到 3pt，但只有标题那一行是 3pt；往下终端的 NSView 盖住了右边那 1pt，
/// 线变成 2pt、右缘往左缩 1pt，在标题行底下错一个台阶。真窗口里摆好，读像素判定。
///
/// 悬停态用 `ColumnResizer.catalogHot` 点亮：合成鼠标事件在这个窗口里点 SwiftUI 的悬停时灵时不灵
/// （同一串事件，有的轮次亮、有的轮次一次 `onHover` 都不来），拿它当前提的用例会时红时绿。
@MainActor
final class CodeTabDividerTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var cleanups: [@MainActor () async -> Void] = []

    override func tearDown() async throws {
        ColumnResizer.catalogHot = nil
        for c in cleanups { await c() }
        cleanups.removeAll()
        for w in windows { w.contentView = NSView(); w.orderOut(nil) }
        windows.removeAll()
        NSApp.appearance = nil
        try await super.tearDown()
    }

    /// SSH 终端窗口里的 Code 标签页，右边是跑着的会话的终端（画廊同款夹具，假后端，不连主机）。
    /// 返回整窗的一帧与终端容器在宿主里的位置（宿主是 flipped 的）。`hot`：分隔线按悬停 / 拖动时画。
    private func render(hot: Bool, size: CGSize = CGSize(width: 1180, height: 740)) async throws -> (Shot, NSRect) {
        ColumnResizer.catalogHot = hot
        NSApp.appearance = NSAppearance(named: .aqua)
        let render = try await UICatalog.codeTabRender(UICatalogStage(),
                                                       .init(running: ["c-login", "x-tests"], showsRun: "c-login"))
        let host = NSHostingView(rootView: AnyView(render.view.environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: host.frame,
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      contentView: host,
                                      placement: .transparentOnScreen,
                                      keepsDrawing: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        windows.append(window)
        if let cleanup = render.cleanup { cleanups.append(cleanup) }
        await UICatalogRenderer.settle(host, limit: .milliseconds(1500))
        if let after = render.after { await after(host); await UICatalogRenderer.settle(host, limit: .milliseconds(1500)) }
        await UICatalogRenderer.waitForTerminalFrames(in: host)
        let surface = try XCTUnwrap(UICatalogRenderer.terminalViews(in: host).first, "右边应当是终端")
        let container = try XCTUnwrap(surface.superview)
        let shot = try XCTUnwrap(snapshot(host))
        attach(shot, hot ? "code-tab-divider-hot.png" : "code-tab-divider-rest.png")
        return (shot, container.convert(container.bounds, to: host))
    }

    // MARK: 像素

    private struct Shot {
        let rep: NSBitmapImageRep
        let png: Data
        func color(x: Int, y: Int) -> UInt32 {
            let scale = CGFloat(rep.pixelsWide) / rep.size.width
            let c = rep.colorAt(x: Int(CGFloat(x) * scale) + 1, y: Int(CGFloat(y) * scale) + 1)!.usingColorSpace(.sRGB)!
            return UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
        }
        /// accent 蓝（浅色主题 #168EFF 一类）：蓝远大于红。
        func isAccent(x: Int, y: Int) -> Bool {
            let c = color(x: x, y: y)
            return Int(c & 0xFF) - Int(c >> 16) > 120
        }
        /// 这一行里 accent 的列（pt）。
        func accentColumns(y: Int, around x: Int) -> [Int] {
            (x - 6...x + 6).filter { isAccent(x: $0, y: y) }
        }
    }

    private func snapshot(_ host: NSView) -> Shot? {
        guard let png = UICatalogRenderer.snapshot(host, overlays: [], windowCorners: false),
              let rep = NSBitmapImageRep(data: png) else { return nil }
        return Shot(rep: rep, png: png)
    }

    private func attach(_ shot: Shot, _ name: String) {
        let a = XCTAttachment(data: shot.png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: 用例

    /// 悬停时那条 3pt 的 accent 线从上到下一样宽、在同一位置：标题行与终端旁边不错台阶，两端与静息时的 1pt 线齐。
    func testHotLineIsUniformFromHeaderToBottom() async throws {
        // 静息：终端左边那几列里唯一一列不是卡面色的就是分隔线，顺着它量出上下两端。
        let (rest, terminal) = try await render(hot: false)
        let probeY = Int(terminal.midY)
        let card = rest.color(x: Int(terminal.minX) + 2, y: probeY)
        let x = try XCTUnwrap((Int(terminal.minX) - 6..<Int(terminal.minX)).last { rest.color(x: $0, y: probeY) != card },
                              "终端左边没找到分隔线")
        let line = rest.color(x: x, y: probeY)
        var top = probeY, bottom = probeY
        while rest.color(x: x, y: top - 1) == line { top -= 1 }
        while rest.color(x: x, y: bottom + 1) == line { bottom += 1 }

        let (hot, _) = try await render(hot: true)
        let headerY = (top + Int(terminal.minY)) / 2
        let header = hot.accentColumns(y: headerY, around: x)
        print("[divider] x=\(x) top=\(top) bottom=\(bottom) terminal=\(terminal) header(y=\(headerY))=\(header)")
        XCTAssertEqual(header, [x - 1, x, x + 1],
                       "标题行旁边的 accent 线应当以静息的线为中线、宽 \(PaneDividerLine.hotThickness)pt")
        for y in [Int(terminal.minY) - 1, Int(terminal.minY) + 1, Int(terminal.midY), bottom - 1] {
            let row = hot.accentColumns(y: y, around: x)
            print("[divider] y=\(y) accent=\(row)")
            XCTAssertEqual(row, header, "y=\(y) 处的 accent 线和标题行旁边的不一样（被右边的终端 / 标题行底线盖住了一截）")
        }
        XCTAssertTrue(hot.isAccent(x: x, y: top) && hot.isAccent(x: x, y: bottom),
                      "accent 线应当和静息时的线一样从 y=\(top) 通到 y=\(bottom)")
        XCTAssertFalse(hot.isAccent(x: x, y: top - 1) || hot.isAccent(x: x, y: bottom + 1),
                       "accent 线不该伸出静息时的线的两端")
    }
}
