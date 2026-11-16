import CoreGraphics
import SwiftUI
import XCTest
@testable import uTerm

/// 手机上贴边铺满时，指针走进被屏幕圆角切掉的角，画面以对角为不动点缩小、把这个角整个露出来。
final class RemoteDesktopCornerPeekTests: XCTestCase {
    /// Duo 内屏横着、顶栏下面的画布，下面两个角落在 55pt 的屏幕圆角里（顶上两个被顶栏挡着）。
    private static let canvas = CGSize(width: 1000, height: 646.5)
    private static let radius: CGFloat = 55
    private static let corners = RemoteDesktopCornerRadii(bottomLeft: radius, bottomRight: radius)
    private static var clearance: CGFloat { (radius * RemoteDesktopViewport.cornerClearance).rounded(.up) }

    private func viewport(bleeds: Bool = true) -> RemoteDesktopViewport {
        RemoteDesktopViewport(contentSize: Self.canvas, viewSize: Self.canvas, corners: Self.corners,
                              bleedsIntoCorners: bleeds)
    }

    /// 归一化指针：离左 / 右边、离下边各多少视图点。
    private func pointer(fromLeft x: CGFloat? = nil, fromRight: CGFloat? = nil, fromBottom y: CGFloat) -> CGPoint {
        let vx = x ?? (Self.canvas.width - (fromRight ?? 0))
        return CGPoint(x: vx / Self.canvas.width, y: (Self.canvas.height - y) / Self.canvas.height)
    }

    private func peeked(_ pointer: CGPoint) -> RemoteDesktopViewport {
        var v = viewport()
        v.peekInsets = v.cornerPeek(for: pointer)
        return v
    }

    func test_bottom_left_shrinks_toward_the_top_right_corner() {
        let v = peeked(pointer(fromLeft: 10, fromBottom: 10))
        let base = v.contentFrame, shown = v.displayedFrame
        // 右上角不动：Mac 的菜单栏和右边都还在原处。
        XCTAssertEqual(shown.minY, base.minY, accuracy: 0.01)
        XCTAssertEqual(shown.maxX, base.maxX, accuracy: 0.01)
        // 下边退一个余量，左边按宽高比退得更多。
        XCTAssertEqual(base.maxY - shown.maxY, Self.clearance, accuracy: 0.01)
        XCTAssertEqual(shown.minX - base.minX, Self.clearance * Self.canvas.width / Self.canvas.height, accuracy: 0.01)
        // 等比缩小，不变形。
        XCTAssertEqual(shown.width / shown.height, base.width / base.height, accuracy: 0.0001)
    }

