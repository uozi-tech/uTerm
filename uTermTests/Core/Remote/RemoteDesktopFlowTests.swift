import CoreGraphics
import AppKit
import XCTest
@testable import uTerm

/// 远程桌面的纯函数：背压与丢帧、码率控制、尺寸与坐标换算、视口、触控板指针、键码映射。
final class RemoteDesktopFlowTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    // MARK: - 背压

    func test_pacer_holds_frames_beyond_two_in_flight_and_keeps_only_the_latest() {
        var pacer = RemoteDesktopPacer<Int>()
        let first = pacer.offer(1, now: 0)
        XCTAssertEqual(first.submit?.0, 1)
        XCTAssertEqual(first.submit?.1, 1)
        XCTAssertEqual(pacer.offer(2, now: 16 * ms).submit?.1, 2)
        // 在途已满两帧：第 3 帧先留着，不编。
        let third = pacer.offer(3, now: 32 * ms)
        XCTAssertNil(third.submit)
        XCTAssertFalse(third.congestionDrop, "第一次留帧不算丢")
        XCTAssertEqual(pacer.pending, 3)
        // 第 4 帧到了链路还没追上：替掉第 3 帧（编码前丢，算拥塞）。
        let fourth = pacer.offer(4, now: 48 * ms)
        XCTAssertNil(fourth.submit)
        XCTAssertTrue(fourth.congestionDrop)
        XCTAssertEqual(pacer.congestionDrops, 1)
        XCTAssertEqual(pacer.pending, 4)
        // 确认回来 = 链路追上：立刻编最新的那帧，而不是等下一次采集（静止画面不会再有下一次）。
        pacer.encoded(1, bytes: 30_000)
        XCTAssertTrue(pacer.acknowledge(1))
        let resumed = pacer.next(now: 50 * ms)
        XCTAssertEqual(resumed?.1, 4)
        XCTAssertEqual(resumed?.0, 3, "序号连续，丢掉的帧不占序号")
        XCTAssertNil(pacer.pending)
        XCTAssertNil(pacer.next(now: 51 * ms), "没有留着的帧就不编")
    }

    func test_pacer_byte_budget_and_bookkeeping() {
        var pacer = RemoteDesktopPacer<String>()
        let (sequence, _) = pacer.offer("big", now: 0).submit!
        pacer.encoded(sequence, bytes: 800 * 1024)
        XCTAssertEqual(pacer.inflightBytes, 800 * 1024)
        // 只有 1 帧在途，但字节超过 768 KB：也要等。
        XCTAssertNil(pacer.offer("next", now: 1).submit)
        XCTAssertFalse(pacer.acknowledge(999), "不认识的序号忽略")
        XCTAssertFalse(pacer.acknowledge(sequence + 5))
        XCTAssertTrue(pacer.acknowledge(sequence))
        XCTAssertFalse(pacer.acknowledge(sequence), "重复确认不再扣")
        XCTAssertEqual(pacer.inflightBytes, 0)
        let (second, frame) = pacer.next(now: 2)!
        XCTAssertEqual(frame, "next")
        // 编码失败：释放名额。
        pacer.abandon(second)
        XCTAssertTrue(pacer.inflight.isEmpty)
        XCTAssertTrue(pacer.hasCapacity)
    }

    func test_pacer_frame_interval_holds_without_counting_congestion() {
        var pacer = RemoteDesktopPacer<Int>()
        pacer.minimumIntervalNanos = 33 * ms
        XCTAssertNotNil(pacer.offer(1, now: 0).submit)
        let early = pacer.offer(2, now: 10 * ms)
        XCTAssertNil(early.submit)
        XCTAssertEqual(pacer.waitNanos(now: 10 * ms), 23 * ms)
        let replaced = pacer.offer(3, now: 20 * ms)
        XCTAssertFalse(replaced.congestionDrop, "帧间隔替掉的帧不算拥塞")
        XCTAssertEqual(pacer.pacingDrops, 1)
        XCTAssertNil(pacer.next(now: 30 * ms))
        XCTAssertEqual(pacer.next(now: 33 * ms)?.1, 3)
        XCTAssertEqual(pacer.waitNanos(now: 40 * ms), 0, "没有留着的帧不用等")
    }

    func test_pacer_direct_submit_respects_capacity() {
        var pacer = RemoteDesktopPacer<Int>()
        XCTAssertNotNil(pacer.submitDirect(1, now: 0))
        XCTAssertNotNil(pacer.submitDirect(1, now: 1))
        XCTAssertNil(pacer.submitDirect(1, now: 2), "精修 / 补关键帧也受在途上限约束")
    }

    // MARK: - 码率

    func test_rate_controller_backs_off_on_congestion_with_spacing_then_halves_frame_rate_at_floor() {
        let config = RemoteRateController.Config(minBitrate: 1_000_000, maxBitrate: 20_000_000)
        var rate = RemoteRateController(config: config, initialBitrate: 10_000_000, now: 0)
        XCTAssertTrue(rate.congestion(now: 1_000 * ms))
        XCTAssertEqual(rate.bitrate, 7_000_000)
        XCTAssertFalse(rate.congestion(now: 1_200 * ms), "500 ms 内的连续拥塞只降一次")
        XCTAssertEqual(rate.bitrate, 7_000_000)
        XCTAssertTrue(rate.congestion(now: 1_500 * ms))
        XCTAssertEqual(rate.bitrate, 4_900_000)
        var now = 1_500 * ms
        while rate.bitrate > config.minBitrate {
            now += 600 * ms
            rate.congestion(now: now)
        }
        XCTAssertEqual(rate.bitrate, config.minBitrate)
        XCTAssertEqual(rate.frameRate, 60)
        now += 600 * ms
        XCTAssertTrue(rate.congestion(now: now))
        XCTAssertEqual(rate.frameRate, 30, "码率到底还拥塞：帧率减半")
        now += 600 * ms
        XCTAssertFalse(rate.congestion(now: now), "已经到底，没得再降")
    }

    func test_rate_controller_recovers_frame_rate_first_then_bitrate_after_stable_period() {
        let config = RemoteRateController.Config(minBitrate: 1_000_000, maxBitrate: 3_000_000)
        var rate = RemoteRateController(config: config, initialBitrate: 1_000_000, now: 0)
        rate.congestion(now: 0)
        XCTAssertEqual(rate.frameRate, 30)
        XCTAssertFalse(rate.tick(now: 900 * ms), "不到 1 s 不升")
        XCTAssertTrue(rate.tick(now: 1_000 * ms))
        XCTAssertEqual(rate.frameRate, 60)
        XCTAssertEqual(rate.bitrate, 1_000_000)
        XCTAssertFalse(rate.tick(now: 1_300 * ms), "两次上调也要隔开")
        XCTAssertTrue(rate.tick(now: 1_500 * ms))
        XCTAssertEqual(rate.bitrate, 1_250_000)
        var now = 2_000 * ms
        for _ in 0..<20 {
            now += 1_000 * ms
            rate.tick(now: now)
        }
        XCTAssertEqual(rate.bitrate, config.maxBitrate, "不超过上限")
    }

    func test_rate_controller_treats_sustained_high_latency_as_congestion() {
        var rate = RemoteRateController(config: .init(minBitrate: 1_000_000, maxBitrate: 20_000_000),
                                        initialBitrate: 10_000_000, now: 0)
        XCTAssertFalse(rate.observe(latencyNanos: 20 * ms, now: 100 * ms))
        XCTAssertFalse(rate.observe(latencyNanos: 75 * ms, now: 450 * ms), "比基线多 55 ms，还在阈值内")
        XCTAssertFalse(rate.observe(latencyNanos: 100 * ms, now: 800 * ms))
        XCTAssertFalse(rate.observe(latencyNanos: 100 * ms, now: 816 * ms))
        XCTAssertTrue(rate.observe(latencyNanos: 100 * ms, now: 832 * ms), "窗口里 3 帧、最快的也排队超过 60 ms 才算拥塞")
        XCTAssertEqual(rate.bitrate, 7_000_000)
        // 拥塞之后要重新稳定满 1 s 才升。
        XCTAssertFalse(rate.observe(latencyNanos: 10 * ms, now: 1_800 * ms))
        XCTAssertTrue(rate.observe(latencyNanos: 10 * ms, now: 1_840 * ms))
    }

    func test_rate_controller_ignores_isolated_slow_acks() {
        // Wi-Fi 偶尔一帧慢：不是带宽不够，不该砍码率。
        var rate = RemoteRateController(config: .init(minBitrate: 1_000_000, maxBitrate: 20_000_000),
                                        initialBitrate: 10_000_000, now: 0)
        var now: UInt64 = 0
        for _ in 0..<10 {
            now += 16 * ms
            XCTAssertFalse(rate.observe(latencyNanos: 200 * ms, now: now))
            now += 16 * ms
            XCTAssertFalse(rate.observe(latencyNanos: 200 * ms, now: now))
            now += 16 * ms
            rate.observe(latencyNanos: 10 * ms, now: now)
        }
        XCTAssertEqual(rate.bitrate, 10_000_000, "慢帧被快帧打断就不累计")
    }

    /// 往返本来就慢（Wi-Fi、手机解码慢）但很稳：不是拥塞，码率照样涨到上限。
    /// 以前按绝对耗时判，这种链路上一直「拥塞」，码率压到底再也上不来。
    func test_rate_controller_climbs_on_a_slow_but_steady_link() {
        let config = RemoteRateController.Config(minBitrate: 1_000_000, maxBitrate: 30_000_000)
        var rate = RemoteRateController(config: config, initialBitrate: 1_000_000, now: 0)
        var now: UInt64 = 0
        while now < 30_000 * ms {
            now += 16 * ms
            rate.observe(latencyNanos: 150 * ms + (now / ms % 7) * ms, now: now)
        }
        XCTAssertEqual(rate.bitrate, config.maxBitrate)
        XCTAssertEqual(rate.frameRate, 60)
    }

    /// 真机 Wi-Fi 的抖动（iPhone 经 Wi-Fi、几乎空载时读到的：基线 30 ms、p50 约 50、p95 约 110 ms）
    /// 不是排队：码率要能涨到上限。旧判法「连续 3 帧超阈值」在这上面一直报拥塞，码率钉在 1 Mbps。
    func test_rate_controller_shrugs_off_wifi_jitter() {
        let config = RemoteRateController.Config(minBitrate: 1_000_000, maxBitrate: 30_000_000)
        var rate = RemoteRateController(config: config, initialBitrate: 1_000_000, now: 0)
        let jitter: [UInt64] = [32, 45, 50, 110, 118, 125, 48, 60, 38, 130, 52, 41, 95, 55, 35, 70, 47, 120, 105, 112]
        var now: UInt64 = 0
        var index = 0
        while now < 20_000 * ms {
            now += 25 * ms
            rate.observe(latencyNanos: jitter[index % jitter.count] * ms, now: now)
            index += 1
        }
        XCTAssertEqual(rate.bitrate, config.maxBitrate)
        XCTAssertEqual(rate.frameRate, 60)
    }

    /// 真排队：每一帧都比基线慢一大截，最快的那帧也一样，要降。
    func test_rate_controller_still_backs_off_when_every_frame_queues() {
        let config = RemoteRateController.Config(minBitrate: 1_000_000, maxBitrate: 30_000_000)
        var rate = RemoteRateController(config: config, initialBitrate: 30_000_000, now: 0)
        var now: UInt64 = 0
        for _ in 0..<20 {
            now += 16 * ms
            rate.observe(latencyNanos: 30 * ms, now: now)
        }
        for step in 0..<60 {
            now += 16 * ms
            rate.observe(latencyNanos: (110 + UInt64(step % 5) * 10) * ms, now: now)
        }
        XCTAssertLessThan(rate.bitrate, config.maxBitrate / 2)
    }

    /// 退避到底之后链路好了：先回 60 帧，再一路涨回上限，越过上次出事的码率也不停。
    func test_rate_controller_recovers_fully_after_backing_off_to_the_floor() {
        let config = RemoteRateController.Config(minBitrate: 1_000_000, maxBitrate: 30_000_000)
        var rate = RemoteRateController(config: config, initialBitrate: 30_000_000, now: 0)
        var now: UInt64 = 0
        // 先确认基线 20 ms，再让排队延迟一直很高：一路降到底、帧率减半。
        rate.observe(latencyNanos: 20 * ms, now: now)
        while rate.frameRate > 30 {
            now += 16 * ms
            rate.observe(latencyNanos: 300 * ms, now: now)
        }
        XCTAssertEqual(rate.bitrate, config.minBitrate)

        var recovered: UInt64?
        let start = now
        while now < start + 30_000 * ms {
            now += 16 * ms
            rate.observe(latencyNanos: 22 * ms, now: now)
            if recovered == nil, rate.bitrate == config.maxBitrate { recovered = now - start }
        }
        XCTAssertEqual(rate.frameRate, 60)
        let elapsed = try? XCTUnwrap(recovered, "要涨回上限，不能停在退避到的那一档")
        XCTAssertLessThan(elapsed ?? .max, 25_000 * ms, "1 → 30 Mbps 不能拖太久")
    }

    /// 接近上次出事的码率时改小步试探；越过去以后照样往上走。
    func test_rate_controller_probes_gently_near_the_bitrate_that_congested() {
        let config = RemoteRateController.Config(minBitrate: 1_000_000, maxBitrate: 40_000_000)
        var rate = RemoteRateController(config: config, initialBitrate: 20_000_000, now: 0)
        rate.congestion(now: 0)
        XCTAssertEqual(rate.bitrate, 14_000_000)
        rate.tick(now: 1_000 * ms)
        XCTAssertEqual(rate.bitrate, 17_500_000, "离 20 Mbps 还远：快涨")
        rate.tick(now: 1_500 * ms)
        XCTAssertEqual(rate.bitrate, 18_900_000, "到了 20 Mbps 的 85% 以上：小步")
        var now = 1_500 * ms
        for _ in 0..<40 {
            now += 500 * ms
            rate.tick(now: now)
        }
        XCTAssertEqual(rate.bitrate, config.maxBitrate)
    }

    /// 链路整体变慢（比如换到远一点的 Wi-Fi）：基线跟着抬，一个窗口后不再把新常态当拥塞。
    func test_rate_controller_baseline_follows_a_link_that_got_slower() {
        let config = RemoteRateController.Config(minBitrate: 1_000_000, maxBitrate: 30_000_000)
        var rate = RemoteRateController(config: config, initialBitrate: 30_000_000, now: 0)
        var now: UInt64 = 0
        for _ in 0..<100 {
            now += 16 * ms
            rate.observe(latencyNanos: 20 * ms, now: now)
        }
        for _ in 0..<1_500 {
            now += 16 * ms
            rate.observe(latencyNanos: 120 * ms, now: now)
        }
        XCTAssertEqual(rate.baselineLatency, 120 * ms)
        XCTAssertEqual(rate.bitrate, config.maxBitrate, "新常态下又涨回上限")
    }

    func test_inflight_frame_limit_follows_the_round_trip() {
        var rate = RemoteRateController(config: .init(minBitrate: 1_000_000, maxBitrate: 20_000_000),
                                        initialBitrate: 10_000_000, now: 0)
        XCTAssertEqual(rate.inflightFrameLimit, 2, "还没有确认：保守")
        rate.observe(latencyNanos: 2 * ms, now: 10 * ms)
        XCTAssertEqual(rate.inflightFrameLimit, 6, "2 ms + 80 ms 抖动余量：60 帧要送 5 帧，再留 1 帧")
        var slow = RemoteRateController(config: .init(minBitrate: 1_000_000, maxBitrate: 20_000_000),
                                        initialBitrate: 10_000_000, now: 0)
        slow.observe(latencyNanos: 30 * ms, now: 10 * ms)
        XCTAssertEqual(slow.inflightFrameLimit, 8, "真机 Wi-Fi 的基线 30 ms：按 110 ms 算要送 7 帧，再留 1 帧")
        slow.observe(latencyNanos: 200 * ms, now: 20 * ms)
        XCTAssertEqual(slow.inflightFrameLimit, 8, "基线取最小值")
        var crawl = RemoteRateController(config: .init(minBitrate: 1_000_000, maxBitrate: 20_000_000),
                                         initialBitrate: 10_000_000, now: 0)
        crawl.observe(latencyNanos: 300 * ms, now: 10 * ms)
        XCTAssertEqual(crawl.inflightFrameLimit, 8, "封顶 8 帧")
    }

    func test_inflight_byte_limit_covers_the_bitrate_over_a_round_trip() {
        var rate = RemoteRateController(config: .init(minBitrate: 1_000_000, maxBitrate: 100_000_000),
                                        initialBitrate: 90_000_000, now: 0)
        XCTAssertEqual(rate.inflightByteLimit, 768 * 1024, "还没有确认：默认")
        rate.observe(latencyNanos: 30 * ms, now: 10 * ms)
        XCTAssertEqual(rate.inflightByteLimit, 90_000_000 / 8 * 110 / 1000, "90 Mbps × 110 ms")
        var slow = RemoteRateController(config: .init(minBitrate: 1_000_000, maxBitrate: 100_000_000),
                                        initialBitrate: 1_000_000, now: 0)
        slow.observe(latencyNanos: 30 * ms, now: 10 * ms)
        XCTAssertEqual(slow.inflightByteLimit, 768 * 1024, "码率低时不低于默认值，关键帧要放得下")
    }

    func test_pacer_frame_window_is_adjustable() {
        var pacer = RemoteDesktopPacer<Int>()
        pacer.maxInflightFrames = 3
        XCTAssertNotNil(pacer.offer(1, now: 0).submit)
        XCTAssertNotNil(pacer.offer(2, now: 16 * ms).submit)
        XCTAssertNotNil(pacer.offer(3, now: 32 * ms).submit)
        XCTAssertNil(pacer.offer(4, now: 48 * ms).submit)
    }

    // MARK: - QP 上限

    /// 喂半秒钟的帧（60 fps）：每帧 `bytes`，前 `drops` 帧被码控丢掉。
    private func feedWindow(_ cap: inout RemoteQualityCap, from start: UInt64, frames: Int = 30, bytes: Int,
                            drops: Int = 0, target: Int = 90_000_000) -> UInt64 {
        var now = start
        for index in 0..<frames {
            now = start + UInt64(index + 1) * 500 * ms / UInt64(frames)
            cap.record(encodedBytes: index < drops ? nil : bytes, targetBitrate: target, frameRate: 60, now: now)
        }
        return now
    }

    func test_quality_cap_starts_unrestricted_and_tightens_while_the_budget_is_unused() {
        var cap = RemoteQualityCap(now: 0)
        XCTAssertEqual(cap.maxQP, RemoteQualityCap.unrestricted, "起步不限：不先压后退")
        var now = feedWindow(&cap, from: 0, bytes: 4_000)
        XCTAssertEqual(cap.maxQP, 40)
        for _ in 0..<20 { now = feedWindow(&cap, from: now, bytes: 4_000) }
        XCTAssertEqual(cap.maxQP, RemoteQualityCap.floor, "每帧 4 KB、预算 90 Mbps：一路收紧到下限")
    }

    /// 画面一下变复杂：第一帧超预算就退，不等丢帧（等到丢帧时码率已经透支，要连丢好几秒还）。
    func test_quality_cap_backs_off_on_the_first_oversized_frame() {
        var cap = RemoteQualityCap(now: 0)
        var now: UInt64 = 0
        for _ in 0..<12 { now = feedWindow(&cap, from: now, bytes: 4_000) }
        XCTAssertEqual(cap.maxQP, 29)
        // 90 Mbps / 60 fps ≈ 187 KB 一帧；300 KB 超了 1.5 倍。
        XCTAssertTrue(cap.record(encodedBytes: 300_000, targetBitrate: 90_000_000, frameRate: 60, now: now + 16 * ms))
        XCTAssertEqual(cap.maxQP, 32)
        XCTAssertFalse(cap.record(encodedBytes: 300_000, keyframe: true, targetBitrate: 90_000_000, frameRate: 60,
                                  now: now + 32 * ms), "关键帧本来就大，不算")
        for step in 0..<3 {
            cap.record(encodedBytes: 300_000, targetBitrate: 90_000_000, frameRate: 60, now: now + UInt64(48 + step * 16) * ms)
        }
        XCTAssertEqual(cap.maxQP, RemoteQualityCap.unrestricted, "连着超：35 → 38 → 到 40 以上就不限")
    }

    func test_quality_cap_backs_off_when_the_encoder_drops() {
        var cap = RemoteQualityCap(now: 0)
        var now: UInt64 = 0
        for _ in 0..<12 { now = feedWindow(&cap, from: now, bytes: 4_000) }
        now = feedWindow(&cap, from: now, bytes: 4_000, drops: 2)
        XCTAssertEqual(cap.maxQP, 29, "零星丢帧不收也不放")
        for drop in 1...3 {
            cap.record(encodedBytes: nil, targetBitrate: 90_000_000, frameRate: 60, now: now + UInt64(drop) * 16 * ms)
        }
        XCTAssertEqual(cap.maxQP, 32, "一个窗口里丢到 3 帧当场放宽")
    }

    func test_quality_cap_holds_when_the_budget_is_already_used() {
        var cap = RemoteQualityCap(now: 0)
        // 30 帧 × 100 KB / 0.5 s ≈ 49 Mbps，超过 90 Mbps 的一半：不再逼编码器多出。
        _ = feedWindow(&cap, from: 0, bytes: 100_000)
        XCTAssertEqual(cap.maxQP, RemoteQualityCap.unrestricted)
    }

    func test_quality_cap_relaxes_on_congestion() {
        var cap = RemoteQualityCap(now: 0)
        XCTAssertFalse(cap.congestion(), "不限时没得放")
        var now: UInt64 = 0
        for _ in 0..<4 { now = feedWindow(&cap, from: now, bytes: 4_000) }
        XCTAssertEqual(cap.maxQP, 37)
        XCTAssertTrue(cap.congestion())
        XCTAssertEqual(cap.maxQP, 40)
    }

    func test_quality_cap_needs_enough_frames_to_tighten() {
        var cap = RemoteQualityCap(now: 0)
        _ = feedWindow(&cap, from: 0, frames: 5, bytes: 4_000)
        XCTAssertEqual(cap.maxQP, RemoteQualityCap.unrestricted, "半秒只有 5 帧：样本太少，不收紧")
    }

    func test_initial_bitrate_scales_with_pixels() {
        XCTAssertEqual(RemoteRateController.initialBitrate(width: 1920, height: 1080), 1920 * 1080 * 12)
        XCTAssertEqual(RemoteRateController.initialBitrate(width: 2144, height: 1206), 2144 * 1206 * 12,
                       "约 31 Mbps：低延迟编码器在桌面上用得到的量，起步就给")
        XCTAssertEqual(RemoteRateController.initialBitrate(width: 64, height: 64), 1_000_000, "下限")
        let config = RemoteRateController.config(width: 2464, height: 1600)
        XCTAssertEqual(config.maxBitrate, 2464 * 1600 * 24)
    }

    // MARK: - 几何

    func test_stream_size_fits_display_into_box_by_orientation_and_never_upscales() {
        // 3024×1964 的 Retina 屏塞进手机 2622×1206 的框：按高度受限。
        let fit = RemoteDesktopGeometry.streamSize(displayPixels: CGSize(width: 3024, height: 1964), maxWidth: 1206, maxHeight: 2622)
        XCTAssertEqual(fit.height, 1206)
        XCTAssertEqual(fit.width, 1856)
        XCTAssertEqual(fit.width % 2, 0)
        // 小屏不放大，奇数取偶。
        let small = RemoteDesktopGeometry.streamSize(displayPixels: CGSize(width: 1367, height: 769), maxWidth: 4000, maxHeight: 3000)
        XCTAssertEqual(small.width, 1366)
        XCTAssertEqual(small.height, 768)
        // 竖屏显示器：框也竖过来。
        let portrait = RemoteDesktopGeometry.streamSize(displayPixels: CGSize(width: 1080, height: 1920), maxWidth: 1920, maxHeight: 1080)
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
    }

    func test_global_point_maps_and_clamps_on_offset_display() {
        let bounds = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        XCTAssertEqual(RemoteDesktopGeometry.globalPoint(x: 0, y: 0, displayBounds: bounds), CGPoint(x: -1440, y: -900))
        XCTAssertEqual(RemoteDesktopGeometry.globalPoint(x: 0.5, y: 0.5, displayBounds: bounds), CGPoint(x: -720, y: -450))
        // 贴边：停在最后一个点上，不跑到相邻的屏幕上去。
        XCTAssertEqual(RemoteDesktopGeometry.globalPoint(x: 1, y: 1.3, displayBounds: bounds), CGPoint(x: -1, y: -1))
        XCTAssertEqual(RemoteDesktopGeometry.globalPoint(x: -0.2, y: .nan, displayBounds: bounds), CGPoint(x: -1440, y: -900))
        let back = RemoteDesktopGeometry.normalized(CGPoint(x: -360, y: -225), displayBounds: bounds)
        XCTAssertEqual(back.x, 0.75, accuracy: 1e-6)
        XCTAssertEqual(back.y, 0.75, accuracy: 1e-6)
    }

    func test_viewport_fit_zoom_pan_and_mapping() {
        var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 1512, height: 982), viewSize: CGSize(width: 874, height: 402))
        // 适配：纵向受限（402/982 < 874/1512）→ 上下贴满、左右留黑边。
        XCTAssertEqual(viewport.fitScale, 402.0 / 982.0, accuracy: 1e-9)
        let frame = viewport.contentFrame
        XCTAssertEqual(frame.height, 402, accuracy: 1e-6)
        XCTAssertEqual(frame.midX, 437, accuracy: 1e-6)
        let center = viewport.normalized(viewPoint: CGPoint(x: 437, y: 201))
        XCTAssertEqual(center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)
        // 适配时拖不动。
        viewport.pan(by: CGSize(width: 100, height: 100))
        XCTAssertEqual(viewport.center, CGPoint(x: 0.5, y: 0.5))

        // 以某点为不动点放大：手指下的那块内容不动。
        let anchor = CGPoint(x: 300, y: 100)
        let before = viewport.normalized(viewPoint: anchor)
        viewport.zoom(by: 3, anchor: anchor)
        XCTAssertEqual(viewport.zoom, 3)
        let after = viewport.viewPoint(normalized: before)
        XCTAssertEqual(after.x, anchor.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, anchor.y, accuracy: 1e-6)
        // 往右拖到底：可见区左边贴住显示器左边，不露黑边。
        viewport.pan(by: CGSize(width: 10_000, height: 0))
        XCTAssertEqual(viewport.contentFrame.minX, 0, accuracy: 1e-6)
        viewport.pan(by: CGSize(width: -10_000, height: -10_000))
        XCTAssertEqual(viewport.contentFrame.maxX, 874, accuracy: 1e-6)
        XCTAssertEqual(viewport.contentFrame.maxY, 402, accuracy: 1e-6)
        // 缩放有上下限。
        viewport.zoom(by: 100, anchor: anchor)
        XCTAssertEqual(viewport.zoom, RemoteDesktopViewport.maxZoom)
        viewport.zoom(by: 0.0001, anchor: anchor)
        XCTAssertEqual(viewport.zoom, RemoteDesktopViewport.minZoom)
        // 缩到适配以下：两个方向都比视图小，居中。
        XCTAssertEqual(viewport.center, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(viewport.contentFrame.midX, viewport.viewSize.width / 2, accuracy: 1e-6)
        XCTAssertEqual(viewport.contentFrame.midY, viewport.viewSize.height / 2, accuracy: 1e-6)
        XCTAssertLessThan(viewport.contentFrame.width, viewport.viewSize.width)
    }

    func test_viewport_follows_pointer_when_zoomed() {
        var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 1512, height: 982), viewSize: CGSize(width: 874, height: 402))
        viewport.setZoom(4)
        viewport.ensureVisible(CGPoint(x: 0.95, y: 0.1), margin: 40)
        let point = viewport.viewPoint(normalized: CGPoint(x: 0.95, y: 0.1))
        XCTAssertLessThanOrEqual(point.x, 874 - 40 + 1e-6)
        XCTAssertGreaterThanOrEqual(point.y, 40 - 1e-6)
        // 已经在可见区内：不动。
        let center = viewport.center
        viewport.ensureVisible(viewport.normalized(viewPoint: CGPoint(x: 437, y: 201)), margin: 40)
        XCTAssertEqual(viewport.center, center)
    }

    /// 在角落放大后光标落到画面外：要把光标留在画面里，下一次移动才不会把画面拽回光标那边。
    func test_pointer_kept_in_view_after_zoom_so_the_next_move_does_not_yank_the_viewport() {
        var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 1600, height: 1000),
                                             viewSize: CGSize(width: 800, height: 500))
        viewport.zoom(by: 4, anchor: CGPoint(x: 780, y: 480))
        let center = CGPoint(x: 0.5, y: 0.5)
        let hidden = viewport.viewPoint(normalized: center)
        XCTAssertLessThan(hidden.x, 0, "前提：放大后光标在画面外")

        let kept = viewport.keepingVisible(center, margin: 48)
        let shown = viewport.viewPoint(normalized: kept)
        XCTAssertEqual(shown.x, 48, accuracy: 0.001)
        XCTAssertEqual(shown.y, 48, accuracy: 0.001)

        let before = viewport
        viewport.ensureVisible(kept, margin: 48)
        XCTAssertEqual(viewport, before, "留在画面里之后，移动光标不会让画面跳走")
    }

    func test_pointer_kept_in_view_stays_put_when_it_is_already_reachable() {
        var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 1600, height: 1000),
                                             viewSize: CGSize(width: 800, height: 500))
        // 适配时整块显示器都在画面里：贴着显示器边的光标不该被往里推。
        let corner = CGPoint(x: 0.001, y: 0.999)
        XCTAssertEqual(viewport.keepingVisible(corner, margin: 48), corner)

        // 放大后停在显示器左上角：那两条边是显示器真实的边，光标可以贴着。
        viewport.zoom(by: 4, anchor: .zero)
        let topLeft = CGPoint(x: 0.001, y: 0.001)
        XCTAssertEqual(viewport.keepingVisible(topLeft, margin: 48), topLeft)
        let before = viewport
        viewport.ensureVisible(topLeft, margin: 48)
        XCTAssertEqual(viewport, before)
    }

    func test_trackpad_moves_finer_when_zoomed_accelerates_and_clamps() {
        var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 1000, height: 500), viewSize: CGSize(width: 500, height: 250))
        let start = CGPoint(x: 0.5, y: 0.5)
        let slow = RemoteTrackpad.advance(start, by: CGSize(width: 10, height: 0), speed: 150, viewport: viewport)
        // 适配比例 0.5：10 视图点 = 20 显示器点 = 0.02。
        XCTAssertEqual(slow.x, 0.52, accuracy: 1e-9)
        viewport.setZoom(4)
        let zoomed = RemoteTrackpad.advance(start, by: CGSize(width: 10, height: 0), speed: 150, viewport: viewport)
        XCTAssertEqual(zoomed.x, 0.505, accuracy: 1e-9, "放大 4 倍后同样的手指位移只走 1/4")
        let fast = RemoteTrackpad.advance(start, by: CGSize(width: 10, height: 0), speed: 2000, viewport: viewport)
        XCTAssertGreaterThan(fast.x - 0.5, zoomed.x - 0.5, "快甩加速")
        XCTAssertEqual(RemoteTrackpad.acceleration(speed: 10_000), 2.5)
        let clamped = RemoteTrackpad.advance(CGPoint(x: 0.99, y: 0.01), by: CGSize(width: 900, height: -900), speed: 0,
                                             viewport: viewport)
        XCTAssertEqual(clamped, CGPoint(x: 1, y: 0))
    }

    func test_trackpad_slows_down_for_precision_and_keeps_gain_continuous() {
        XCTAssertEqual(RemoteTrackpad.acceleration(speed: 0), 0.5)
        XCTAssertEqual(RemoteTrackpad.acceleration(speed: 40), 0.5)
        XCTAssertEqual(RemoteTrackpad.acceleration(speed: 95), 0.75, accuracy: 1e-9)
        XCTAssertEqual(RemoteTrackpad.acceleration(speed: 150), 1)
        XCTAssertGreaterThan(RemoteTrackpad.acceleration(speed: 151), 1)
    }

    func test_edge_velocity_points_to_the_nearest_edge_and_grows_toward_it() {
        let size = CGSize(width: 400, height: 800)
        XCTAssertEqual(RemoteTrackpad.edgeVelocity(at: CGPoint(x: 200, y: 400), in: size), .zero)
        let left = RemoteTrackpad.edgeVelocity(at: CGPoint(x: 16, y: 400), in: size)
        XCTAssertEqual(left, CGSize(width: -200, height: 0))
        let corner = RemoteTrackpad.edgeVelocity(at: CGPoint(x: 400, y: 800), in: size)
        XCTAssertEqual(corner, CGSize(width: 400, height: 400))
    }

    /// 只造事件读回来，不投递：app 看到的阶段必须和手机发的一致。
    func test_injected_scroll_phases_read_back_as_sent() throws {
        let cases: [(RemoteScrollPhase, NSEvent.Phase, NSEvent.Phase)] = [
            (.began, .began, []),
            (.changed, .changed, []),
            (.ended, .ended, []),
            (.momentumBegan, [], .began),
            (.momentum, [], .changed),
            (.momentumEnded, [], .ended),
        ]
        for (phase, expectedPhase, expectedMomentum) in cases {
            let (scrollPhase, momentumPhase) = RemoteEventInjector.phases(phase)
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                              wheel1: 5, wheel2: 0, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
            let read = try XCTUnwrap(NSEvent(cgEvent: event))
            XCTAssertEqual(read.phase, expectedPhase, "\(phase)")
            XCTAssertEqual(read.momentumPhase, expectedMomentum, "\(phase)")
            XCTAssertEqual(read.scrollingDeltaY, 5, "像素位移不缩放")
        }
    }

    // MARK: - 键码

    func test_key_map_hid_and_characters() {
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x04), 0x00, "a")
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x1D), 0x06, "z")
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x1E), 0x12, "1")
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x27), 0x1D, "0")
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x28), RemoteKeyMap.Key.returnKey)
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x2A), RemoteKeyMap.Key.delete)
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x3A), 0x7A, "F1")
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x45), 0x6F, "F12")
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x50), RemoteKeyMap.Key.left)
        XCTAssertEqual(RemoteKeyMap.keyCode(hidUsage: 0x52), RemoteKeyMap.Key.up)
        XCTAssertNil(RemoteKeyMap.keyCode(hidUsage: 0xE3), "修饰键本身不发")

        XCTAssertEqual(RemoteKeyMap.keyCode(for: "c")?.code, 0x08)
        XCTAssertEqual(RemoteKeyMap.keyCode(for: "c")?.shift, false)
        XCTAssertEqual(RemoteKeyMap.keyCode(for: "C")?.code, 0x08)
        XCTAssertEqual(RemoteKeyMap.keyCode(for: "C")?.shift, true)
        XCTAssertEqual(RemoteKeyMap.keyCode(for: "?")?.code, 0x2C)
        XCTAssertEqual(RemoteKeyMap.keyCode(for: "?")?.shift, true)
        XCTAssertEqual(RemoteKeyMap.keyCode(for: "\n")?.code, RemoteKeyMap.Key.returnKey)
        XCTAssertNil(RemoteKeyMap.keyCode(for: "你"))
        // 每个字母都有键码且互不相同。
        let codes = "abcdefghijklmnopqrstuvwxyz".compactMap { RemoteKeyMap.keyCode(for: $0)?.code }
        XCTAssertEqual(Set(codes).count, 26)
    }
}
