import CoreGraphics
import SwiftUI
import XCTest
@testable import uTerm

/// 手机上贴边铺满时，指针走进被屏幕圆角切掉的角，画面朝里滑开、把角整个露出来。
final class RemoteDesktopCornerPeekTests: XCTestCase {
    /// Duo 内屏横着、顶栏下面的画布，下面两个角落在 55pt 的屏幕圆角里（顶上两个被顶栏挡着）。
    private static let canvas = CGSize(width: 1000, height: 646.5)
    private static let radius: CGFloat = 55
    private static let corners = RemoteDesktopCornerRadii(bottomLeft: radius, bottomRight: radius)

    private func viewport(bleeds: Bool = true) -> RemoteDesktopViewport {
        RemoteDesktopViewport(contentSize: Self.canvas, viewSize: Self.canvas, corners: Self.corners,
                              bleedsIntoCorners: bleeds)
    }

    /// 归一化指针：离左 / 右边、离下边各多少视图点。
    private func pointer(fromLeft x: CGFloat? = nil, fromRight: CGFloat? = nil, fromBottom y: CGFloat) -> CGPoint {
        let vx = x ?? (Self.canvas.width - (fromRight ?? 0))
        return CGPoint(x: vx / Self.canvas.width, y: (Self.canvas.height - y) / Self.canvas.height)
    }

    func test_pointer_in_a_bottom_corner_slides_the_picture_diagonally_inward() {
        let v = viewport()
        let shift = (Self.radius * RemoteDesktopViewport.cornerClearance).rounded(.up)
        XCTAssertEqual(v.cornerPeek(for: pointer(fromLeft: 10, fromBottom: 10)), CGSize(width: shift, height: -shift))
        XCTAssertEqual(v.cornerPeek(for: pointer(fromRight: 10, fromBottom: 10)), CGSize(width: -shift, height: -shift))
        // 程序坞最左边的访达（离左边约 40pt、离下边约 15pt）也在区域里。
        XCTAssertEqual(v.cornerPeek(for: pointer(fromLeft: 40, fromBottom: 15)), CGSize(width: shift, height: -shift))
    }

    func test_pointer_away_from_the_corners_does_not_move_the_picture() {
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

    /// 挪过之后画面的角落在屏幕圆角里面：用系统的连续曲线圆角（iOS 屏幕圆角的形状）核。
    func test_peeked_picture_corner_is_inside_the_continuous_screen_corner() {
        var v = viewport()
        let screen = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .path(in: CGRect(origin: .zero, size: CGSize(width: Self.canvas.width, height: Self.canvas.height)))
        let frame = v.contentFrame
        let corner = CGPoint(x: frame.minX + 0.5, y: frame.maxY - 0.5)
        XCTAssertFalse(screen.contains(corner), "不挪的话角被切掉")

        v.peekOffset = v.cornerPeek(for: pointer(fromLeft: 10, fromBottom: 10))
        let shown = v.displayedFrame
        XCTAssertTrue(screen.contains(CGPoint(x: shown.minX + 0.5, y: shown.maxY - 0.5)))
        // 底边、左边贴着角的那一段也都露出来了。
        for t in stride(from: CGFloat(1), through: Self.radius * 1.5, by: 2) {
            XCTAssertTrue(screen.contains(CGPoint(x: shown.minX + t, y: shown.maxY - 0.5)), "底边 \(t)")
            XCTAssertTrue(screen.contains(CGPoint(x: shown.minX + 0.5, y: shown.maxY - t)), "左边 \(t)")
        }
    }

    func test_peek_only_moves_the_drawn_picture_not_the_pointer_mapping() {
        var v = viewport()
        let before = v.contentFrame
        v.peekOffset = CGSize(width: 17, height: -17)
        XCTAssertEqual(v.contentFrame, before)
        XCTAssertEqual(v.displayedFrame, before.offsetBy(dx: 17, dy: -17))
        XCTAssertEqual(v.normalized(viewPoint: CGPoint(x: 100, y: 100)),
                       RemoteDesktopViewport(contentSize: Self.canvas, viewSize: Self.canvas, corners: Self.corners,
                                             bleedsIntoCorners: true).normalized(viewPoint: CGPoint(x: 100, y: 100)))
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
        XCTAssertNotEqual(v.cornerPeek(for: CGPoint(x: 0.005, y: 0.995)), .zero)
    }

    func test_step_eases_toward_the_target_and_settles_exactly() {
        var v = viewport()
        let target = CGSize(width: 17, height: -17)
        var frames = 0
        while v.stepPeek(toward: target, duration: 1.0 / 120) { frames += 1 }
        XCTAssertEqual(v.peekOffset, target)
        // 120 Hz 下约 0.25～0.35 秒走完。
        XCTAssertTrue((20...45).contains(frames), "\(frames) 帧")
        XCTAssertFalse(v.stepPeek(toward: target, duration: 1.0 / 120))
        // 第一帧就有明显的位移，不是等一会儿才动。
        var back = v
        XCTAssertTrue(back.stepPeek(toward: .zero, duration: 1.0 / 120))
        XCTAssertLessThan(back.peekOffset.width, 17 * 0.95)
    }
}
