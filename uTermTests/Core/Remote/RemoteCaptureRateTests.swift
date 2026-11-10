import CoreGraphics
import XCTest
@testable import uTerm

/// 采集帧率随变化面积走：一直只有小块在变满 1 秒降到 30 fps，出现大面积变化立刻回满帧。
final class RemoteCaptureRateTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func test_small_changes_reduce_after_a_steady_second_and_large_change_restores_at_once() {
        var governor = RemoteCaptureRateGovernor(fullRate: 60)
        XCTAssertEqual(governor.rate, 60)
        // 打字：每帧只变一小块。不到 1 秒不降。
        for tick in 0..<60 {
            XCTAssertNil(governor.frame(dirtyFraction: 0.01, now: UInt64(tick) * 16 * ms), "第 \(tick) 帧")
        }
        XCTAssertEqual(governor.frame(dirtyFraction: 0.01, now: 1_000 * ms), 30, "满 1 秒降到 30")
        XCTAssertNil(governor.frame(dirtyFraction: 0.02, now: 1_033 * ms), "已经降了，不重复报")
        // 开始滚动：大面积变化，立刻回 60。
        XCTAssertEqual(governor.frame(dirtyFraction: 0.6, now: 1_066 * ms), 60)
        XCTAssertNil(governor.frame(dirtyFraction: 0.6, now: 1_083 * ms))
        // 滚完又只剩小块变化：重新计满 1 秒才降。
        XCTAssertNil(governor.frame(dirtyFraction: 0.01, now: 1_100 * ms))
        XCTAssertNil(governor.frame(dirtyFraction: 0.01, now: 2_000 * ms))
        XCTAssertEqual(governor.frame(dirtyFraction: 0.01, now: 2_100 * ms), 30)
    }

    func test_unknown_dirty_area_counts_as_large_and_low_full_rate_is_left_alone() {
        var governor = RemoteCaptureRateGovernor(fullRate: 60)
        XCTAssertNil(governor.frame(dirtyFraction: 0.01, now: 0))
        XCTAssertNil(governor.frame(dirtyFraction: nil, now: 600 * ms), "没有 dirtyRects：按大面积算，清掉计时")
        XCTAssertNil(governor.frame(dirtyFraction: 0.01, now: 1_200 * ms), "从 1.2 s 重新计")
        XCTAssertEqual(governor.frame(dirtyFraction: 0.01, now: 2_200 * ms), 30)

        var thirty = RemoteCaptureRateGovernor(fullRate: 30)
        XCTAssertNil(thirty.frame(dirtyFraction: 0.01, now: 0))
        XCTAssertNil(thirty.frame(dirtyFraction: 0.01, now: 5_000 * ms), "满帧本来就是 30：不再降")
    }

    func test_dirty_fraction_clips_to_frame_and_caps_at_one() {
        let size = CGSize(width: 100, height: 100)
        XCTAssertEqual(RemoteCaptureRateGovernor.dirtyFraction([], frameSize: size), 0)
        XCTAssertEqual(RemoteCaptureRateGovernor.dirtyFraction([CGRect(x: 0, y: 0, width: 10, height: 10)],
                                                              frameSize: size), 0.01, accuracy: 1e-9)
        XCTAssertEqual(RemoteCaptureRateGovernor.dirtyFraction([CGRect(x: 90, y: 90, width: 50, height: 50)],
                                                              frameSize: size), 0.01, accuracy: 1e-9, "裁到画面内")
        XCTAssertEqual(RemoteCaptureRateGovernor.dirtyFraction([CGRect(x: 0, y: 0, width: 100, height: 100),
                                                               CGRect(x: 0, y: 0, width: 50, height: 50)],
                                                              frameSize: size), 1, "重叠相加封顶 1")
        XCTAssertEqual(RemoteCaptureRateGovernor.dirtyFraction([], frameSize: .zero), 1, "尺寸不明按整屏")
    }
}
