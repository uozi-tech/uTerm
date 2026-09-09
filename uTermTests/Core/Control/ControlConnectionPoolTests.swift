import SwiftData
import XCTest
@testable import uTerm

/// 连接池：懒建 / 复用 / 显式释放 / 全量释放 / 空闲回收 / 主机密钥质询缓存与 `trust` 配对。
/// 建连闭包全部注入（池本身不认识 SSH），所以这些用例不碰网络也不碰钥匙串。
@MainActor
final class ControlConnectionPoolTests: XCTestCase {

    // MARK: 夹具

    /// 假的 exec 通道：记自己被关过没有。
    private actor FakeChannel: ControlExecChannel {
        let serial: Int
        private(set) var closed = false

        init(serial: Int) { self.serial = serial }

        func exec(_ command: String) async throws -> String { "ran:\(command)" }
        func close() { closed = true }
        func isClosed() -> Bool { closed }
    }

    /// 建连次数 + 产出的通道，供断言「懒建」与「复用」。
    private actor Factory {
        private(set) var made: [FakeChannel] = []
        var error: ControlConnectError?
        private(set) var trusted: [(UUID, String)] = []

        func setError(_ error: ControlConnectError?) { self.error = error }

        func make() throws -> FakeChannel {
            if let error { throw error }
            let channel = FakeChannel(serial: made.count)
            made.append(channel)
            return channel
        }

        func recordTrust(_ id: UUID, _ fingerprint: String) { trusted.append((id, fingerprint)) }
        func count() -> Int { made.count }
        func channel(_ index: Int) -> FakeChannel { made[index] }
        func trustedCount() -> Int { trusted.count }
        func lastTrusted() -> (UUID, String)? { trusted.last }
    }

