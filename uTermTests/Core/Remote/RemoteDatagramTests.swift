import CryptoKit
import XCTest
@testable import uTerm

/// 数据报层的纯逻辑：加密、防重放、发送节奏、链路估计、丢包策略。
final class RemoteDatagramTests: XCTestCase {

    // MARK: - 加密

    private func cipherPair() -> (RemoteDatagramCipher, RemoteDatagramCipher) {
        let keys = makeDatagramKeys()
        return (RemoteDatagramCipher(control: keys.first), RemoteDatagramCipher(control: keys.second))
    }

    func test_datagram_round_trips() throws {
        var (a, b) = cipherPair()
        let sealed = try XCTUnwrap(a.seal(.reliable, Data("hello".utf8)))
        XCTAssertEqual(sealed.count, RemoteDatagramCipher.overhead + 5)
        let opened = try XCTUnwrap(b.open(sealed))
        XCTAssertEqual(opened.kind, .reliable)
        XCTAssertEqual(opened.sequence, 1)
        XCTAssertEqual(opened.payload, Data("hello".utf8))
    }

    func test_tampering_anywhere_is_rejected() throws {
        var (a, b) = cipherPair()
        let sealed = try XCTUnwrap(a.seal(.report, Data(repeating: 7, count: 32)))
        for index in sealed.indices {
            var forged = sealed
            forged[index] ^= 0x01
            XCTAssertNil(b.open(forged), "第 \(index) 字节被改了还能解开")
        }
    }

    func test_replay_and_reflection_are_rejected() throws {
        var (a, b) = cipherPair()
        let sealed = try XCTUnwrap(a.seal(.reliable, Data([1])))
        XCTAssertNotNil(b.open(sealed))
        XCTAssertNil(b.open(sealed), "重放")
        XCTAssertNil(a.open(sealed), "原样反射回发送方")
    }

    func test_media_needs_its_own_key() throws {
        var (a, b) = cipherPair()
        XCTAssertNil(a.seal(.media, Data([1])), "视频密钥没装好不能发")
        let sessionA = SymmetricKey(size: .bits256), sessionB = SymmetricKey(size: .bits256)
        a.installMedia(.media(sessionSend: sessionA, sessionReceive: sessionB))
        let sealed = try XCTUnwrap(a.seal(.media, Data([1])))
        XCTAssertNil(b.open(sealed), "对端还没装好")
        b.installMedia(.media(sessionSend: sessionB, sessionReceive: sessionA))
        XCTAssertEqual(b.open(sealed)?.payload, Data([1]))
    }

    /// 视频不能用信令派生的密钥：那把密钥只靠长期密钥和随机数，长期密钥泄露就能解开录下来的画面。
    func test_media_key_differs_from_session_key() {
        let session = SymmetricKey(size: .bits256)
        let media = RemoteDatagramKeys.media(sessionSend: session, sessionReceive: session)
        XCTAssertNotEqual(media.send.withUnsafeBytes { Data($0) }, session.withUnsafeBytes { Data($0) })
    }

    func test_replay_window_tolerates_reordering_within_limits() {
        var window = RemoteReplayWindow()
        XCTAssertFalse(window.accept(0))
        XCTAssertTrue(window.accept(5))
        XCTAssertTrue(window.accept(3), "乱序")
        XCTAssertFalse(window.accept(3), "重复")
        XCTAssertTrue(window.accept(5000))
        XCTAssertFalse(window.accept(5), "太旧")
        XCTAssertTrue(window.accept(4999))
        XCTAssertTrue(window.accept(100_000), "一下跳很远")
        XCTAssertFalse(window.accept(99_999 - RemoteReplayWindow.size))
        XCTAssertTrue(window.accept(99_999))
    }

    // MARK: - 发送节奏

    func test_pacer_holds_to_the_rate() {
        var pacer = RemoteDatagramPacer(rate: 1_000_000, now: 0)
        for _ in 0..<2000 { pacer.enqueue(.media, Data(count: 1000), priority: .media) }
        var now: UInt64 = 0
        var sent = 0
        while now < 1_000_000_000 {
            while pacer.next(now: now) != nil { sent += 1 }
            now += 1_000_000
        }
        // 1 MB/s，每包 1025 字节（含加密开销）。
        XCTAssertEqual(Double(sent), 1_000_000 / 1025, accuracy: 30)
    }

