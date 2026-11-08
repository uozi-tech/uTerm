import UIKit
import XCTest
@testable import uTermMobile

/// 远控相关的省电改动：重连退避不再轮询、问中继「谁在线」只在有界面显示时进行。
@MainActor
final class RemotePowerTests: XCTestCase {
    // MARK: - 重连退避的等待

    func testRetryGateWakesEarlyOnKick() async {
        let gate = RemoteRetryGate()
        let waiting = Task { await gate.wait(.seconds(30)) }
        try? await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        gate.kick()
        let woke = await waiting.value
        XCTAssertTrue(woke, "被叫醒要报 true，调用方据此重置退避")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "叫醒应当是立即的")
    }

    func testRetryGateTimesOutWithoutKick() async {
        let gate = RemoteRetryGate()
        let started = ContinuousClock.now
        let woke = await gate.wait(.milliseconds(80))
        XCTAssertFalse(woke)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(80), "不能提前返回")
    }

    func testOneKickWakesEveryWaiter() async {
        let gate = RemoteRetryGate()
        let waiters = (0..<4).map { _ in Task { await gate.wait(.seconds(30)) } }
        try? await Task.sleep(for: .milliseconds(50))
        gate.kick()
        for waiter in waiters {
            let woke = await waiter.value
            XCTAssertTrue(woke, "网络恢复时每个在退避的标签都该马上重试")
        }
    }

    func testCancelledWaitReturnsPromptlyAsNotWoken() async {
        let gate = RemoteRetryGate()
        let waiting = Task { await gate.wait(.seconds(30)) }
        try? await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        waiting.cancel()
        let woke = await waiting.value
        XCTAssertFalse(woke, "取消不算被叫醒")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "关标签时退避等待要立即结束")
    }

    func testKickBeforeWaitDoesNotCarryOver() async {
        let gate = RemoteRetryGate()
        gate.kick()
        let woke = await gate.wait(.milliseconds(50))
        XCTAssertFalse(woke, "等待开始之前的叫醒不算（和以前的语义一样）")
    }

    func testCancelledWaitDoesNotSwallowLaterKicks() async {
        let gate = RemoteRetryGate()
        let cancelled = Task { await gate.wait(.seconds(30)) }
        try? await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        _ = await cancelled.value
        let waiting = Task { await gate.wait(.seconds(30)) }
        try? await Task.sleep(for: .milliseconds(30))
        gate.kick()
        let woke = await waiting.value
        XCTAssertTrue(woke)
    }

    // MARK: - 问中继谁在线

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private let relay = RemoteRelayConfig(name: "测试中继", host: "relay.invalid", port: 47310, relayID: "test",
                                          key: Data(count: 32).base64EncodedString())

    /// 已启用远控、没有真实钥匙串与 Bonjour 的目录；问中继的次数记在 `counter` 里。
    private func directory(interval: Duration, counter: Counter) throws -> RemoteMacDirectory {
        let suite = "RemotePowerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        // 直接写「已启用」，不调 activate()：那会开始 Bonjour 浏览。
        defaults.set(true, forKey: DefaultsKey.remoteBrowseActivated)
        return RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()), defaults: defaults,
                                  relayPollInterval: interval) { _ in
            counter.increment()
            return []
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { return XCTFail("等待超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testRelayIsAskedOnceWhenNothingShowsOnlineStatus() async throws {
        let counter = Counter()
        let directory = try directory(interval: .milliseconds(50), counter: counter)
        XCTAssertTrue(directory.importRelayConfig(relay))
        try await waitUntil { counter.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, 1, "没有界面显示在线状态时只问这一次，不再按间隔一直问")
    }

    func testRelayIsPolledWhileAViewShowsStatusAndStopsAfterward() async throws {
        let counter = Counter()
        let directory = try directory(interval: .milliseconds(50), counter: counter)
        XCTAssertTrue(directory.importRelayConfig(relay))
        try await waitUntil { counter.count == 1 }

        let watcher = Task { await directory.keepLiveStatusFresh() }
        try await waitUntil { counter.count >= 4 }

        watcher.cancel()
        await watcher.value
        let afterLeaving = counter.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, afterLeaving, "界面消失后不再问")
    }

    func testPollingPausesInBackgroundAndResumesInForeground() async throws {
        let counter = Counter()
        let directory = try directory(interval: .milliseconds(50), counter: counter)
        // 前后台通知由 iOS 的生命周期桥接转给目录（目录本身两端共享，不认 UIApplication）。
        directory.lifecycle = RemoteMacDirectoryLifecycle(directory: directory)
        XCTAssertTrue(directory.importRelayConfig(relay))
        let watcher = Task { await directory.keepLiveStatusFresh() }
        defer { watcher.cancel() }
        try await waitUntil { counter.count >= 3 }

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let inBackground = counter.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(counter.count, inBackground + 1, "后台不问（最多收尾正在进行的那一次）")

        let beforeForeground = counter.count
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await waitUntil { counter.count >= beforeForeground + 3 }
    }

    func testReadingOnlineMacsRefreshesStaleStatus() async throws {
        let counter = Counter()
        let directory = try directory(interval: .milliseconds(300), counter: counter)
        XCTAssertTrue(directory.importRelayConfig(relay))
        try await waitUntil { counter.count == 1 }

        _ = directory.pairedMacs
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counter.count, 1, "刚问过就不再问")

        try await Task.sleep(for: .milliseconds(300))
        _ = directory.pairedMacs
        try await waitUntil { counter.count == 2 }
        _ = directory.pairedMacs
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counter.count, 2, "抽屉反复求值不会一读一问")
    }

    func testNotActivatedDirectoryDoesNotPollForAView() async throws {
        let counter = Counter()
        let suite = "RemotePowerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let directory = RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                           defaults: defaults, relayPollInterval: .milliseconds(50)) { _ in
            counter.increment()
            return []
        }
        XCTAssertTrue(directory.importRelayConfig(relay))
        try await waitUntil { counter.count == 1 }
        let watcher = Task { await directory.keepLiveStatusFresh() }
        try await Task.sleep(for: .milliseconds(200))
        watcher.cancel()
        await watcher.value
        XCTAssertEqual(counter.count, 1, "没启用远控（还没点「控制我的 Mac」）时主机页不按间隔问中继")
    }
}
