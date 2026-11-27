import CoreGraphics
import XCTest
@testable import uTerm

/// 手机键盘的触控板（长按空格键滑动）：位移换成方向键或指针移动。
final class RemoteKeyboardTrackpadTests: XCTestCase {
    private let left = RemoteKeyMap.Key.left, right = RemoteKeyMap.Key.right
    private let up = RemoteKeyMap.Key.up, down = RemoteKeyMap.Key.down

    /// 两次报告之间隔得这么短：多小的位移都算快拖，步长按 `columnStep` / `rowStep` 原样计。
    private static let fast: Double = 0.00001
    /// 系统一秒报 120 次。
    private static let frame: Double = 1.0 / 120

    /// 从原点沿一串位移一路滑过去（每段隔 `interval` 秒），收集全部方向键。
    private func arrows(_ steps: [CGSize], interval: Double = fast) -> [UInt16] {
        var trackpad = RemoteKeyboardTrackpad(at: .zero, time: 0)
        var point = CGPoint.zero
        var time = 0.0
        var codes: [UInt16] = []
        for step in steps {
            point.x += step.width
            point.y += step.height
            time += interval
            codes += trackpad.arrows(to: point, time: time)
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

    /// 慢慢挪（每秒 30 点）时每个字要走的距离是快拖的 1 / `slowGain` 倍：能一个字一个字地点到位，不冲过头。
    func testSlowDragNeedsMoreDistancePerCharacter() {
        let distance: CGFloat = 40
        let slow = arrows(repeated(CGSize(width: 0.25, height: 0), Int(distance / 0.25)), interval: Self.frame)
        let quick = arrows(repeated(CGSize(width: 0.25, height: 0), Int(distance / 0.25)))
        XCTAssertEqual(quick.count, Int(distance / RemoteKeyboardTrackpad.columnStep))
        XCTAssertEqual(slow.count, Int(distance * RemoteKeyboardTrackpad.slowGain / RemoteKeyboardTrackpad.columnStep))
        XCTAssertLessThan(slow.count, quick.count)
    }

    func testGainRisesWithSpeed() {
        XCTAssertEqual(RemoteKeyboardTrackpad.gain(at: 0), RemoteKeyboardTrackpad.slowGain)
        XCTAssertEqual(RemoteKeyboardTrackpad.gain(at: RemoteKeyboardTrackpad.slowSpeed), RemoteKeyboardTrackpad.slowGain)
        XCTAssertEqual(RemoteKeyboardTrackpad.gain(at: RemoteKeyboardTrackpad.fastSpeed), 1)
        XCTAssertEqual(RemoteKeyboardTrackpad.gain(at: 10_000), 1)
        let middle = RemoteKeyboardTrackpad.gain(at: (RemoteKeyboardTrackpad.slowSpeed + RemoteKeyboardTrackpad.fastSpeed) / 2)
        XCTAssertGreaterThan(middle, RemoteKeyboardTrackpad.slowGain)
        XCTAssertLessThan(middle, 1)
    }

    /// 往右拖到差一点就再按一下的位置再往回拖：走一格左右就该按 ←，不用先把右边攒着的那段走回来（之前要走将近两格，像慢了半拍）。
    func testReversingStartsMovingBackWithinAboutOneColumn() {
        let step = RemoteKeyboardTrackpad.columnStep
        var trackpad = RemoteKeyboardTrackpad(at: .zero, time: 0)
        var x: CGFloat = 0, time = 0.0
        for _ in 0..<Int(step * 2 - 1) {
            x += 1
            time += Self.fast
            _ = trackpad.arrows(to: CGPoint(x: x, y: 0), time: time)
        }
        var samplesUntilLeft = 0
        while samplesUntilLeft < 100 {
            samplesUntilLeft += 1
            x -= 1
            time += Self.fast
            if trackpad.arrows(to: CGPoint(x: x, y: 0), time: time).contains(left) { break }
        }
        XCTAssertLessThanOrEqual(samplesUntilLeft, Int(step) + 3, "往回拖了 \(samplesUntilLeft) 点才按 ←")
    }

    /// 慢慢挪时手指一抖有一两次反向的小位移：不该把攒着的清掉、一直走不满一格。
    func testTremorDuringSlowDragStillAdvances() {
        var steps: [CGSize] = []
        for index in 0..<400 {
            steps.append(CGSize(width: index.isMultiple(of: 5) ? -0.2 : 0.4, height: 0))
        }
        let codes = arrows(steps, interval: Self.frame)
        XCTAssertFalse(codes.contains(left), "\(codes)")
        // 净走 0.28 × 400 = 112 点，慢速一个字 20 点：抖动会清掉一点余数，至少也要有 4 个。
        XCTAssertGreaterThanOrEqual(codes.filter { $0 == right }.count, 4, "\(codes)")
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