    func test_control_goes_before_queued_media() {
        var pacer = RemoteDatagramPacer(rate: 1_000_000, now: 0)
        pacer.enqueue(.media, Data(count: 1000), priority: .media)
        pacer.enqueue(.media, Data(count: 1000), priority: .media)
        pacer.enqueue(.reliable, Data(count: 10), priority: .control)
        XCTAssertEqual(pacer.next(now: 0)?.0, .reliable)
    }

    /// 控制 > 声音 > 视频重传 > 新视频。视频重传以前跟控制同一档、插到声音前面，3G 上声音欠载翻几倍；
    /// 也不能跟新视频一档，排在一大串新分片后面就过了时限（2026-11-09）。
    func test_retransmits_go_after_audio_but_before_new_video() {
        var pacer = RemoteDatagramPacer(rate: 1_000_000_000, now: 0)
        pacer.enqueue(.media, Data(count: 1000), priority: .media)
        pacer.enqueue(.media, Data(count: 999), priority: .retransmit)
        pacer.enqueue(.audio, Data(count: 100), priority: .audio)
        pacer.enqueue(.report, Data(count: 10), priority: .control)
        var order: [Int] = []
        while let item = pacer.next(now: 0) { order.append(item.1.count) }
        XCTAssertEqual(order, [10, 100, 999, 1000])
        XCTAssertTrue(pacer.isEmpty)
        XCTAssertEqual(pacer.mediaEnqueued, 1, "重传不算进新视频的计数")
        XCTAssertEqual(pacer.mediaSent, 1)
    }

    func test_media_counters_tell_when_a_frame_has_left_the_queue() {
        var pacer = RemoteDatagramPacer(rate: 2400, now: 0)
        for _ in 0..<3 { pacer.enqueue(.media, Data(count: 1000), priority: .media) }
        let frameEnd = pacer.mediaEnqueued
        _ = pacer.next(now: 0)
        _ = pacer.next(now: 0)
        XCTAssertLessThan(pacer.mediaSent, frameEnd, "令牌不够：最后一片还排着")
        while pacer.next(now: 10_000_000_000) != nil {}
        XCTAssertEqual(pacer.mediaSent, frameEnd)
    }

    func test_pacer_reports_how_long_to_wait() {
        var pacer = RemoteDatagramPacer(rate: 100_000, now: 0)
        XCTAssertNil(pacer.waitNanos(now: 0), "空队列不用醒")
        for _ in 0..<10 { pacer.enqueue(.media, Data(count: 1000), priority: .media) }
        while pacer.next(now: 0) != nil {}
        let wait = pacer.waitNanos(now: 0)
        XCTAssertNotNil(wait)
        XCTAssertGreaterThan(wait ?? 0, 0)
    }

    // MARK: - 链路估计

    /// 喂一段确定的流量：`rate` 字节 / 秒、每 50 ms 一份报告、往返 `trip`。
    private func feed(_ estimator: inout RemoteLinkEstimator, seconds: Double, packetsPerReport: UInt64 = 50,
                      loss: Double = 0, trip: UInt64 = 100_000_000, start: UInt64,
                      state: inout (sequence: UInt64, received: UInt64, bytes: UInt64), backlog: Bool = false) -> UInt64 {
        var now = start
        for _ in 0..<Int(seconds / 0.05) {
            for _ in 0..<packetsPerReport {
                state.sequence += 1
                estimator.recordSent(sequence: state.sequence, now: now &- trip)
            }
            let delivered = UInt64((1 - loss) * Double(packetsPerReport))
            state.received += delivered
            state.bytes += delivered * 1200
            if backlog { estimator.noteBacklog() }
            estimator.record(RemoteLinkReport(highestSequence: state.sequence, packets: state.received, bytes: state.bytes,
                                              echoSequence: state.sequence, echoHeldMicros: 0), now: now)
            now += 50_000_000
        }
        return now
    }

