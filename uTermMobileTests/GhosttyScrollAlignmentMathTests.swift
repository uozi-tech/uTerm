import CoreGraphics
@testable import GhosttyTerminal
import XCTest

/// 系统滚动落点与对齐的纯算术（vendor/libghostty-spm 的本地补丁 #18，见 UTERM-PATCHES.md）。
/// 真触摸下的行为由 `Probes/GhosttySystemScrollVelocityTests` 核。
final class GhosttyScrollAlignmentMathTests: XCTestCase {
    /// 行高 50 px、倍率 2、回滚 10000 px、没有偏移。
    private let mapping = TerminalScrollOffsetMapping(scale: 2, cellHeight: 50, engineMax: 10_000, viewMax: 10_000, shift: 0)

    // MARK: 甩出去的落点

    func testLandingNearestRowWhenItIsAhead() {
        // 从 1010 px 甩到 2030 px：最近的一行 2050 在前方，照取最近的。
        XCTAssertEqual(mapping.landingOffset(proposed: 1015, current: 505), 1025)
        XCTAssertEqual(mapping.landingOffset(proposed: 1005, current: 505), 1000)
        // 往回滚顶也一样。
        XCTAssertEqual(mapping.landingOffset(proposed: 495, current: 1005), 500)
    }

    /// 起点 20 px（行内）、甩到 24 px：最近的一行是 0，在起点身后。原来取 0，UIKit 一帧把内容拽回去；现在取前方的 50。
    func testLandingNeverBehindTheStart() {
        XCTAssertEqual(mapping.landingOffset(proposed: 12, current: 10), 25)
        XCTAssertEqual(mapping.landingOffset(proposed: 38, current: 40), 25, "往回滚顶的短甩：最近的 100 在起点 80 身后，取 50")
        // 起点就在行上：前方第一行是它下一行（往前甩不会落回起点）。
        XCTAssertEqual(mapping.landingOffset(proposed: 26, current: 25), 25, "起点 50 px 在行上、提议 52：最近的 50 = 起点，不在身后，留着")
    }

    func testLandingStaysInRange() {
        XCTAssertEqual(mapping.landingOffset(proposed: 5_000, current: 4_990), 5_000)
        XCTAssertEqual(mapping.landingOffset(proposed: 0, current: 3), 0)
        let short = TerminalScrollOffsetMapping(scale: 2, cellHeight: 50, engineMax: 130, viewMax: 130, shift: 0)
        // 底不是行的整数倍时（engineMax 130），往底甩、前方第一行 150 超过了底：停在底上。
        XCTAssertEqual(short.landingOffset(proposed: 64, current: 60), 65)
    }

    // MARK: 停下来对齐到哪一行

    func testRestingRowFollowsTheTravel() {
        XCTAssertEqual(mapping.restingRow(enginePixels: 1010, travel: 0), 1000)
        XCTAssertEqual(mapping.restingRow(enginePixels: 1040, travel: 0), 1050)
        // 往底走（travel > 0）：前方第一行，哪怕后面那一行更近。
        XCTAssertEqual(mapping.restingRow(enginePixels: 1010, travel: 120), 1050)
        // 往回滚顶走：身后那一行算前方。
        XCTAssertEqual(mapping.restingRow(enginePixels: 1040, travel: -120), 1000)
        // 差不到半个像素算在行上，不再往前走一整行。
        XCTAssertEqual(mapping.restingRow(enginePixels: 1000.2, travel: 120), 1000)
        XCTAssertEqual(mapping.restingRow(enginePixels: 999.8, travel: -120), 1000)
        XCTAssertEqual(mapping.restingRow(enginePixels: 9_990, travel: 120), 10_000)
    }

    // MARK: 对齐曲线

    func testCurveFromRestStartsAtZeroSpeed() {
        let curve = TerminalScrollAlignmentCurve(distance: 6, velocity: 0, longest: 0.25)
        XCTAssertEqual(curve.duration, 0.25)
        XCTAssertEqual(curve.startSlope, 0)
        XCTAssertEqual(curve.value(at: 0), 0)
        XCTAssertEqual(curve.value(at: 1), 1)
        // 头 1/15（60 Hz 的第一帧）走的路程：从静止起步不到全程的 2%；原来的三次缓出是 18.7%（平均速度的 2.8 倍）。
        XCTAssertLessThan(curve.value(at: 1.0 / 15), 0.02)
        XCTAssertGreaterThan(1 - pow(1 - 1.0 / 15, 3), 0.18)
    }

    func testCurveKeepsTheReleaseSpeed() {
        // 6 pt 到行，手指 120 pt/s：三次缓出的时长 3 × 6 / 120 = 0.15 s，起步速度正好 120 pt/s。
        let curve = TerminalScrollAlignmentCurve(distance: 6, velocity: 120, longest: 0.25)
        XCTAssertEqual(curve.duration, 0.15, accuracy: 1e-9)
        XCTAssertEqual(curve.startSlope, 3, accuracy: 1e-9)
        let dt = 0.001
        let startSpeed = 6 * curve.value(at: CGFloat(dt / curve.duration)) / CGFloat(dt)
        XCTAssertEqual(startSpeed, 120, accuracy: 1)
        // 慢的手指（30 pt/s、13 pt 到行）：时长到顶 0.25 s，起步速度仍是 30 pt/s。
        let slow = TerminalScrollAlignmentCurve(distance: 13, velocity: 30, longest: 0.25)
        XCTAssertEqual(slow.duration, 0.25)
        XCTAssertEqual(13 * slow.value(at: CGFloat(dt / slow.duration)) / CGFloat(dt), 30, accuracy: 1)
        // 往回滚顶（距离、速度都为负）。
        let back = TerminalScrollAlignmentCurve(distance: -6, velocity: -120, longest: 0.25)
        XCTAssertEqual(back.startSlope, 3, accuracy: 1e-9)
    }

    func testCurveNeverOvershootsOrTurnsBack() {
        for (distance, velocity) in [(6.0, 0.0), (6.0, 60.0), (6.0, 120.0), (1.0, 250.0), (13.0, 30.0), (6.0, -200.0)] as [(CGFloat, CGFloat)] {
            let curve = TerminalScrollAlignmentCurve(distance: distance, velocity: velocity, longest: 0.25)
            XCTAssertGreaterThanOrEqual(curve.duration, TerminalScrollAlignmentCurve.shortestDuration)
            var last: CGFloat = 0
            for step in 1...200 {
                let value = curve.value(at: CGFloat(step) / 200)
                XCTAssertGreaterThanOrEqual(value, last - 1e-9, "d=\(distance) v=\(velocity)：对齐往回走了")
                XCTAssertLessThanOrEqual(value, 1 + 1e-9, "d=\(distance) v=\(velocity)：冲过了那一行")
                last = value
            }
        }
        // 速度背离那一行（不该发生，发生了按静止算）。
        XCTAssertEqual(TerminalScrollAlignmentCurve(distance: 6, velocity: -200, longest: 0.25).startSlope, 0)
    }
}
