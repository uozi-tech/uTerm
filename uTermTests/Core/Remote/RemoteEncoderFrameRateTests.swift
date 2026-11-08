import XCTest
@testable import uTerm

/// 告诉编码器的帧率跟着采集帧率走：快升慢降、不每帧都改。
final class RemoteEncoderFrameRateTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    /// 喂 `count` 帧、间隔 `gap`，每帧都问一次，返回最后的值。
    private func feed(_ rate: inout RemoteEncoderFrameRate, from start: UInt64, count: Int, gap: UInt64,
                      limit: Int = 60) -> (value: Int, end: UInt64) {
        var now = start
        var value = 0
        for _ in 0..<count {
            now += gap
            rate.record(now: now)
            value = rate.expected(limit: limit, now: now)
        }
        return (value, now)
    }

    /// 采集 6 fps：报 12（留一倍余量）。
    func test_follows_a_slow_capture_rate_with_headroom() {
        var rate = RemoteEncoderFrameRate()
        let result = feed(&rate, from: 0, count: 20, gap: 166 * ms)
        XCTAssertEqual(result.value, 12)
    }

    /// 采集 30 fps（满屏在变）：仍报码控帧率 60，跟以前一样——如实报 30 时每帧预算翻倍、丢得更多。
    func test_busy_capture_keeps_the_rate_controller_frame_rate() {
        var rate = RemoteEncoderFrameRate()
        let result = feed(&rate, from: 0, count: 60, gap: 33 * ms)
        XCTAssertEqual(result.value, 60)
    }

    /// 静止之后画面突然满帧率在变：几帧之内就跟上，不在低帧率上停一秒（每帧预算偏大，帧一张比一张大）。
    func test_rises_within_a_few_frames() {
        var rate = RemoteEncoderFrameRate()
        var (value, now) = feed(&rate, from: 0, count: 3, gap: 5_000 * ms)
        XCTAssertEqual(value, RemoteEncoderFrameRate.floor)
        (value, now) = feed(&rate, from: now, count: 10, gap: 17 * ms)
        XCTAssertGreaterThanOrEqual(value, 45)
    }

    /// 降下来要慢：改过一次之后 1 s 内不再改；差不到 20% 不改。
    func test_falls_slowly_and_at_most_once_a_second() {
        var rate = RemoteEncoderFrameRate()
        var (value, now) = feed(&rate, from: 0, count: 120, gap: 17 * ms)
        XCTAssertGreaterThanOrEqual(value, 55)
        // 第一次降：可以马上降（上次改已经是 1 s 多以前）。
        (value, now) = feed(&rate, from: now, count: 2, gap: 166 * ms)
        let first = value
        XCTAssertLessThan(first, 55)
        // 1 s 之内不再降，哪怕采集帧率还在往下走。
        (value, now) = feed(&rate, from: now, count: 4, gap: 166 * ms)
        XCTAssertEqual(value, first)
        (value, now) = feed(&rate, from: now, count: 40, gap: 166 * ms)
        XCTAssertTrue((12...14).contains(value), "\(value)")
    }

    /// 夹在 [下限, 码控帧率]：码控把帧率压下去时立刻跟。
    func test_is_bounded_by_the_floor_and_the_rate_controller() {
        var rate = RemoteEncoderFrameRate()
        var (value, now) = feed(&rate, from: 0, count: 20, gap: 1_000 * ms)
        XCTAssertEqual(value, RemoteEncoderFrameRate.floor)
        (value, now) = feed(&rate, from: now, count: 60, gap: 17 * ms)
        rate.record(now: now + 17 * ms)
        XCTAssertEqual(rate.expected(limit: 30, now: now + 17 * ms), 30)
    }

    /// 还没量到间隔（只采到一帧）：按码控帧率。
    func test_uses_the_rate_controller_before_any_interval() {
        var rate = RemoteEncoderFrameRate()
        rate.record(now: 0)
        XCTAssertEqual(rate.expected(limit: 60, now: 0), 60)
    }
}
