import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 底部安全区（Home 条那一截）不再整段空着（实机反馈：Duo 横握时 Code 标签页键盘条下面、会话列表下面
/// 各空出 34pt 一条）。
///
/// - 键盘条只在键帽下面留出够 Home 条用的一点，其余还给正文；
/// - 竖向列表照常滚进底部安全区（系统列表的样子），侧边那一列（Duo 的状态栏列）仍然裁掉。
@MainActor
final class MBottomSafeAreaTests: XCTestCase {
    /// 键盘条最下面那一行的下沿离窗口底边多远。
    private final class Probe {
        var rowFrame: CGRect = .zero
    }

    private struct KeyBarHarness: View {
        let probe: Probe

        var body: some View {
            VStack(spacing: 0) {
                Color.blue
                MKeyBar(panel: .constant(Int?.none), softKeyboardUp: .constant(false)) {
                    Color.red
                        .frame(width: MKeyCapMetrics.minWidth,
                               height: MKeyCapMetrics.height + 2 * MKeyCapMetrics.verticalHitInset)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.rowFrame = $0 }
                } row: {
                    Color.green.frame(width: 40, height: MKeyCapMetrics.height)
                } trailing: {
                    Color.green.frame(width: 40, height: MKeyCapMetrics.height)
                } content: { _ in
                    EmptyView()
                }
            }
        }
    }

    private func keyBarBottomGap(bottomInset: CGFloat) async throws -> CGFloat {
        defer { MobileProbeWindow.closeAll() }
        let probe = Probe()
        let size = CGSize(width: 600, height: 400)
        let (window, hosting) = MobileProbeWindow.make(size: size, placement: .visibleOnScreen, isolateHost: true,
                                                       rootView: KeyBarHarness(probe: probe))
        hosting.safeAreaRegions = .container
        hosting.additionalSafeAreaInsets.bottom = bottomInset - window.safeAreaInsets.bottom
        hosting.view.setNeedsLayout()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(hosting.view.safeAreaInsets.bottom, bottomInset, accuracy: 0.5, "没设上底部安全区")
        XCTAssertGreaterThan(probe.rowFrame.height, 0, "没量到键盘条")
        return size.height - probe.rowFrame.maxY
    }

    func testKeyBarReclaimsMostOfTheHomeIndicatorInset() async throws {
        let gap = try await keyBarBottomGap(bottomInset: 34)
        XCTAssertEqual(gap, MKeyBarBottomInset.kept, accuracy: 0.5,
                       "键盘条下面只留 \(MKeyBarBottomInset.kept)pt，实际 \(gap)pt")
    }

    func testKeyBarKeepsTheSmallerInsetAsIs() async throws {
        let gap = try await keyBarBottomGap(bottomInset: 6)
        XCTAssertEqual(gap, 6, accuracy: 0.5, "安全区比要留的还小时照安全区留")
    }

    func testReclaimRule() {
        func reclaimed(_ bottom: CGFloat, container: CGFloat? = nil) -> CGFloat {
            MKeyBarBottomInset.reclaimed(safeAreaBottom: bottom, containerBottom: container ?? bottom)
        }
        XCTAssertEqual(reclaimed(0), 0)
        XCTAssertEqual(reclaimed(34), 34 - MKeyBarBottomInset.kept)
        XCTAssertEqual(reclaimed(21), 21 - MKeyBarBottomInset.kept)
        XCTAssertEqual(reclaimed(4), 0)
        XCTAssertEqual(reclaimed(336, container: 34), 0, "软键盘弹着：不往键盘里伸")
        XCTAssertEqual(reclaimed(55, container: 34), 0, "外接键盘的快捷栏在下面：同样不伸")
    }

    // MARK: - 竖向列表

    private struct ListHarness: View {
        var body: some View {
            ZStack {
                Color.white.ignoresSafeArea()
                ScrollView {
                    Color.red.frame(height: 3000)
                }
                .mKeepsScrollContentInSafeArea()
            }
        }
    }

    func testVerticalListScrollsIntoBottomInsetButStaysOutOfSideColumn() async throws {
        defer { MobileProbeWindow.closeAll() }
        let size = CGSize(width: 600, height: 400)
        let (window, hosting) = MobileProbeWindow.make(size: size, placement: .visibleOnScreen, isolateHost: true,
                                                       rootView: ListHarness())
        hosting.safeAreaRegions = .container
        hosting.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0,
                                                        bottom: 34 - window.safeAreaInsets.bottom,
                                                        right: 60 - window.safeAreaInsets.right)
        hosting.view.setNeedsLayout()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let insets = hosting.view.safeAreaInsets
        XCTAssertEqual(insets.bottom, 34, accuracy: 0.5)
        XCTAssertEqual(insets.right, 60, accuracy: 0.5)

        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let homeStrip = try XCTUnwrap(redness(of: image, at: CGPoint(x: size.width / 3, y: size.height - 17)))
        let sideColumn = try XCTUnwrap(redness(of: image, at: CGPoint(x: size.width - 30, y: size.height / 2)))
        let body = try XCTUnwrap(redness(of: image, at: CGPoint(x: size.width / 3, y: size.height / 2)))
        XCTAssertTrue(body, "正文里该是列表内容")
        XCTAssertTrue(homeStrip, "列表内容该滚进底部安全区，不是空一条")
        XCTAssertFalse(sideColumn, "侧边那一列（Duo 的状态栏列）仍要裁掉")
    }

    /// 这一点是不是红的（列表内容）。
    private func redness(of image: UIImage, at point: CGPoint) -> Bool? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let x = Int(point.x * CGFloat(cgImage.width) / image.size.width)
        let y = Int(point.y * CGFloat(cgImage.height) / image.size.height)
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return pixel[0] > 200 && pixel[1] < 80 && pixel[2] < 80
    }
}
