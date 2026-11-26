import CoreGraphics
import XCTest
@testable import uTerm

/// 手机键盘的触控板（长按空格键滑动）：位移换成方向键或指针移动。
final class RemoteKeyboardTrackpadTests: XCTestCase {
    private let left = RemoteKeyMap.Key.left, right = RemoteKeyMap.Key.right
    private let up = RemoteKeyMap.Key.up, down = RemoteKeyMap.Key.down

    /// 从原点沿一串位移一路滑过去，收集全部方向键。
    private func arrows(_ steps: [CGSize]) -> [UInt16] {
        var trackpad = RemoteKeyboardTrackpad(at: .zero, time: 0)
        var point = CGPoint.zero
        var codes: [UInt16] = []
        for step in steps {
            point.x += step.width
            point.y += step.height
            codes += trackpad.arrows(to: point)
        }
        return codes
    }

    private func repeated(_ step: CGSize, _ count: Int) -> [CGSize] { Array(repeating: step, count: count) }

    func testHorizontalDragPressesOneArrowPerColumn() {
        let step = RemoteKeyboardTrackpad.columnStep
        XCTAssertEqual(arrows([CGSize(width: step * 3, height: 0)]), [right, right, right])
        XCTAssertEqual(arrows([CGSize(width: -step * 2, height: 0)]), [left, left])
    }

    func testSmallMovesAccumulateInsteadOfBeingDropped() {
        // 每帧只挪 1 点：攒满一格才按，攒的余数不丢。
        let codes = arrows(repeated(CGSize(width: 1, height: 0), Int(RemoteKeyboardTrackpad.columnStep * 4)))
        XCTAssertEqual(codes, Array(repeating: right, count: 4))
    }

    func testBelowOneColumnPressesNothing() {
        XCTAssertEqual(arrows([CGSize(width: RemoteKeyboardTrackpad.columnStep - 0.5, height: 0)]), [])
    }

    func testDraggingBackUndoesWhatWasPressed() {
        let step = RemoteKeyboardTrackpad.columnStep
        let codes = arrows(repeated(CGSize(width: 1, height: 0), Int(step * 2)) + repeated(CGSize(width: -1, height: 0), Int(step * 2)))
        XCTAssertEqual(codes.filter { $0 == right }.count, codes.filter { $0 == left }.count, "\(codes)")
        XCTAssertEqual(codes.filter { $0 == right }.count, 2)
    }

    func testVerticalDragMovesByLine() {
        let row = RemoteKeyboardTrackpad.rowStep
        XCTAssertEqual(arrows(repeated(CGSize(width: 0, height: 2), Int(row))), [down, down])
        XCTAssertEqual(arrows(repeated(CGSize(width: 0, height: -2), Int(row))), [up, up])
    }

    /// 横着拖的时候手指上下抖：不该跳行。
    func testJitterWhileDraggingSidewaysDoesNotChangeLine() {
        var steps: [CGSize] = []
        for index in 0..<120 {
            steps.append(CGSize(width: 1.5, height: index.isMultiple(of: 2) ? 1.2 : -1.0))
        }
        let codes = arrows(steps)
        XCTAssertFalse(codes.contains(up) || codes.contains(down), "\(codes)")
        XCTAssertEqual(codes.count, Int(1.5 * 120 / RemoteKeyboardTrackpad.columnStep))
    }

    /// 横着拖时整体一点点往下偏（不到 22°）也不跳行。
    func testSlightSlopeStaysOnTheLine() {
        let codes = arrows(repeated(CGSize(width: 2, height: 0.5), 200))
        XCTAssertFalse(codes.contains(down), "\(codes.filter { $0 == down }.count) 次跳行")
    }

    func testDeliberateDiagonalMovesBothWays() {
        let codes = arrows(repeated(CGSize(width: 2, height: 2), 60))
        XCTAssertTrue(codes.contains(right))
        XCTAssertTrue(codes.contains(down))
    }

    func testPointerMoveReportsDeltaAndSpeed() {
        var trackpad = RemoteKeyboardTrackpad(at: CGPoint(x: 10, y: 10), time: 1)
        let move = trackpad.pointerMove(to: CGPoint(x: 13, y: 14), time: 1.05)
        XCTAssertEqual(move.delta, CGSize(width: 3, height: 4))
        XCTAssertEqual(move.speed, 100, accuracy: 0.001)
        let still = trackpad.pointerMove(to: CGPoint(x: 13, y: 14), time: 1.05)
        XCTAssertEqual(still.delta, .zero)
        XCTAssertEqual(still.speed, 0, "同一时刻的两次报告不除以 0")
    }

    func testStoredModeFallsBackToTheDefault() {
        XCTAssertEqual(RemoteKeyboardTrackpadMode(stored: "pointer"), .pointer)
        XCTAssertEqual(RemoteKeyboardTrackpadMode(stored: "caret"), .caret)
        XCTAssertEqual(RemoteKeyboardTrackpadMode(stored: nil), .caret)
        XCTAssertEqual(RemoteKeyboardTrackpadMode(stored: "junk"), .caret)
        XCTAssertEqual(RemoteKeyboardTrackpadMode.allCases.map(\.rawValue), ["caret", "pointer"], "存进偏好的值不能改")
    }
}