    func test_estimator_measures_round_trip_and_loss() {
        var estimator = RemoteLinkEstimator(now: 0)
        var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
        _ = feed(&estimator, seconds: 2, loss: 0.05, start: 1_000_000_000, state: &state)
        let result = estimator.state
        XCTAssertEqual(Double(result.roundTripNanos ?? 0) / 1e6, 100, accuracy: 5)
        XCTAssertEqual(result.lossRate, 0.05, accuracy: 0.03)
        XCTAssertEqual(result.deliveryRate, 950 * 1200, accuracy: 300_000)
    }

    /// 这是整个方案的要害：随机丢包不能让速率往下掉。
    func test_random_loss_does_not_lower_the_rate() {
        for loss in [0.01, 0.05, 0.10] {
            var estimator = RemoteLinkEstimator(now: 0)
            var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
            _ = feed(&estimator, seconds: 5, loss: loss, start: 1_000_000_000, state: &state)
            XCTAssertGreaterThanOrEqual(estimator.pacingRate, estimator.config.initialRate, "丢包 \(loss)")
        }
    }

    func test_rate_grows_only_when_something_is_waiting() {
        var idle = RemoteLinkEstimator(now: 0)
        var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
        _ = feed(&idle, seconds: 3, packetsPerReport: 5, start: 1_000_000_000, state: &state)
        XCTAssertEqual(idle.pacingRate, idle.config.initialRate, "没东西发时量不出带宽，不能涨")

        var busy = RemoteLinkEstimator(now: 0)
        state = (0, 0, 0)
        _ = feed(&busy, seconds: 3, packetsPerReport: 200, start: 1_000_000_000, state: &state, backlog: true)
        XCTAssertGreaterThan(busy.pacingRate, busy.config.initialRate * 2)
    }

    /// 限速器后面：发得再快也只送达这么多，节奏不能一直往上涨，否则多发的全是丢包和重传。
    func test_rate_stays_near_what_is_actually_delivered() {
        var estimator = RemoteLinkEstimator(now: 0)
        var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
        _ = feed(&estimator, seconds: 5, start: 1_000_000_000, state: &state, backlog: true)
        let delivered = 50.0 * 1200 / 0.05
        XCTAssertLessThanOrEqual(estimator.pacingRate, delivered * estimator.config.deliveryHeadroom * 1.001)
    }

    /// 撞过一次排队之后只慢慢探：节奏不会很快又冲过上限。
    func test_rate_probes_gently_after_finding_the_ceiling() {
        var estimator = RemoteLinkEstimator(now: 0)
        var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
        var now = feed(&estimator, seconds: 2, packetsPerReport: 200, start: 1_000_000_000, state: &state, backlog: true)
        now = feed(&estimator, seconds: 0.5, packetsPerReport: 200, trip: 300_000_000, start: now, state: &state)
        let afterBackoff = estimator.pacingRate
        _ = feed(&estimator, seconds: 0.5, packetsPerReport: 200, start: now, state: &state, backlog: true)
        XCTAssertGreaterThan(estimator.pacingRate, afterBackoff)
        XCTAssertLessThan(estimator.pacingRate, afterBackoff * 1.5, "5 个往返，每个涨 5%")
    }

    func test_rising_queue_delay_backs_off_below_the_delivered_rate() {
        var estimator = RemoteLinkEstimator(now: 0)
        var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
        var now = feed(&estimator, seconds: 2, start: 1_000_000_000, state: &state, backlog: true)
        let before = estimator.pacingRate
        now = feed(&estimator, seconds: 0.5, trip: 300_000_000, start: now, state: &state)
        XCTAssertLessThan(estimator.pacingRate, before)
        XCTAssertGreaterThan(now, 0)
    }