    func test_bottom_right_shrinks_toward_the_top_left_corner() {
        let v = peeked(pointer(fromRight: 10, fromBottom: 10))
        let base = v.contentFrame, shown = v.displayedFrame
        XCTAssertEqual(shown.minY, base.minY, accuracy: 0.01)
        XCTAssertEqual(shown.minX, base.minX, accuracy: 0.01)
        XCTAssertEqual(base.maxY - shown.maxY, Self.clearance, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(base.maxX - shown.maxX, Self.clearance)
        XCTAssertEqual(shown.width / shown.height, base.width / base.height, accuracy: 0.0001)
    }

    func test_dock_ends_are_inside_the_zone() {
        let v = viewport()
        // 程序坞最左边的访达（离左边约 40pt、离下边约 15pt）、最右边的废纸篓。
        XCTAssertNotEqual(v.cornerPeek(for: pointer(fromLeft: 40, fromBottom: 15)), .zero)
        XCTAssertNotEqual(v.cornerPeek(for: pointer(fromRight: 40, fromBottom: 15)), .zero)
    }

    func test_pointer_away_from_the_corners_does_not_shrink_the_picture() {
        let v = viewport()
        XCTAssertEqual(v.cornerPeek(for: CGPoint(x: 0.5, y: 0.5)), .zero)
        // 程序坞中间、左边中间：贴着一条边，但不在角上。
        XCTAssertEqual(v.cornerPeek(for: pointer(fromLeft: 500, fromBottom: 5)), .zero)
        XCTAssertEqual(v.cornerPeek(for: pointer(fromLeft: 5, fromBottom: 300)), .zero)
        // 顶上两个角不在屏幕圆角里（半径 0）。
        XCTAssertEqual(v.cornerPeek(for: CGPoint(x: 0, y: 0)), .zero)
        XCTAssertEqual(v.cornerPeek(for: CGPoint(x: 1, y: 0)), .zero)
    }

    func test_zone_reaches_one_and_a_half_radii_along_each_edge() {
        let v = viewport()
        let edge = Self.radius * RemoteDesktopViewport.cornerZone
        XCTAssertNotEqual(v.cornerPeek(for: pointer(fromLeft: edge - 1, fromBottom: edge - 1)), .zero)
        XCTAssertEqual(v.cornerPeek(for: pointer(fromLeft: edge + 1, fromBottom: 5)), .zero)
        XCTAssertEqual(v.cornerPeek(for: pointer(fromLeft: 5, fromBottom: edge + 1)), .zero)
    }

    /// 让开之后画面的角落在屏幕圆角里面：用系统的连续曲线圆角（iOS 屏幕圆角的形状）核。
    func test_shrunk_picture_corner_is_inside_the_continuous_screen_corner() {
        let screen = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .path(in: CGRect(origin: .zero, size: Self.canvas))
        let base = viewport().contentFrame
        XCTAssertFalse(screen.contains(CGPoint(x: base.minX + 0.5, y: base.maxY - 0.5)), "不让开的话角被切掉")

        for (v, left) in [(peeked(pointer(fromLeft: 10, fromBottom: 10)), true),
                          (peeked(pointer(fromRight: 10, fromBottom: 10)), false)] {
            let shown = v.displayedFrame
            let cornerX = left ? shown.minX + 0.5 : shown.maxX - 0.5
            XCTAssertTrue(screen.contains(CGPoint(x: cornerX, y: shown.maxY - 0.5)), left ? "左下" : "右下")
            // 底边、侧边贴着角的那一段也都露出来了。
            for t in stride(from: CGFloat(1), through: Self.radius * 1.5, by: 2) {
                let x = left ? shown.minX + t : shown.maxX - t
                let sideX = left ? shown.minX + 0.5 : shown.maxX - 0.5
                XCTAssertTrue(screen.contains(CGPoint(x: x, y: shown.maxY - 0.5)), "底边 \(t)")
                XCTAssertTrue(screen.contains(CGPoint(x: sideX, y: shown.maxY - t)), "侧边 \(t)")
            }
        }
    }

    func test_peek_only_changes_the_drawn_picture_not_the_pointer_mapping() {
        let plain = viewport()
        let v = peeked(pointer(fromLeft: 10, fromBottom: 10))
        XCTAssertEqual(v.contentFrame, plain.contentFrame)
        XCTAssertNotEqual(v.displayedFrame, plain.contentFrame)
        XCTAssertEqual(v.normalized(viewPoint: CGPoint(x: 100, y: 100)), plain.normalized(viewPoint: CGPoint(x: 100, y: 100)))
    }

    func test_mac_window_keeps_its_margin_and_never_peeks() {
        let v = viewport(bleeds: false)
        XCTAssertEqual(v.cornerPeek(for: pointer(fromLeft: 5, fromBottom: 5)), .zero)
    }

    func test_zoomed_in_peeks_only_once_panned_to_that_corner() {
        var v = viewport()
        v.setZoom(2)
        // 放大后居中：画面的边不贴视图边，角不在屏幕圆角里。
        XCTAssertEqual(v.cornerPeek(for: CGPoint(x: 0.3, y: 0.7)), .zero)
        // 拖到左下角：画面的左边、下边贴着视图边。
        v.pan(by: CGSize(width: 10_000, height: -10_000))
        let frame = v.contentFrame
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, Self.canvas.height, accuracy: 0.5)
        v.peekInsets = v.cornerPeek(for: CGPoint(x: 0.005, y: 0.995))
        // 视图里的那个角照样退开一个余量（不动点是视图的右上角）。
        XCTAssertEqual(v.displayedFrame.minX, Self.clearance * Self.canvas.width / Self.canvas.height, accuracy: 0.01)
        XCTAssertEqual(Self.canvas.height - v.displayedFrame.maxY, Self.clearance, accuracy: 0.01)
    }

    func test_step_eases_toward_the_target_and_settles_exactly() {
        var v = viewport()
        let target = v.cornerPeek(for: pointer(fromLeft: 10, fromBottom: 10))
        var frames = 0
        while v.stepPeek(toward: target, duration: 1.0 / 120) { frames += 1 }
        XCTAssertEqual(v.peekInsets, target)
        // 120 Hz 下约 0.3～0.4 秒走完（左边退约 26pt）。
        XCTAssertTrue((20...50).contains(frames), "\(frames) 帧")
        XCTAssertFalse(v.stepPeek(toward: target, duration: 1.0 / 120))
        // 第一帧就有明显的变化，不是等一会儿才动。
        var back = v
        XCTAssertTrue(back.stepPeek(toward: .zero, duration: 1.0 / 120))
        XCTAssertLessThan(back.peekInsets.bottom, target.bottom * 0.95)
    }
}
