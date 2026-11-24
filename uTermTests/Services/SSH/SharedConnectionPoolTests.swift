import Foundation
import XCTest
@testable import uTerm

/// `SharedConnectionPool` 的复用 / 去重 / 引用计数 / 断开分发。用假连接，不握真手。
final class SharedConnectionPoolTests: XCTestCase {

    func testSameKeyReusesOneConnection() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()

        let first = try await pool.acquire("host") { await counter.makeConnection() }
        let second = try await pool.acquire("host") { await counter.makeConnection() }

        XCTAssertEqual(first.origin, .created)
        XCTAssertEqual(second.origin, .reused)
        XCTAssertTrue(first.connection === second.connection)
        XCTAssertNotEqual(first.lease, second.lease)
        let connects = await counter.count
        XCTAssertEqual(connects, 1, "同一 key 的第二次借用不能再握一次手")
    }

    func testDifferentKeysGetSeparateConnections() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()

        let a = try await pool.acquire("a") { await counter.makeConnection() }
        let b = try await pool.acquire("b") { await counter.makeConnection() }

        XCTAssertFalse(a.connection === b.connection)
        let connects = await counter.count
        XCTAssertEqual(connects, 2)
    }

    /// 打开工作区时终端与 SFTP 侧栏同时建连：只能握一次手。
    func testConcurrentAcquiresShareOneInFlightConnect() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()
        let gate = Gate()
        let connect: @Sendable @concurrent () async throws -> FakeConnection = {
            let connection = await counter.makeConnection()
            await gate.wait()
            return connection
        }

        async let first = pool.acquire("host", connect: connect)
        try await waitUntil { await counter.count == 1 }
        async let second = pool.acquire("host", connect: connect)
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()

        let results = try await [first, second]
        XCTAssertEqual(Set(results.map { $0.origin }), [.created, .joined])
        XCTAssertTrue(results[0].connection === results[1].connection)
        let connects = await counter.count
        XCTAssertEqual(connects, 1)
        let open = await pool.connectionCount(for: "host")
        XCTAssertEqual(open, 1)
    }

    func testConnectionClosesOnlyAfterLastLeaseReturns() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()
        let first = try await pool.acquire("host") { await counter.makeConnection() }
        let second = try await pool.acquire("host") { await counter.makeConnection() }

        await pool.release(first.lease)
        XCTAssertEqual(first.connection.closeCount, 0, "还有人在用，不能断开")
        XCTAssertTrue(first.connection.isAlive)

        await pool.release(second.lease)
        XCTAssertEqual(first.connection.closeCount, 1)
        let open = await pool.connectionCount(for: "host")
        XCTAssertEqual(open, 0)
    }

    func testReleasingTwiceDoesNotCloseForOthers() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()
        let first = try await pool.acquire("host") { await counter.makeConnection() }
        _ = try await pool.acquire("host") { await counter.makeConnection() }

        await pool.release(first.lease)
        await pool.release(first.lease)

        XCTAssertEqual(first.connection.closeCount, 0, "重复归还不能把别人的那份也算掉")
    }

    func testFullConnectionOpensAnother() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 2)
        let counter = ConnectCounter()

        let a = try await pool.acquire("host") { await counter.makeConnection() }
        let b = try await pool.acquire("host") { await counter.makeConnection() }
        let c = try await pool.acquire("host") { await counter.makeConnection() }

        XCTAssertTrue(a.connection === b.connection)
        XCTAssertFalse(a.connection === c.connection, "超过每条连接的租约上限要另开一条（sshd MaxSessions）")
        XCTAssertEqual(c.origin, .created)

        await pool.release(a.lease)
        let d = try await pool.acquire("host") { await counter.makeConnection() }
        XCTAssertEqual(d.origin, .reused, "腾出位置后接着复用已有连接")
        let connects = await counter.count
        XCTAssertEqual(connects, 2)
    }

    /// 对端断开（或某个使用方判死）：这条连接上的每个使用方都要收到，之后重新建连。
    func testTransportCloseNotifiesEveryLeaseAndEvicts() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()
        let notified = Recorder()
        let first = try await pool.acquire("host") { await counter.makeConnection() }
        let second = try await pool.acquire("host") { await counter.makeConnection() }
        await pool.onClosed(first.lease) { notified.record("first") }
        await pool.onClosed(second.lease) { notified.record("second") }

        first.connection.simulateRemoteClose()
        try await waitUntil { notified.values.count == 2 }

        XCTAssertEqual(Set(notified.values), ["first", "second"])
        let next = try await pool.acquire("host") { await counter.makeConnection() }
        XCTAssertEqual(next.origin, .created)
        XCTAssertFalse(next.connection === first.connection)
    }

    func testReleasedLeaseIsNotNotifiedLater() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()
        let notified = Recorder()
        let leaving = try await pool.acquire("host") { await counter.makeConnection() }
        let staying = try await pool.acquire("host") { await counter.makeConnection() }
        await pool.onClosed(leaving.lease) { notified.record("leaving") }
        await pool.onClosed(staying.lease) { notified.record("staying") }

        await pool.release(leaving.lease)
        staying.connection.simulateRemoteClose()
        try await waitUntil { notified.values.count == 1 }

        XCTAssertEqual(notified.values, ["staying"])
    }

    func testSubscribingToDeadConnectionCallsBackImmediately() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()
        let notified = Recorder()
        let acquired = try await pool.acquire("host") { await counter.makeConnection() }

        // 断了但断开回调还没到池子里（或根本没触发）。
        acquired.connection.markDeadSilently()
        await pool.onClosed(acquired.lease) { notified.record("late") }

        XCTAssertEqual(notified.values, ["late"])
    }

    func testDeadConnectionIsNotReused() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()
        let stale = try await pool.acquire("host") { await counter.makeConnection() }

        stale.connection.markDeadSilently()
        let fresh = try await pool.acquire("host") { await counter.makeConnection() }

        XCTAssertEqual(fresh.origin, .created)
        XCTAssertFalse(fresh.connection === stale.connection)
    }

    func testConnectFailureReachesJoinersAndNextAcquireRetries() async throws {
        let pool = SharedConnectionPool<String, FakeConnection>(maxLeasesPerConnection: 6)
        let counter = ConnectCounter()
        let gate = Gate()
        let failing: @Sendable @concurrent () async throws -> FakeConnection = {
            _ = await counter.makeConnection()
            await gate.wait()
            throw FakeConnectError()
        }

        async let first = pool.acquire("host", connect: failing)
        try await waitUntil { await counter.count == 1 }
        async let second = pool.acquire("host", connect: failing)
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()

        var failures = 0
        do { _ = try await first } catch { failures += 1 }
        do { _ = try await second } catch { failures += 1 }
        XCTAssertEqual(failures, 2, "等同一次建连的两个调用方都要拿到失败")
        let failedConnects = await counter.count
        XCTAssertEqual(failedConnects, 1, "等同一次建连的调用方共享同一个失败")

        let retry = try await pool.acquire("host") { await counter.makeConnection() }
        XCTAssertEqual(retry.origin, .created, "失败不能卡死后续建连")
    }

    // MARK: - SharedSSHKey

    func testSSHKeyGroupsByTargetAndCredential() {
        let profile = SSHConnection.ProfileSnapshot(host: "10.0.0.2", port: 22, jumpHost: nil)
        let auth = ResolvedAuth.password(username: "root", password: "secret")

        XCTAssertEqual(
            SharedSSHKey(profile: profile, auth: auth, jumpHostAuth: nil),
            SharedSSHKey(profile: profile, auth: auth, jumpHostAuth: nil))
        XCTAssertNotEqual(
            SharedSSHKey(profile: profile, auth: auth, jumpHostAuth: nil),
            SharedSSHKey(profile: profile,
                         auth: .password(username: "root", password: "changed"),
                         jumpHostAuth: nil),
            "改了密码不能借到用旧密码登录的连接")
        XCTAssertNotEqual(
            SharedSSHKey(profile: profile, auth: auth, jumpHostAuth: nil),
            SharedSSHKey(profile: profile,
                         auth: .password(username: "deploy", password: "secret"),
                         jumpHostAuth: nil))
        let viaJump = SSHConnection.ProfileSnapshot(
            host: "10.0.0.2", port: 22,
            jumpHost: .init(host: "bastion", port: 22))
        XCTAssertNotEqual(
            SharedSSHKey(profile: profile, auth: auth, jumpHostAuth: nil),
            SharedSSHKey(profile: viaJump, auth: auth, jumpHostAuth: auth))
    }

    func testSSHKeyDoesNotKeepSecretsInPlainText() {
        let profile = SSHConnection.ProfileSnapshot(host: "10.0.0.2", port: 22, jumpHost: nil)
        let key = SharedSSHKey(profile: profile,
                               auth: .password(username: "root", password: "hunter2"),
                               jumpHostAuth: nil)
        XCTAssertFalse(key.credential.contains("hunter2"))
        XCTAssertEqual(key.credential.count, 64)
    }

    // MARK: - 辅助

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("等待条件超时")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct FakeConnectError: Error {}

