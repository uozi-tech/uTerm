import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 底部面板的背板遮罩要铺满整屏，包括顶部状态栏那一条（真机反馈：iPhone 与 Duo 上状态栏一条还是亮的）。
///
/// 判据是像素：白底页面上弹出面板，截图后比较状态栏区域与页面中部（面板上方）的亮度——
/// 两处都应被同一层遮罩压暗。只看遮罩视图的 frame 不够：`ignoresSafeArea` 是否真生效要看画出来的结果。
@MainActor
final class MBottomPanelScrimTests: XCTestCase {
    private struct Token: Identifiable { let id = 1 }

    private struct Harness: View {
        @State private var item: Token?

        var body: some View {
            Color.white
                .ignoresSafeArea()
                .mBottomPanel(item: $item) { _ in
                    Text(verbatim: "panel").frame(height: 120)
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(300))
                    item = Token()
                }
        }
    }

    func testScrimCoversStatusBarArea() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (window, _) = MobileProbeWindow.make(placement: .visibleOnScreen, isolateHost: true,
                                                 rootView: Harness())
        let controller = try XCTUnwrap(window.rootViewController)
        var presented: UIViewController?
        for _ in 0..<50 where presented == nil {
            try await Task.sleep(for: .milliseconds(100))
            presented = controller.presentedViewController
        }
        let cover = try XCTUnwrap(presented, "面板没有弹出来")
        defer { cover.dismiss(animated: false) }
        // 等卡片滑入、遮罩淡入的弹簧动画收尾。
        try await Task.sleep(for: .milliseconds(900))

        let topInset = cover.view.safeAreaInsets.top
        guard topInset > 0 else { throw XCTSkip("当前模拟器顶部没有安全区，量不出状态栏那一条") }

        let size = window.bounds.size
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let statusBar = try XCTUnwrap(luminance(of: image, at: CGPoint(x: size.width * 0.25, y: topInset / 2)))
        let page = try XCTUnwrap(luminance(of: image, at: CGPoint(x: size.width * 0.25, y: size.height * 0.2)))
        print("SCRIM topInset=\(topInset) statusBar=\(statusBar) page=\(page)")

        let expected = 255 * (1 - MBottomPanelMetrics.scrimOpacity)
        XCTAssertEqual(page, expected, accuracy: 12, "面板上方的页面没被遮罩压暗")
        XCTAssertEqual(statusBar, page, accuracy: 6, "状态栏区域没被遮罩盖住（顶部安全区 \(topInset)pt）")
    }

    /// 某一点的平均亮度（0…255）。
    private func luminance(of image: UIImage, at point: CGPoint) -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let x = Int(point.x * CGFloat(cgImage.width) / image.size.width)
        let y = Int(point.y * CGFloat(cgImage.height) / image.size.height)
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3
    }
}
