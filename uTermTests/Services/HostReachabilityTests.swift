import XCTest
@testable import uTerm

@MainActor
final class HostReachabilityTests: XCTestCase {

    /// 可控的探测：记下每次调用，`release()` 之前一律挂起；结果按端点查表（缺省 = 握得上）。
    private actor ProbeGate {
        private(set) var calls: [HostEndpointKey] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private var results: [HostEndpointKey: Bool] = [:]

        init(open: Bool = false, results: [HostEndpointKey: Bool] = [:]) {
            self.isOpen = open
            self.results = results
        }

        func probe(_ key: HostEndpointKey) async -> Bool {
            calls.append(key)
            if !isOpen { await withCheckedContinuation { waiters.append($0) } }
            return results[key] ?? true
        }

        func release() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private let a = HostEndpointKey(host: "10.0.0.1", port: 22)
    private let b = HostEndpointKey(host: "10.0.0.2", port: 22)

    private func waitUntil(_ condition: @MainActor () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("条件在 1 秒内没有满足", file: file, line: line)
    }

    func testProbeResultLandsOnEntry() async {
        let gate = ProbeGate(open: true, results: [b: false])
        let monitor = HostReachabilityMonitor(probe: { await gate.probe($0) })
        let ta = Task { await monitor.watch(a) }
        let tb = Task { await monitor.watch(b) }

        await waitUntil { monitor.entry(for: a).status != .unknown && monitor.entry(for: b).status != .unknown }
        XCTAssertEqual(monitor.entry(for: a).status, .online)
        XCTAssertEqual(monitor.entry(for: b).status, .offline)
        ta.cancel(); tb.cancel()
    }

    /// 多台主机指向同一端点（或同一行重复出现）只握一次手。
    func testSameEndpointIsProbedOnce() async {
        let gate = ProbeGate()
        let monitor = HostReachabilityMonitor(probe: { await gate.probe($0) })
        let t1 = Task { await monitor.watch(a) }
        let t2 = Task { await monitor.watch(a) }
        await waitUntil { await gate.calls.count == 1 }
        await gate.release()
        await waitUntil { monitor.entry(for: a).status == .online }

        let calls = await gate.calls
        XCTAssertEqual(calls, [a])
        t1.cancel(); t2.cancel()
    }

    /// 排队期间滚出屏幕的行不再探测 —— 快速滚过长列表不会排出一长串握手。
    func testQueuedEndpointIsSkippedOnceNobodyWatches() async {
        let gate = ProbeGate()
        let monitor = HostReachabilityMonitor(probe: { await gate.probe($0) }, maxConcurrent: 1)
        let ta = Task { await monitor.watch(a) }
        await waitUntil { await gate.calls.count == 1 }
        let tb = Task { await monitor.watch(b) }
        await Task.yield()
        tb.cancel()
        await tb.value

        await gate.release()
        await waitUntil { monitor.entry(for: a).status == .online }
        try? await Task.sleep(for: .milliseconds(30))

        let calls = await gate.calls
        XCTAssertEqual(calls, [a])
        XCTAssertEqual(monitor.entry(for: b).status, .unknown)
        ta.cancel()
    }

    /// 刚探过的端点重新出现不补探；超过 `staleAfter` 才补。
    func testReappearingRowOnlyReprobesWhenStale() async {
        let gate = ProbeGate(open: true)
        let clock = Clock()
        let monitor = HostReachabilityMonitor(probe: { await gate.probe($0) },
                                              staleAfter: 120,
                                              now: { clock.now })
        let first = Task { await monitor.watch(a) }
        await waitUntil { monitor.entry(for: a).status == .online }
        first.cancel()
        await first.value

        clock.now += 60
        let fresh = Task { await monitor.watch(a) }
        try? await Task.sleep(for: .milliseconds(30))
        var calls = await gate.calls
        XCTAssertEqual(calls.count, 1, "两分钟内重新出现不该再握手")
        fresh.cancel()
        await fresh.value

        clock.now += 120
        let stale = Task { await monitor.watch(a) }
        await waitUntil { await gate.calls.count == 2 }
        calls = await gate.calls
        XCTAssertEqual(calls, [a, a])
        stale.cancel()
    }

    /// 可见期间按 `refreshInterval` 周期重探。
    func testVisibleRowIsReprobedPeriodically() async {
        let gate = ProbeGate(open: true)
        let clock = Clock()
        let monitor = HostReachabilityMonitor(probe: { await gate.probe($0) },
                                              refreshInterval: .milliseconds(40),
                                              now: { clock.now })
        let t = Task { await monitor.watch(a) }
        await waitUntil { await gate.calls.count == 1 }
        clock.now += 300
        await waitUntil { await gate.calls.count >= 2 }
        t.cancel()
    }

    /// 探测关闭（XCTest 宿主里的 `shared`）时什么都不发，状态保持未知。
    func testDisabledProbeKeepsUnknown() async {
        let monitor = HostReachabilityMonitor(probe: nil)
        let t = Task { await monitor.watch(a) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(monitor.entry(for: a).status, .unknown)
        t.cancel()
    }

    func testMonogram() {
        XCTAssertEqual(ServerProfile.monogram(for: "web-01"), "W")
        XCTAssertEqual(ServerProfile.monogram(for: "  db"), "D")
        XCTAssertEqual(ServerProfile.monogram(for: "生产库"), "生")
        XCTAssertEqual(ServerProfile.monogram(for: "   "), "?")
        XCTAssertEqual(ServerProfile.monogram(for: ""), "?")
    }
}