    /// 可推进的假时钟，用来把「空闲 10 分钟」压成一瞬。
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            value = value.addingTimeInterval(seconds)
        }
    }

    private func makeSpec(name: String = "prod-web", id: UUID = UUID()) throws -> HostConnectionSpec {
        let container = try ModelContainer(
            for: ServerProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return HostConnectionSpec(
            id: id,
            name: name,
            profile: SSHConnection.ProfileSnapshot(host: "10.0.0.1", port: 22, jumpHost: nil),
            auth: .password(username: "root", password: "p"),
            jumpAuth: nil,
            container: container
        )
    }

    private func makePool(
        factory: Factory,
        clock: Clock,
        idleInterval: Duration = .seconds(600)
    ) -> ControlConnectionPool {
        let connector = ControlConnectionPool.Connector(
            makeExec: { _ in try await factory.make() },
            makeSFTP: { _ in throw ControlConnectError.connectFailed("测试不建 SFTP") },
            trustHostKey: { spec, fingerprint in await factory.recordTrust(spec.id, fingerprint) }
        )
        return ControlConnectionPool(
            connector: connector,
            idleInterval: idleInterval,
            now: { [clock] in clock.now }
        )
    }

    // MARK: 懒建 / 复用

    func testExecutorIsBuiltLazilyAndReusedPerHost() async throws {
        let factory = Factory()
        let clock = Clock()
        let pool = makePool(factory: factory, clock: clock)
        let spec = try makeSpec()

        // 还没要过执行器 —— 一条连接都不该建。
        var held = await pool.heldHostIDs()
        XCTAssertTrue(held.isEmpty)
        var made = await factory.count()
        XCTAssertEqual(made, 0)

        _ = try await pool.executor(for: spec)
        _ = try await pool.executor(for: spec, maxLines: 10, maxBytes: 100)
        made = await factory.count()
        XCTAssertEqual(made, 1, "同一台主机只该建一次连接")

        held = await pool.heldHostIDs()
        XCTAssertEqual(held, [spec.id])
        XCTAssertEqual(pool.heldHostIDsNow(), [spec.id], "同步镜像要跟着走（resolveHost 那条路要用）")

        let other = try makeSpec(name: "prod-db")
        _ = try await pool.executor(for: other)
        made = await factory.count()
        XCTAssertEqual(made, 2, "另一台主机要另建一条")
        await pool.disconnectAll()
    }

    /// 请求给的裁剪参数落到返回的执行器上，但**连接是复用的**。
    func testExecutorCarriesPerRequestLimits() async throws {
        let factory = Factory()
        let pool = makePool(factory: factory, clock: Clock())
        let spec = try makeSpec()

        let defaults = try await pool.executor(for: spec)
        XCTAssertEqual(defaults.maxLines, ControlProtocol.defaultMaxLines)
        XCTAssertEqual(defaults.maxBytes, ControlProtocol.defaultMaxBytes)

        let custom = try await pool.executor(for: spec, maxLines: 7, maxBytes: 77)
        XCTAssertEqual(custom.maxLines, 7)
        XCTAssertEqual(custom.maxBytes, 77)
        let made = await factory.count()
        XCTAssertEqual(made, 1)
        await pool.disconnectAll()
    }

    // MARK: 释放

    func testDisconnectClosesAndForgetsOneHost() async throws {
        let factory = Factory()
        let pool = makePool(factory: factory, clock: Clock())
        let spec = try makeSpec()
        _ = try await pool.executor(for: spec)

        await pool.disconnect(hostID: spec.id)
        let held = await pool.heldHostIDs()
        XCTAssertTrue(held.isEmpty)
        XCTAssertTrue(pool.heldHostIDsNow().isEmpty)
        let closed = await factory.channel(0).isClosed()
        XCTAssertTrue(closed, "释放必须真的关掉连接，否则 fd 泄漏")

        // 再要一次执行器 → 重新建连。
        _ = try await pool.executor(for: spec)
        let made = await factory.count()
        XCTAssertEqual(made, 2)
        await pool.disconnectAll()
    }

    func testDisconnectAllReleasesEveryHost() async throws {
        let factory = Factory()
        let pool = makePool(factory: factory, clock: Clock())
        let a = try makeSpec(name: "a")
        let b = try makeSpec(name: "b")
        _ = try await pool.executor(for: a)
        _ = try await pool.executor(for: b)

        await pool.disconnectAll()
        let held = await pool.heldHostIDs()
        XCTAssertTrue(held.isEmpty)
        for index in 0..<2 {
            let closed = await factory.channel(index).isClosed()
            XCTAssertTrue(closed)
        }
    }

    // MARK: 空闲回收

    func testIdleHostsAreReclaimedAfterTheInterval() async throws {
        let factory = Factory()
        let clock = Clock()
        let pool = makePool(factory: factory, clock: clock, idleInterval: .seconds(600))
        let spec = try makeSpec()
        _ = try await pool.executor(for: spec)

        clock.advance(599)
        _ = await pool.sweepIdle()
        var held = await pool.heldHostIDs()
        XCTAssertEqual(held, [spec.id], "还没到点，不该回收")

        clock.advance(2)
        _ = await pool.sweepIdle()
        held = await pool.heldHostIDs()
        XCTAssertTrue(held.isEmpty, "空闲超过间隔应被回收")
        try await waitUntil("空闲连接被关闭") { await factory.channel(0).isClosed() }
        await pool.disconnectAll()
    }

    /// 用过就该续命：touch 之后重新计时，不该被上一次的 `lastUsedAt` 拖去回收。
    func testUsingAHostPostponesReclaim() async throws {
        let factory = Factory()
        let clock = Clock()
        let pool = makePool(factory: factory, clock: clock, idleInterval: .seconds(600))
        let spec = try makeSpec()
        _ = try await pool.executor(for: spec)

        clock.advance(500)
        _ = try await pool.executor(for: spec)   // 复用一次 = 续命
        clock.advance(500)
        _ = await pool.sweepIdle()
        let held = await pool.heldHostIDs()
        XCTAssertEqual(held, [spec.id])
        await pool.disconnectAll()
    }

    // MARK: 主机密钥质询与 trust 配对

    func testHostKeyChallengeIsCachedForTrust() async throws {
        let factory = Factory()
        let pool = makePool(factory: factory, clock: Clock())
        let spec = try makeSpec()

        var cached = await pool.lastHostKeyChallenge(hostID: spec.id)
        XCTAssertNil(cached, "还没建过连就不该有质询 —— trust 此时要回 invalid_request")

        await factory.setError(.hostKeyUnknown(fingerprint: "SHA256:abc", algorithm: ""))
        do {
            _ = try await pool.executor(for: spec)
            XCTFail("未知主机密钥必须拒绝，绝不自动 TOFU")
        } catch let error as ControlConnectError {
            XCTAssertEqual(error.code, .host_key_unknown)
        }

        cached = await pool.lastHostKeyChallenge(hostID: spec.id)
        let recorded = try XCTUnwrap(cached)
        let fingerprint = recorded.newFingerprint
        let recordedHost = recorded.host
        let recordedPort = recorded.port
        XCTAssertEqual(fingerprint, "SHA256:abc")
        XCTAssertEqual(recordedHost, "10.0.0.1")
        XCTAssertEqual(recordedPort, 22)
        guard case .unknown = recorded.kind else {
            return XCTFail("首连应是 unknown 质询")
        }
        let held = await pool.heldHostIDs()
        XCTAssertTrue(held.isEmpty, "建连失败不该在池里留下半条记录")

        try await pool.trustHostKey(host: spec, fingerprint: "SHA256:abc")
        let trusted = await factory.lastTrusted()
        XCTAssertEqual(trusted?.0, spec.id)
        XCTAssertEqual(trusted?.1, "SHA256:abc")
        let after = await pool.lastHostKeyChallenge(hostID: spec.id)
        XCTAssertNil(after, "信任成功后质询必须作废，免得下次 trust 拿着陈旧指纹批准")
    }

    func testChangedHostKeyIsCachedAsMismatch() async throws {
        let factory = Factory()
        let pool = makePool(factory: factory, clock: Clock())
        let spec = try makeSpec()
        await factory.setError(.hostKeyChanged(fingerprint: "SHA256:new", algorithm: ""))

        do {
            _ = try await pool.executor(for: spec)
            XCTFail("密钥变更必须拒绝")
        } catch let error as ControlConnectError {
            XCTAssertEqual(error.code, .host_key_changed)
        }
        let stored = await pool.lastHostKeyChallenge(hostID: spec.id)
        let cached = try XCTUnwrap(stored)
        guard case .mismatch = cached.kind else {
            return XCTFail("密钥变更应缓存成 mismatch —— trust 据此直接回 host_key_changed")
        }
    }

    // MARK: 工具

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等不到：\(what)")
    }
}
