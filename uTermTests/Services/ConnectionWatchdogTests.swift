import XCTest
@testable import uTerm

@MainActor
final class ConnectionWatchdogTests: XCTestCase {

    private final class ProbeSpy: ConnectionHealthProbing {
        private(set) var probeCount = 0
        func probeConnectionHealth() async { probeCount += 1 }
    }

    func testSweepProbesAllRegisteredObjects() async {
        let dog = ConnectionWatchdog(observingSystemEvents: false)
        let a = ProbeSpy()
        let b = ProbeSpy()
        dog.register(a)
        dog.register(b)

        await dog.sweep()

        XCTAssertEqual(a.probeCount, 1)
        XCTAssertEqual(b.probeCount, 1)
    }

    /// 同一对象重复注册（视图重建会反复触发 connect）只占一个槽位。
    func testRegisterIsIdempotentPerObject() async {
        let dog = ConnectionWatchdog(observingSystemEvents: false)
        let a = ProbeSpy()
        dog.register(a)
        dog.register(a)

        await dog.sweep()

        XCTAssertEqual(a.probeCount, 1)
    }

    /// 弱引用注册表：对象释放（窗格关闭）后不再被探测，也不阻止释放。
    func testDeallocatedEntriesAreSkipped() async {
        let dog = ConnectionWatchdog(observingSystemEvents: false)
        let keep = ProbeSpy()
        dog.register(keep)
        do {
            let gone = ProbeSpy()
            dog.register(gone)
        }

        await dog.sweep()

        XCTAssertEqual(keep.probeCount, 1)
    }

    /// `scheduleSweep` 在 settle 窗口内合并重复触发（唤醒 + 网络恢复几乎同时来）。
    func testScheduleSweepCoalescesWithinSettleWindow() async {
        let dog = ConnectionWatchdog(observingSystemEvents: false)
        dog.settleDelay = .milliseconds(50)
        let a = ProbeSpy()
        dog.register(a)

        dog.scheduleSweep()
        dog.scheduleSweep()
        dog.scheduleSweep()

        // 等过 settle 窗口 + 富余量，让合并后的那一次扫描完成。
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(a.probeCount, 1)
    }

    /// `NWPathMonitor` 启动时会立即回调一次当前路径；首次 satisfied 只记录状态，
    /// 避免应用带网启动时无谓探测。
    func testInitialSatisfiedPathUpdateDoesNotSweep() async {
        let dog = ConnectionWatchdog(observingSystemEvents: false)
        dog.settleDelay = .milliseconds(50)
        let a = ProbeSpy()
        dog.register(a)

        dog.handlePathUpdate(satisfied: true)

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(a.probeCount, 0)
    }

    /// Wi-Fi / 热点 / VPN 切换常见表现是 satisfied → satisfied，而不是先
    /// unsatisfied；后续可用路径更新必须主动扫一次，才能及时判死半开 SSH。
    func testSatisfiedToSatisfiedPathUpdateSchedulesSweep() async {
        let dog = ConnectionWatchdog(observingSystemEvents: false)
        dog.settleDelay = .milliseconds(50)
        let a = ProbeSpy()
        dog.register(a)

        dog.handlePathUpdate(satisfied: true)
        dog.handlePathUpdate(satisfied: true)

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(a.probeCount, 1)
    }

    func testUnsatisfiedToSatisfiedPathUpdateSchedulesSweep() async {
        let dog = ConnectionWatchdog(observingSystemEvents: false)
        dog.settleDelay = .milliseconds(50)
        let a = ProbeSpy()
        dog.register(a)

        dog.handlePathUpdate(satisfied: false)
        dog.handlePathUpdate(satisfied: true)

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(a.probeCount, 1)
    }
}
