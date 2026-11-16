import CoreGraphics
import XCTest
@testable import uTerm

/// 开流前叫醒显示器：无显示器的 Mac 醒来时占位屏换了号，不能盯着旧号等满时限。
final class RemoteDisplayWakeTests: XCTestCase {
    /// 一台假的 Mac 的显示器状态。`nudge` 之后过 `wakesAfterPolls` 次查询屏幕才醒；`replacesOnWake` 时醒来的是
    /// 一块新号的屏（旧号从在线列表里消失、一直报睡着），同 2026-11-16 mini 上的占位屏。
    private final class FakeDisplays: @unchecked Sendable {
        private let lock = NSLock()
        private var asleep: Set<CGDirectDisplayID>
        private var onlineIDs: [CGDirectDisplayID]
        private var mainID: CGDirectDisplayID
        private var capturable: Set<CGDirectDisplayID> = []
        private var nudged = false
        private var pollsSinceNudge = 0
        private var capturableChecks = 0
        let wakesAfterPolls: Int
        let replacement: CGDirectDisplayID?
        /// 醒来后第几次问「能不能采」才说能（nil = 永远不能）。
        let capturableAfterChecks: Int?

        init(main: CGDirectDisplayID, asleep: Bool, wakesAfterPolls: Int = 2, replacement: CGDirectDisplayID? = nil,
             capturableAfterChecks: Int? = 1) {
            mainID = main
            onlineIDs = [main]
            self.asleep = asleep ? [main] : []
            self.wakesAfterPolls = wakesAfterPolls
            self.replacement = replacement
            self.capturableAfterChecks = capturableAfterChecks
            if !asleep { capturable = [main] }
        }

        var nudgeCount: Int { lock.withLock { nudged ? 1 : 0 } }
        var capturableCheckCount: Int { lock.withLock { capturableChecks } }

        var probe: RemoteDisplayWake.Probe {
            RemoteDisplayWake.Probe(
                isAsleep: { id in self.lock.withLock { self.tick(); return self.asleep.contains(id) || !self.onlineIDs.contains(id) } },
                online: { self.lock.withLock { self.onlineIDs } },
                main: { self.lock.withLock { self.mainID } },
                isCapturable: { id in
                    self.lock.withLock {
                        self.capturableChecks += 1
                        guard let after = self.capturableAfterChecks, self.capturableChecks >= after else { return false }
                        return self.capturable.contains(id)
                    }
                },
                nudge: { self.lock.withLock { self.nudged = true } },
                poll: .milliseconds(1))
        }

        /// 在锁里调：叫醒之后每查一次算一拍，够了就醒（或换成新号的屏）。
        private func tick() {
            guard nudged, !asleep.isEmpty else { return }
            pollsSinceNudge += 1
            guard pollsSinceNudge >= wakesAfterPolls else { return }
            if let replacement {
                onlineIDs = [replacement]
                mainID = replacement
                capturable = [replacement]
                // 旧号的「睡着」留着：系统对一块已移除的屏一直这么报。
            } else {
                asleep.removeAll()
                capturable = Set(onlineIDs)
            }
        }
    }

    func testTargetKeepsRequestedWhileOnlineAndFallsBackToMain() {
        XCTAssertEqual(RemoteDisplayWake.target(requested: 5, online: [5, 6], main: 6), 5)
        XCTAssertEqual(RemoteDisplayWake.target(requested: 0xd, online: [0xe], main: 0xe), 0xe)
    }

    /// mini 的冷开屏：睡着的占位屏 0xd 醒来时被换成 0xe。不能等满 3 秒。
    func testReplacedPlaceholderDoesNotWaitForTheWakeLimit() async {
        let displays = FakeDisplays(main: 0xd, asleep: true, replacement: 0xe)
        let started = ContinuousClock.now
        await RemoteDisplayWake.wake(display: 0xd, probe: displays.probe)
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(displays.nudgeCount, 1)
        XCTAssertLessThan(elapsed, .milliseconds(500), "盯着旧号会等满 \(RemoteDisplayWake.wakeLimit)")
    }

    func testAwakeDisplayReturnsAtOnceWithoutNudging() async {
        let displays = FakeDisplays(main: 1, asleep: false)
        await RemoteDisplayWake.wake(display: 1, probe: displays.probe)
        XCTAssertEqual(displays.nudgeCount, 0)
        XCTAssertEqual(displays.capturableCheckCount, 0)
    }

    /// 醒来后一列进可采集的显示器就返回，不再固定睡 400 ms。
    func testReturnsAsSoonAsTheDisplayIsCapturable() async {
        let displays = FakeDisplays(main: 1, asleep: true, capturableAfterChecks: 3)
        let started = ContinuousClock.now
        await RemoteDisplayWake.wake(display: 1, probe: displays.probe)
        XCTAssertEqual(displays.capturableCheckCount, 3)
        XCTAssertLessThan(ContinuousClock.now - started, RemoteDisplayWake.capturableLimit)
    }

    /// 一直列不出来：最多等 `capturableLimit`，不比原来的固定等待更久。
    func testGivesUpOnCapturableAfterTheLimit() async {
        let displays = FakeDisplays(main: 1, asleep: true, capturableAfterChecks: nil)
        let started = ContinuousClock.now
        await RemoteDisplayWake.wake(display: 1, probe: displays.probe)
        let elapsed = ContinuousClock.now - started
        XCTAssertGreaterThanOrEqual(elapsed, RemoteDisplayWake.capturableLimit)
        XCTAssertLessThan(elapsed, RemoteDisplayWake.capturableLimit + .milliseconds(300))
    }

    /// 建虚拟屏之前读占位屏的模式：只要醒着，不问采集。
    func testWithoutCapturableSkipsTheCaptureCheck() async {
        let displays = FakeDisplays(main: 0xd, asleep: true, replacement: 0xe)
        await RemoteDisplayWake.wake(display: 0xd, untilCapturable: false, probe: displays.probe)
        XCTAssertEqual(displays.capturableCheckCount, 0)
    }
}
