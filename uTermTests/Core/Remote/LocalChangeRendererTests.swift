import CoreVideo
import XCTest
@testable import uTerm

/// 弱网矩阵的局部变化画面自证：每档只在自己那块变、变化量在预期的量级，滚动循环无缝。
final class LocalChangeRendererTests: XCTestCase {
    private let width = 1206
    private let height = 782

    /// 两帧亮度平面不同的像素：比例与外接矩形。
    private func diff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (fraction: Double, box: CGRect?) {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
        }
        let strideA = CVPixelBufferGetBytesPerRowOfPlane(a, 0), strideB = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        let lumaA = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaB = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        var changed = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where lumaA[y * strideA + x] != lumaB[y * strideB + x] {
                changed += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let box = changed == 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (Double(changed) / Double(width * height), box)
    }

    func test_typing_changes_one_glyph_and_the_cursor_per_frame() {
        let renderer = LocalChangeRenderer(content: .typing, width: width, height: height)
        let a = renderer.frame(10), b = renderer.frame(11)
        let (fraction, box) = diff(a, b)
        XCTAssertGreaterThan(fraction, 0)
        XCTAssertLessThan(fraction, 0.001, "打字每帧只变一个字加光标")
        XCTAssertLessThan(box?.width ?? .infinity, 30)
    }

    func test_scroll_stays_inside_the_pane_and_loops_seamlessly() {
        let renderer = LocalChangeRenderer(content: .scroll, width: width, height: height)
        let (fraction, box) = diff(renderer.frame(0), renderer.frame(1))
        // 深底稀疏文字：上滚 2 px 只有字的边缘变，像素比例不高，但变化铺满整个窗格。
        XCTAssertGreaterThan(fraction, 0.02)
        XCTAssertLessThan(fraction, 0.45)
        XCTAssertGreaterThan(box?.height ?? 0, 0.6 * Double(height), "整个窗格都在动")
        let pane = CGRect(x: 0.11 * Double(width), y: 0.11 * Double(height), width: 0.57 * Double(width),
                          height: 0.72 * Double(height))
        XCTAssertTrue(box.map { pane.contains($0) } ?? false, "变化只在窗格里：\(String(describing: box))")
        XCTAssertEqual(diff(renderer.frame(0), renderer.frame(60)).fraction, 0, "滚完一个周期回到原样")
    }

    func test_small_area_changes_only_its_corner() {
        let renderer = LocalChangeRenderer(content: .smallArea, width: width, height: height)
        let (fraction, box) = diff(renderer.frame(3), renderer.frame(4))
        XCTAssertGreaterThan(fraction, 0.01)
        XCTAssertLessThan(fraction, 0.05)
        let corner = CGRect(x: 0.71 * Double(width), y: 0.07 * Double(height), width: 0.22 * Double(width),
                            height: 0.22 * Double(height))
        XCTAssertTrue(box.map { corner.contains($0) } ?? false, "变化只在角落：\(String(describing: box))")
    }
}
