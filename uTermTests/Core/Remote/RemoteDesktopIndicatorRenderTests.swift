import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 远程桌面指示条（屏幕顶部那条「×× 正在控制这台 Mac」）的阴影要在面板里淡完。
///
/// 面板按内容大小定、本身透明无窗口阴影，阴影是 SwiftUI 画在内容里的。四周留白不够时，阴影会在
/// 窗口边上被齐刷刷截断，看上去是胶囊外面套了个灰色矩形。这里把视图按面板的大小渲染出来，
/// 量最外一圈像素的不透明度。
@MainActor
final class RemoteDesktopIndicatorRenderTests: XCTestCase {

    func test_shadow_fades_out_before_the_panel_edge() throws {
        let viewer = RemoteHostServer.DesktopViewer(connection: UUID(), channel: 1, deviceName: "iPhone",
                                                    canControl: true, isControlling: true)
        let host = NSHostingView(rootView: RemoteDesktopIndicatorView(viewer: viewer, onDisconnect: {}))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: host.frame, styleMask: [.borderless], contentView: host,
                                      key: false, placement: .offScreen)
        defer { window.orderOut(nil) }
        window.isOpaque = false
        window.backgroundColor = .clear
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var edge: CGFloat = 0
        var center: CGFloat = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if x == 0 || y == 0 || x == rep.pixelsWide - 1 || y == rep.pixelsHigh - 1 { edge = max(edge, alpha) }
                if y == rep.pixelsHigh / 2 { center = max(center, alpha) }
            }
        }
        XCTAssertEqual(center, 1, accuracy: 0.01, "胶囊本身是不透明的：没渲染出来的话边缘的读数没有意义")
        XCTAssertLessThan(edge, 2.0 / 255, "面板最外一圈还有阴影（不透明度 \(edge)），说明阴影被窗口边截断了")
    }
}
