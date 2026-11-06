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
        XCTAssertLessThanOrEqual(RemoteLossPolicy.frameDeadlineMillis(frameBytes: 4_000_000, roundTripNanos: 1_000_000_000,
                                                                      pacingRate: 100_000), 1500)
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
