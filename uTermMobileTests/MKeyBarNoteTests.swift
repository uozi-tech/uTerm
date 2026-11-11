import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 键盘条上方的提示（「正在发送图片…」）压在终端的字上面，底不能透。
///
/// 1090 实测：它的底只有一层白 8% / 黑 4% 的淡色，终端的字从下面透上来。这里把它摆在黑白相间的条纹上读像素：
/// 提示里面（避开文字的那一圈内边距）不管压着黑条还是白条，颜色都应当一样。
@MainActor
final class MKeyBarNoteTests: XCTestCase {
    override func tearDown() async throws {
        MobileProbeWindow.closeAll()
        try await super.tearDown()
    }

    private struct Stage: View {
        var body: some View {
            ZStack {
                // 竖条纹：每 8 pt 黑白交替，模拟提示下面的终端内容。
                HStack(spacing: 0) {
                    ForEach(0 ..< 30, id: \.self) { index in
                        (index.isMultiple(of: 2) ? Color.black : Color.white).frame(width: 8)
                    }
                }
                MKeyBarNote(text: "正在发送图片…")
                    .fixedSize()
            }
            .frame(width: 240, height: 80)
        }
    }

    private func check(_ style: UIUserInterfaceStyle) throws {
        let (window, host) = MobileProbeWindow.make(size: CGSize(width: 240, height: 80), rootView: Stage())
        defer { window.isHidden = true }
        window.overrideUserInterfaceStyle = style
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / 240
        func color(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let px = min(width - 1, Int(x * scale)), py = min(height - 1, Int(y * scale))
            let i = (py * width + px) * 4
            return [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
        }
        // 条纹本身确实黑白分明（夹具自检）：提示外面的一行。
        let outside = stride(from: CGFloat(4), to: 236, by: 8).map { color($0, 6) }
        XCTAssertGreaterThan(Set(outside.map { $0[0] / 128 }).count, 1, "条纹没画出来：\(outside.prefix(4))")
        // 提示里面：文字上方的内边距那一行（提示高约 30 pt，居中在 y=40；y=29 落在上内边距里），横跨好几条条纹。
        let inside = stride(from: CGFloat(84), through: 156, by: 4).map { color($0, 29) }
        let spread = (0 ..< 3).map { channel in
            (inside.map { $0[channel] }.max() ?? 0) - (inside.map { $0[channel] }.min() ?? 0)
        }.max() ?? 0
        XCTAssertLessThanOrEqual(spread, 2, "提示的底透出了下面的条纹（\(style == .dark ? "深色" : "浅色")）：\(inside)")
    }

    func testNoteBackgroundIsOpaqueInLightMode() throws {
        try check(.light)
    }

    func testNoteBackgroundIsOpaqueInDarkMode() throws {
        try check(.dark)
    }
}