extension SharedConnectionPoolTests {
    /// 判死一条共享连接：断开要好几秒才完成（这期间 `isAlive` 还是真），但从判死那一刻起就不能再借给别人，
    /// 上面的租约立刻收到断开通知。
    func testInvalidatedConnectionIsNeverHandedOutWhileItCloses() async throws {
        let pool = SharedConnectionPool<String, SlowClosingConnection>(maxLeasesPerConnection: 6)
        let first = try await pool.acquire("host") { SlowClosingConnection() }
        let notified = Flag()
        await pool.onClosed(first.lease) { notified.raise() }

        let closing = Task { await pool.invalidate(first.lease) }
        try await waitUntil { first.connection.closeStarted }
        XCTAssertTrue(first.connection.isAlive, "前提：断开还没完成")
        XCTAssertTrue(notified.isRaised, "判死时就通知租约，不等断开完成")

        let next = try await pool.acquire("host") { SlowClosingConnection() }
        XCTAssertEqual(next.origin, .created, "正在关的连接不能再借出去")
        XCTAssertFalse(next.connection === first.connection)
        first.connection.finishClose()
        await closing.value
    }
}

/// 断开要等 `finishClose()` 才完成的假连接（模拟经跳板机的内层连接最多等 5 秒）。
private final class SlowClosingConnection: PooledConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var finished = false

    var isAlive: Bool { lock.withLock { alive } }
    var closeStarted: Bool { lock.withLock { started } }

    func onTransportClosed(_ handler: @escaping @Sendable () -> Void) {}

    func closeTransport() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                started = true
                if finished { return true }
                waiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
        lock.withLock { alive = false }
    }

    func finishClose() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            finished = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

private final class FakeConnection: PooledConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    private var closes = 0
    private var handler: (@Sendable () -> Void)?

    var isAlive: Bool { lock.withLock { alive } }
    var closeCount: Int { lock.withLock { closes } }

    func onTransportClosed(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    func closeTransport() async {
        lock.withLock { closes += 1 }
        simulateRemoteClose()
    }

    func simulateRemoteClose() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            alive = false
            return self.handler
        }
        handler?()
    }

    func markDeadSilently() {
        lock.withLock { alive = false }
    }
}

private actor ConnectCounter {
    private(set) var count = 0

    func makeConnection() -> FakeConnection {
        count += 1
        return FakeConnection()
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] { lock.withLock { recorded } }

    func record(_ value: String) {
        lock.withLock { recorded.append(value) }
    }
}