    /// 每份报告的往返各自加一段随机延迟（数据包和报告两段各 0…`jitter`），可复现。发送端一直有东西等着发，
    /// 按节奏发、链路最多送 10 Mbps：节奏退下去，送达也跟着少（真实链路上就是这样一路退到底的）。
    private func feedJittered(_ estimator: inout RemoteLinkEstimator, seconds: Double, base: UInt64, jitter: UInt64,
                              extra: (Int) -> UInt64 = { _ in 0 }, seed: inout UInt64, start: UInt64,
                              state: inout (sequence: UInt64, received: UInt64, bytes: UInt64)) -> UInt64 {
        func random() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (seed >> 33) % (jitter + 1)
        }
        var now = start
        for step in 0..<Int(seconds / 0.05) {
            let trip = base + random() + random() + extra(step)
            let packets = UInt64(min(52, max(1, Int(estimator.pacingRate * 0.05 / 1200))))
            for _ in 0..<packets {
                state.sequence += 1
                estimator.recordSent(sequence: state.sequence, now: now &- trip)
            }
            state.received += packets
            state.bytes += packets * 1200
            estimator.noteBacklog()
            estimator.record(RemoteLinkReport(highestSequence: state.sequence, packets: state.received, bytes: state.bytes,
                                              echoSequence: state.sequence, echoHeldMicros: 0), now: now)
            now += 50_000_000
        }
        return now
    }

    /// 弱网矩阵「高延迟抖动」：10 Mbps、往返 300 ± 150 ms，每个包各自晚到。最快往返常比基线慢上百毫秒，
    /// 以前当排队，节奏一路退到下限（0.2 Mbps），首个关键帧永远发不完（2026-11-09）。
    func test_jitter_alone_is_not_queueing() {
        for allowance in [0.0, RemoteLinkEstimator.Config().jitterAllowance] {
            var config = RemoteLinkEstimator.Config()
            config.jitterAllowance = allowance
            var estimator = RemoteLinkEstimator(config: config, now: 0)
            var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
            var seed: UInt64 = 7
            _ = feedJittered(&estimator, seconds: 20, base: 150_000_000, jitter: 150_000_000, seed: &seed,
                             start: 1_000_000_000, state: &state)
            if allowance == 0 {
                XCTAssertLessThan(estimator.pacingRate, config.initialRate / 4, "不扣抖动时会一路退（对照）")
            } else {
                XCTAssertGreaterThan(estimator.pacingRate, config.initialRate / 2, "抖动不是排队，节奏不该退")
                XCTAssertGreaterThan(estimator.state.jitterNanos, 30_000_000)
            }
        }
    }

    /// 抖动链路上真排起队来（往返一路变长）照样要退：抖动只从往返变短那一步量，排队不会抬高门槛。
    func test_queue_building_on_a_jittery_link_still_backs_off() {
        var estimator = RemoteLinkEstimator(now: 0)
        var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
        var seed: UInt64 = 11
        var now = feedJittered(&estimator, seconds: 10, base: 150_000_000, jitter: 150_000_000, seed: &seed,
                               start: 1_000_000_000, state: &state)
        let before = estimator.pacingRate
        // 2 秒里排队涨到 1 秒。
        now = feedJittered(&estimator, seconds: 2, base: 150_000_000, jitter: 150_000_000,
                           extra: { UInt64($0) * 25_000_000 }, seed: &seed, start: now, state: &state)
        XCTAssertLessThan(estimator.pacingRate, before)
        XCTAssertGreaterThan(now, 0)
    }

    /// 干净的链路上门槛跟以前一样：往返平稳时抖动接近 0，涨 60 ms 就算排队。
    func test_clean_link_keeps_the_plain_queue_threshold() {
        var estimator = RemoteLinkEstimator(now: 0)
        var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
        var seed: UInt64 = 3
        var now = feedJittered(&estimator, seconds: 5, base: 50_000_000, jitter: 1_000_000, seed: &seed,
                               start: 1_000_000_000, state: &state)
        let before = estimator.pacingRate
        now = feedJittered(&estimator, seconds: 0.5, base: 110_000_000, jitter: 1_000_000, seed: &seed,
                           start: now, state: &state)
        XCTAssertLessThan(estimator.pacingRate, before)
        XCTAssertLessThan(estimator.state.jitterNanos, 2_000_000)
    }

    func test_heavy_loss_backs_off_after_it_persists() {
        var estimator = RemoteLinkEstimator(now: 0)
        var state: (sequence: UInt64, received: UInt64, bytes: UInt64) = (0, 0, 0)
        _ = feed(&estimator, seconds: 4, loss: 0.4, start: 1_000_000_000, state: &state)
        XCTAssertLessThan(estimator.pacingRate, estimator.config.initialRate)
    }

    func test_report_round_trips() throws {
        let report = RemoteLinkReport(highestSequence: 9, packets: 8, bytes: 7, echoSequence: 6, echoHeldMicros: 5)
        XCTAssertEqual(report.encoded().count, RemoteLinkReport.encodedSize)
        XCTAssertEqual(try RemoteLinkReport(decoding: report.encoded()), report)
    }

    // MARK: - 丢包策略

    func test_fec_strength_follows_loss() {
        let far: UInt64 = 100_000_000
        XCTAssertEqual(RemoteLossPolicy.fecGroupSize(lossRate: 0, roundTripNanos: far), 0)
        XCTAssertEqual(RemoteLossPolicy.fecGroupSize(lossRate: 0.01, roundTripNanos: far), 16)
        XCTAssertEqual(RemoteLossPolicy.fecGroupSize(lossRate: 0.03, roundTripNanos: far), 8)
        XCTAssertEqual(RemoteLossPolicy.fecGroupSize(lossRate: 0.07, roundTripNanos: far), 5)
        XCTAssertEqual(RemoteLossPolicy.fecGroupSize(lossRate: 0.2, roundTripNanos: far), 3)
    }

    func test_short_round_trips_rely_on_retransmission() {
        XCTAssertEqual(RemoteLossPolicy.fecGroupSize(lossRate: 0.03, roundTripNanos: 10_000_000), 0)
        XCTAssertEqual(RemoteLossPolicy.fecGroupSize(lossRate: 0.08, roundTripNanos: 10_000_000), 5)
    }

    func test_budget_leaves_room_for_parity() {
        XCTAssertEqual(RemoteLossPolicy.mediaBudgetFactor(fecGroupSize: 0), 1)
        XCTAssertEqual(RemoteLossPolicy.mediaBudgetFactor(fecGroupSize: 4), 0.8, accuracy: 0.001)
    }

    func test_deadline_covers_sending_and_two_retransmissions() {
        let small = RemoteLossPolicy.frameDeadlineMillis(frameBytes: 10_000, roundTripNanos: 100_000_000, pacingRate: 1_000_000)
        XCTAssertEqual(small, 250)
        let key = RemoteLossPolicy.frameDeadlineMillis(frameBytes: 500_000, roundTripNanos: 100_000_000, pacingRate: 1_000_000)
        XCTAssertEqual(key, 740)
        XCTAssertEqual(RemoteLossPolicy.frameDeadlineMillis(frameBytes: 4_000_000, roundTripNanos: 1_000_000_000,
                                                            pacingRate: 100_000), 1500, "普通帧封顶 1.5 s")
        XCTAssertEqual(RemoteLossPolicy.frameDeadlineMillis(frameBytes: 4_000_000, roundTripNanos: 1_000_000_000,
                                                            pacingRate: 100_000, kind: .refresh), 5000,
                       "刷新帧封顶跟着最长等待")
        // 窄链路上的大刷新帧（4K 在 2 Mbps 上）：发得完要多久就给多久；普通帧仍 1.5 s。
        XCTAssertEqual(RemoteLossPolicy.frameDeadlineMillis(frameBytes: 500_000, roundTripNanos: 60_000_000,
                                                            pacingRate: 250_000, kind: .refresh), 2160)
        XCTAssertEqual(RemoteLossPolicy.frameDeadlineMillis(frameBytes: 500_000, roundTripNanos: 60_000_000,
                                                            pacingRate: 250_000), 1500)
        XCTAssertEqual(RemoteLossPolicy.frameWaitCap(deadlineMillis: 100), RemoteLossPolicy.baseFrameWaitNanos)
        XCTAssertEqual(RemoteLossPolicy.frameWaitCap(deadlineMillis: 2160), 3_240_000_000)
        XCTAssertEqual(RemoteLossPolicy.frameWaitCap(deadlineMillis: 5000), RemoteLossPolicy.maxFrameWaitNanos)
    }

    /// 关键帧：手机手上没有能用的参考帧，放弃它也只能再要一个一样大的。时限至少比刷新帧的上限多一点（接收端
    /// 靠这个认出关键帧），封顶 30 s；按计划算出来的再长也照给（节奏估计偏低时计划偏短）。
    func test_keyframes_get_a_longer_deadline_than_refresh_frames() {
        let small = RemoteLossPolicy.frameDeadlineMillis(frameBytes: 10_000, roundTripNanos: 100_000_000,
                                                         pacingRate: 1_000_000, kind: .keyframe)
        XCTAssertEqual(small, 5001)
        XCTAssertGreaterThan(UInt64(small) * 1_000_000, RemoteLossPolicy.maxFrameWaitNanos)
        // 184 KB 在 0.2 Mbps（25 KB/s）上：7.36 s 再加两轮往返。
        XCTAssertEqual(RemoteLossPolicy.frameDeadlineMillis(frameBytes: 184_000, roundTripNanos: 300_000_000,
                                                            pacingRate: 25_000, kind: .keyframe), 8000)
        XCTAssertEqual(RemoteLossPolicy.frameDeadlineMillis(frameBytes: 4_000_000, roundTripNanos: 300_000_000,
                                                            pacingRate: 25_000, kind: .keyframe), 30_000)
        XCTAssertEqual(RemoteLossPolicy.frameWaitCap(deadlineMillis: 5001), 7_501_500_000)
        XCTAssertEqual(RemoteLossPolicy.frameWaitCap(deadlineMillis: 30_000), RemoteLossPolicy.keyframeMaxWaitNanos)
    }

    /// 直连上在途最多攒链路 0.6 s 发得完的量：3G（0.75 Mbps）上码控自己的上限（按 2.2 Mbps 下限和被排队拉长的
    /// 基线算，至少 768 KB）能攒十来秒，排在后面的普通帧全过时限（2026-11-09 3G 直连 0 fps）。宽链路上不起作用。
    func test_inflight_bytes_stay_within_a_fraction_of_a_second_of_the_link() {
        let threeG = RemoteLossPolicy.inflightByteCap(pacingRate: 90_000, roundTripNanos: 300_000_000)
        XCTAssertEqual(threeG, 54_000)
        XCTAssertLessThan(threeG, RemoteDesktopPacer<Int>.defaultInflightBytes / 8)
        XCTAssertEqual(RemoteLossPolicy.inflightByteCap(pacingRate: 90_000, roundTripNanos: 1_920_000_000), 180_000,
                       "往返更长时按往返算，否则一个往返里一帧都确认不回来")
        XCTAssertGreaterThan(RemoteLossPolicy.inflightByteCap(pacingRate: 2_500_000, roundTripNanos: 50_000_000),
                             RemoteDesktopPacer<Int>.defaultInflightBytes, "20 Mbps 上比码控的保底还大，不起作用")
    }

    func test_rate_controller_ignores_light_loss_but_not_heavy_loss() {
        var rate = RemoteRateController(width: 1280, height: 800, path: .direct, now: 0)
        let start = rate.bitrate
        XCTAssertFalse(rate.observeLoss(lossRate: 0.10, now: 1_000_000_000))
        XCTAssertEqual(rate.bitrate, start)
        XCTAssertTrue(rate.observeLoss(lossRate: 0.30, now: 2_000_000_000))
        XCTAssertLessThan(rate.bitrate, start)
    }

    func test_one_lost_frame_is_not_congestion_but_a_burst_is() {
        var rate = RemoteRateController(width: 1280, height: 800, path: .direct, now: 0)
        let start = rate.bitrate
        XCTAssertFalse(rate.observeLostFrames(count: 1, now: 1_000_000_000))
        XCTAssertFalse(rate.observeLostFrames(count: 1, now: 3_000_000_000), "隔太久不算连着丢")
        XCTAssertEqual(rate.bitrate, start)
        XCTAssertTrue(rate.observeLostFrames(count: 3, now: 4_000_000_000))
        XCTAssertLessThan(rate.bitrate, start)
    }
}
