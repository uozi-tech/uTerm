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
        /// 建连耗时。用来把「并发冷启动」这个竞态做成必然发生。
        var delay: Duration?
        private(set) var trusted: [(UUID, String)] = []

        func setError(_ error: ControlConnectError?) { self.error = error }
        func setDelay(_ delay: Duration?) { self.delay = delay }

        func make() async throws -> FakeChannel {
            if let delay { try? await Task.sleep(for: delay) }
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

    /// 假 SFTP 会话：只要能被池借出 / 归还 / 关闭即可，读写全部落到内存树上
    /// （`MockSFTP` 已经是产品协议的完整实现，直接复用，别再抄第二份）。
    private actor SFTPFactory {
        private(set) var made: [MockSFTP] = []
        var error: ControlConnectError?
        var delay: Duration?

        func setError(_ error: ControlConnectError?) { self.error = error }
        func setDelay(_ delay: Duration?) { self.delay = delay }

        func make() async throws -> MockSFTP {
            if let delay { try? await Task.sleep(for: delay) }
            if let error { throw error }
            let session = MockSFTP()
            made.append(session)
            return session
        }

        func count() -> Int { made.count }
        func session(_ index: Int) -> MockSFTP { made[index] }
        func closedCount() async -> Int {
            var closed = 0
            for session in made {
                if await session.didClose { closed += 1 }
            }
            return closed
        }
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
        idleInterval: Duration = .seconds(600),
        sftpFactory: SFTPFactory? = nil,
        maxSFTPChannels: Int = ControlConnectionPool.maxSFTPChannelsPerHost
    ) -> ControlConnectionPool {
        let connector = ControlConnectionPool.Connector(
            makeExec: { _ in try await factory.make() },
            makeSFTP: { _ in
                guard let sftpFactory else {
                    throw ControlConnectError.connectFailed("测试不建 SFTP")
                }
                return try await sftpFactory.make()
            },
            trustHostKey: { spec, fingerprint in await factory.recordTrust(spec.id, fingerprint) }
        )
        return ControlConnectionPool(
            connector: connector,
            idleInterval: idleInterval,
            maxSFTPChannels: maxSFTPChannels,
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

    // MARK: 并发冷启动

    /// 同一台主机的两条并发请求撞在「还没建好」的窗口里，只该建**一条**连接。
    ///
    /// 回归的是一个真实泄漏：没有 in-flight 占位时两边各建一条，后者覆盖前者入表，
    /// 前者永远没人 `close()` —— 本机 fd 泄漏，远端还多一条看不见的 SSH 会话。
    func testConcurrentColdStartsShareASingleConnection() async throws {
        let factory = Factory()
        let pool = makePool(factory: factory, clock: Clock())
        let spec = try makeSpec()
        await factory.setDelay(.milliseconds(200))

        async let first = pool.executor(for: spec)
        async let second = pool.executor(for: spec, maxLines: 5, maxBytes: 50)
        let executors = try await [first, second]
        XCTAssertEqual(executors.count, 2)
        XCTAssertEqual(executors[1].maxLines, 5, "搭车者仍拿到自己那份裁剪参数")

        let made = await factory.count()
        XCTAssertEqual(made, 1, "并发冷启动只该建一条连接（否则后者覆盖前者 = fd 泄漏）")
        let held = await pool.heldHostIDs()
        XCTAssertEqual(held, [spec.id], "池里只该有一条记录")
        await pool.disconnectAll()
    }

    /// 并发冷启动一起失败：两边都拿到错误，且占位被清掉 —— 下一次请求要能重新建连，
    /// 不能一直「记得」上次失败。
    func testConcurrentColdStartFailuresClearTheInFlightSlot() async throws {
        let factory = Factory()
        let pool = makePool(factory: factory, clock: Clock())
        let spec = try makeSpec()
        await factory.setDelay(.milliseconds(150))
        await factory.setError(.connectFailed("网络不通"))

        async let first = pool.executor(for: spec)
        async let second = pool.executor(for: spec)
        var codes: [ControlErrorCode] = []
        do {
            _ = try await first
            XCTFail("建连失败时不该拿到执行器")
        } catch {
            codes.append((error as? ControlConnectError)?.code ?? .operation_failed)
        }
        do {
            _ = try await second
            XCTFail("搭车者也该拿到同一个失败")
        } catch {
            codes.append((error as? ControlConnectError)?.code ?? .operation_failed)
        }
        XCTAssertEqual(codes, [.connect_failed, .connect_failed])
        var held = await pool.heldHostIDs()
        XCTAssertTrue(held.isEmpty, "建连失败不该在池里留下半条记录")

        // 占位已清 → 恢复正常后能重新建连。
        await factory.setError(nil)
        await factory.setDelay(nil)
        _ = try await pool.executor(for: spec)
        held = await pool.heldHostIDs()
        XCTAssertEqual(held, [spec.id])
        await pool.disconnectAll()
    }

    /// 并发冷启动撞上主机密钥未信任：两边都拒，且质询照样缓存给 `trust`。
    func testConcurrentColdStartsStillCacheTheHostKeyChallenge() async throws {
        let factory = Factory()
        let pool = makePool(factory: factory, clock: Clock())
        let spec = try makeSpec()
        await factory.setDelay(.milliseconds(100))
        await factory.setError(.hostKeyUnknown(fingerprint: "SHA256:abc", algorithm: ""))

        async let first = pool.executor(for: spec)
        async let second = pool.executor(for: spec)
        _ = try? await first
        _ = try? await second

        let challenge = await pool.lastHostKeyChallenge(hostID: spec.id)
        let cached = try XCTUnwrap(challenge)
        XCTAssertEqual(cached.newFingerprint, "SHA256:abc")
        await pool.disconnectAll()
    }

    // MARK: SFTP 多通道

    /// 4 个并发借用 → 4 条会话（各自独立的 SSH 连接），这是分片并行传输的前提。
    func testConcurrentBorrowsOpenUpToTheChannelLimit() async throws {
        let sftpFactory = SFTPFactory()
        let pool = makePool(factory: Factory(), clock: Clock(), sftpFactory: sftpFactory)
        let spec = try makeSpec()
        await sftpFactory.setDelay(.milliseconds(80))

        let sessions = try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<4 {
                group.addTask { ObjectIdentifier(try await pool.borrowSFTP(for: spec)) }
            }
            var ids: Set<ObjectIdentifier> = []
            for try await id in group { ids.insert(id) }
            return ids
        }
        XCTAssertEqual(sessions.count, 4, "4 个并发借用要拿到 4 条不同的会话")
        let made = await sftpFactory.count()
        XCTAssertEqual(made, 4)
        await pool.disconnectAll()
    }

    /// 到上限后第 5 个借用要**等**，等到有人归还才复用那一条 —— 不再多建。
    func testBorrowBeyondTheLimitWaitsAndReusesAReturnedSession() async throws {
        let sftpFactory = SFTPFactory()
        let pool = makePool(factory: Factory(), clock: Clock(),
                            sftpFactory: sftpFactory, maxSFTPChannels: 2)
        let spec = try makeSpec()

        let first = try await pool.borrowSFTP(for: spec)
        let second = try await pool.borrowSFTP(for: spec)
        var made = await sftpFactory.count()
        XCTAssertEqual(made, 2)

        let waiting = Task { ObjectIdentifier(try await pool.borrowSFTP(for: spec)) }
        // 还没人归还 → 第三个必须挂着，不能偷偷建第三条。
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(waiting.isCancelled)
        made = await sftpFactory.count()
        XCTAssertEqual(made, 2, "到上限后不该再建新会话")

        await pool.returnSFTP(first, for: spec.id)
        let got = try await waiting.value
        XCTAssertEqual(got, ObjectIdentifier(first), "等到的应该正是刚归还那条")
        made = await sftpFactory.count()
        XCTAssertEqual(made, 2)

        await pool.returnSFTP(second, for: spec.id)
        await pool.disconnectAll()
    }

    /// 顺序借还只用一条会话（不归还才会逼池子多建）。
    func testSequentialBorrowsReuseASingleSession() async throws {
        let sftpFactory = SFTPFactory()
        let pool = makePool(factory: Factory(), clock: Clock(), sftpFactory: sftpFactory)
        let spec = try makeSpec()

        for _ in 0..<5 {
            let session = try await pool.borrowSFTP(for: spec)
            await pool.returnSFTP(session, for: spec.id)
        }
        let made = await sftpFactory.count()
        XCTAssertEqual(made, 1, "借完就还的话一条就够，不该每次都新建")
        await pool.disconnectAll()
    }

    /// `withSFTP` 抛错也要归还 —— 否则一条错误路径就烧掉一个名额。
    func testWithSFTPReturnsTheSessionEvenOnFailure() async throws {
        let sftpFactory = SFTPFactory()
        let pool = makePool(factory: Factory(), clock: Clock(),
                            sftpFactory: sftpFactory, maxSFTPChannels: 1)
        let spec = try makeSpec()

        struct Boom: Error {}
        for _ in 0..<3 {
            do {
                try await pool.withSFTP(for: spec) { _ -> Void in throw Boom() }
                XCTFail("闭包抛错时 withSFTP 必须把错误透出来")
            } catch is Boom {
                // 预期
            }
        }
        // 名额没被烧掉 → 还能正常借到（上限是 1，漏还的话这句会挂死）。
        let value = try await pool.withSFTP(for: spec) { _ in 42 }
        XCTAssertEqual(value, 42)
        let made = await sftpFactory.count()
        XCTAssertEqual(made, 1)
        await pool.disconnectAll()
    }

    /// `disconnectAll` 关掉这台主机的**全部** SFTP 会话（空闲的和借出中的都算）。
    func testDisconnectAllClosesEverySFTPChannel() async throws {
        let sftpFactory = SFTPFactory()
        let pool = makePool(factory: Factory(), clock: Clock(), sftpFactory: sftpFactory)
        let spec = try makeSpec()

        let borrowed = try await pool.borrowSFTP(for: spec)
        let second = try await pool.borrowSFTP(for: spec)
        await pool.returnSFTP(second, for: spec.id)   // 一条空闲、一条仍借出

        await pool.disconnectAll()
        let held = await pool.heldHostIDs()
        XCTAssertTrue(held.isEmpty)
        try await waitUntil("两条会话都被关闭") { await sftpFactory.closedCount() == 2 }

        // 借出中的那条归还时池里已无记录 → 也会被关掉（这里它本来就关了，
        // 断言的是归还路径不炸、也不把它塞回一个已释放的主机）。
        await pool.returnSFTP(borrowed, for: spec.id)
        let after = await pool.heldHostIDs()
        XCTAssertTrue(after.isEmpty, "归还不能把已释放的主机重新塞回池里")
    }

    /// 空闲的 SFTP 会话跟 exec 一样按 `lastUsedAt` 回收；借出中的不回收
    /// （长传输期间被抽走会直接断掉正在进行的分片）。
    func testIdleSFTPChannelsAreReclaimedButBorrowedOnesAreNot() async throws {
        let sftpFactory = SFTPFactory()
        let clock = Clock()
        let pool = makePool(factory: Factory(), clock: clock,
                            idleInterval: .seconds(600), sftpFactory: sftpFactory)
        let spec = try makeSpec()

        let borrowed = try await pool.borrowSFTP(for: spec)
        clock.advance(601)
        _ = await pool.sweepIdle()
        var held = await pool.heldHostIDs()
        XCTAssertEqual(held, [spec.id], "有会话正借在外面就不该回收")

        await pool.returnSFTP(borrowed, for: spec.id)
        clock.advance(601)
        _ = await pool.sweepIdle()
        held = await pool.heldHostIDs()
        XCTAssertTrue(held.isEmpty, "全部归还且空闲超时后应被回收")
        try await waitUntil("空闲会话被关闭") { await sftpFactory.closedCount() == 1 }
    }

    /// 建连失败要把占住的名额还回去，否则这台主机的 SFTP 通道会被慢慢烧光。
    func testFailedSFTPConnectReleasesTheSlot() async throws {
        let sftpFactory = SFTPFactory()
        let pool = makePool(factory: Factory(), clock: Clock(),
                            sftpFactory: sftpFactory, maxSFTPChannels: 1)
        let spec = try makeSpec()
        await sftpFactory.setError(.connectFailed("网络不通"))

        for _ in 0..<3 {
            do {
                _ = try await pool.borrowSFTP(for: spec)
                XCTFail("建连失败时不该拿到会话")
            } catch let error as ControlConnectError {
                XCTAssertEqual(error.code, .connect_failed)
            }
        }
        let held = await pool.heldHostIDs()
        XCTAssertTrue(held.isEmpty, "建连失败不该在池里留下半条记录")

        await sftpFactory.setError(nil)
        let session = try await pool.borrowSFTP(for: spec)
        await pool.returnSFTP(session, for: spec.id)
        await pool.disconnectAll()
    }

    /// 主机密钥未信任在 SFTP 路径上同样要缓存质询，`trust` 才有指纹可核对。
    func testSFTPHostKeyChallengeIsCached() async throws {
        let sftpFactory = SFTPFactory()
        let pool = makePool(factory: Factory(), clock: Clock(), sftpFactory: sftpFactory)
        let spec = try makeSpec()
        await sftpFactory.setError(.hostKeyUnknown(fingerprint: "SHA256:sftp", algorithm: ""))

        do {
            _ = try await pool.borrowSFTP(for: spec)
            XCTFail("未知主机密钥必须拒绝")
        } catch let error as ControlConnectError {
            XCTAssertEqual(error.code, .host_key_unknown)
        }
        let challenge = await pool.lastHostKeyChallenge(hostID: spec.id)
        let cached = try XCTUnwrap(challenge)
        XCTAssertEqual(cached.newFingerprint, "SHA256:sftp")
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
