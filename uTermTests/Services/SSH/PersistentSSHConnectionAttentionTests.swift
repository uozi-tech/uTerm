import Foundation
import NIOCore
import Synchronization
import SwiftData
import XCTest
import USSHTestServer
@testable import uTerm
@testable import USSHKit

/// `PersistentSSHConnection` 的重连碰到「重试也不会好」的失败时：不结束会话、不换会话 id，停下来等用户，
/// 用户处理完点重试 → 重新读凭据 → 接回**同一个**会话。
///
/// 主机这头是进程内测试服务端，exec 通道上跑一个说保持进程帧协议的替身（不需要 Linux 主机与真的 uterm-holder）。
final class PersistentSSHConnectionAttentionTests: XCTestCase {

    /// 服务端的开关：拒不拒绝登录。
    private final class Switches: Sendable {
        let rejectLogins = Mutex(false)
        let attachPayloads = Mutex<[[UInt8]]>([])
        /// 接入时先回放的输出（在 replayEnd 之前）。新建的会话这就是 shell 刚启动时打的东西。
        let replay = Mutex<[UInt8]>([])
        /// 接下来这么多次接入在回放到一半时把整条 SSH 连接掐掉（replayEnd 之前）。
        let dropDuringReplay = Mutex(0)
    }

    /// 保持进程的替身：回 helloReply、接入后回 replayEnd、输入原样回显成 output；terminate 时报 exited(0)。
    private static func fakeHolder(_ switches: Switches) -> SSHTestExecHandler {
        SSHTestExecHandler { context in
            var reader = HolderFrameReader()
            func send(_ frame: HolderFrame) async throws {
                try await context.write(ByteBuffer(bytes: frame.encoded()))
            }
            for await chunk in context.stdin {
                chunk.withUnsafeReadableBytes { reader.append($0) }
                while let frame = try reader.next() {
                    switch frame.kind {
                    case .hello:
                        try await send(HolderFrame(.helloReply, payload: HolderHelloReply(
                            version: 1, shellPID: 4242, createdAt: 0, cols: 80, rows: 24,
                            exitStatus: nil, attributes: []).encoded()))
                    case .attach:
                        switches.attachPayloads.withLock { $0.append(frame.payload) }
                        let replay = switches.replay.withLock { $0 }
                        if !replay.isEmpty { try await send(HolderFrame(.output, payload: replay)) }
                        let drop = switches.dropDuringReplay.withLock { value -> Bool in
                            guard value > 0 else { return false }
                            value -= 1
                            return true
                        }
                        if drop {
                            try await send(HolderFrame(.output, payload: Array("half a replay".utf8)))
                            context.channel.parent?.close(promise: nil)
                            return .noStatus
                        }
                        var end = HolderByteWriter()
                        end.u64(0)
                        try await send(HolderFrame(.replayEnd, payload: end.bytes))
                    case .input:
                        if String(decoding: frame.payload, as: UTF8.self).contains("quit") {
                            // shell 自己退出了。
                            var status = HolderByteWriter()
                            status.i32(0)
                            try await send(HolderFrame(.exited, payload: status.bytes))
                            return .status(0)
                        }
                        try await send(HolderFrame(.output, payload: frame.payload))
                    case .terminate:
                        var status = HolderByteWriter()
                        status.i32(0)
                        try await send(HolderFrame(.exited, payload: status.bytes))
                        return .status(0)
                    default:
                        break
                    }
                }
            }
            return .status(0)
        }
    }

    /// 服务端此刻只认哪些登录（nil = 都认）。
    private final class Requirement: @unchecked Sendable {
        private let lock = NSLock()
        private var rule: (@Sendable (SSHTestAuthAttempt) -> Bool)?
        func set(_ rule: @escaping @Sendable (SSHTestAuthAttempt) -> Bool) { lock.withLock { self.rule = rule } }
        func allows(_ attempt: SSHTestAuthAttempt) -> Bool { lock.withLock { rule }?(attempt) ?? true }
    }

    private final class PromptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    func testPermanentReconnectFailureWaitsForTheUserAndResumesTheSameSession() async throws {
        let switches = Switches()
        var configuration = SSHTestServer.Configuration(
            authentication: SSHTestAuthentication(custom: { _ in !switches.rejectLogins.withLock { $0 } }),
            exec: Self.fakeHolder(switches))
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }

        let container = try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let resolutions = Counter()
        let sessionID = UUID()
        let backend = PersistentSSHConnection(
            sessionID: sessionID,
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "old"),
            jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container),
            hostKeyApprover: { _ in true },
            resolveSettings: { [port = server.port] in
                await resolutions.increment()
                return PersistentSSHConnection.ResolvedSettings(
                    profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil),
                    auth: .password(username: "tester", password: "new"), jump: nil)
            })
        try await backend.connect()
        XCTAssertEqual(switches.attachPayloads.withLock { $0.count }, 1)

        // 服务器开始拒绝登录，然后连接断了：重连碰到认证失败，停下来等用户——会话不结束。
        switches.rejectLogins.withLock { $0 = true }
        var attention = backend.attention.makeAsyncIterator()
        await server.dropAllConnections()
        let reason = await attention.next()
        XCTAssertNotNil(reason ?? nil, "应当报出要用户处理的原因")
        XCTAssertFalse(backend.hostSessionHasEnded, "主机上的会话还在，不能当成没了")
        let resolvedBeforeRetry = await resolutions.value
        XCTAssertEqual(resolvedBeforeRetry, 0, "没等用户就不重新读凭据")

        // 等一会儿：不会自己再去登录。
        let attemptsWhileWaiting = server.events.authAttempts.count
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(server.events.authAttempts.count, attemptsWhileWaiting, "停下等用户时不自动重试")

        // 用户处理好了，点重试：重新读凭据，接回同一个会话（只要断开之后的字节，不再 --create）。
        switches.rejectLogins.withLock { $0 = false }
        await backend.retryAfterAttention()
        let cleared = await attention.next()
        XCTAssertEqual(cleared ?? "unexpected", nil)
        let reattached = try await server.waitForEvents(timeout: .seconds(10)) { _ in
            switches.attachPayloads.withLock { $0.count } == 2
        }
        let resolvedAfterRetry = await resolutions.value
        XCTAssertEqual(resolvedAfterRetry, 1)
        let attachCommands = reattached.execCommands.filter { $0.contains("attach --id \(sessionID.uuidString)") }
        XCTAssertEqual(attachCommands.count, 2, "两次接入都是同一个会话")
        XCTAssertFalse(attachCommands.last?.contains("--create") ?? true, "接回不是新建")
        XCTAssertEqual(switches.attachPayloads.withLock { $0.last }, HostHolderAttach.fromOffset(0))
        XCTAssertFalse(backend.hostSessionHasEnded)

        // 接回之后输入照常回显。
        let output = Task { () -> String in
            for await item in backend.outputItems {
                if case .bytes(let data) = item, String(decoding: data, as: UTF8.self).contains("after-retry") {
                    return "after-retry"
                }
            }
            return ""
        }
        await backend.write(Data("after-retry".utf8))
        let echoed = await output.value
        XCTAssertEqual(echoed, "after-retry")
        await backend.close()
    }

    /// 保持进程说会话没了（shell 退出）：这才算主机上的会话结束（界面据此换 id）。
    func testHolderReportedExitEndsTheHostSession() async throws {
        let switches = Switches()
        let server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: Self.fakeHolder(switches)))
        defer { Task { await server.stop() } }
        let container = try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let backend = PersistentSSHConnection(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "x"), jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        try await backend.connect()
        XCTAssertFalse(backend.hostSessionHasEnded)
        await backend.write(Data("quit".utf8))
        for await _ in backend.exitStream { break }
        XCTAssertTrue(backend.hostSessionHasEnded)
        await backend.close()
    }

    // MARK: - 第一次就没连上

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// 第一个输出块是历史（`.history`，查询不答）还是实时的（`.bytes`，查询照答）。
    private func firstOutputIsHistory(_ backend: PersistentSSHConnection) async -> Bool? {
        for await item in backend.outputItems {
            switch item {
            case .history: return true
            case .bytes: return false
            default: continue
            }
        }
        return nil
    }

    /// 第一次连接就失败（服务器拒了登录）：后端从没接上过主机上的会话。界面据此重试时**不当成接回**，
    /// 新 shell 启动时打的东西（这里是一条终端查询 DA1）按实时输出处理、照常回答，不是当成历史吞掉。
    func testFailedFirstConnectNeverAttachedSoTheRetryIsANewSession() async throws {
        let switches = Switches()
        switches.rejectLogins.withLock { $0 = true }
        switches.replay.withLock { $0 = Array("\u{1b}[c".utf8) }
        let server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: SSHTestAuthentication(custom: { _ in !switches.rejectLogins.withLock { $0 } }),
            exec: Self.fakeHolder(switches)))
        defer { Task { await server.stop() } }
        let container = try makeContainer()
        let sessionID = UUID()
        func backend(resumes: Bool) -> PersistentSSHConnection {
            PersistentSSHConnection(
                sessionID: sessionID, resumesSession: resumes,
                profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
                auth: .password(username: "tester", password: "x"), jumpHostAuth: nil,
                hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        }

        let first = backend(resumes: false)
        do {
            try await first.connect()
            XCTFail("服务器拒了登录，应当连不上")
        } catch {}
        XCTAssertFalse(first.hostSessionHasEnded)
        XCTAssertFalse(first.hasAttachedToHostSession, "没接上过")

        // 界面的规则（`MobileTerminalController`）：接着连同一个 id，接回与否 = 之前就是接回 || 接上过。
        let resumes = false || first.hasAttachedToHostSession
        switches.rejectLogins.withLock { $0 = false }
        let second = backend(resumes: resumes)
        try await second.connect()
        let history = await firstOutputIsHistory(second)
        XCTAssertEqual(history, false, "新会话启动时的输出要按实时处理（终端查询要回答）")
        XCTAssertTrue(server.events.execCommands.last?.contains("--create") ?? false)
        XCTAssertTrue(second.hasAttachedToHostSession)
        await second.close()

        // 对照：错当成接回的话（修之前的行为），同样的输出被当成历史。
        let wrong = PersistentSSHConnection(
            sessionID: UUID(), resumesSession: true,
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "x"), jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        try await wrong.connect()
        let wrongHistory = await firstOutputIsHistory(wrong)
        XCTAssertEqual(wrongHistory, true)
        await wrong.close()
    }

    // MARK: - 重试时重读整份设置

    /// 先连上，再让服务器只认 `accepts` 的登录、断开：重连停下来等用户。返回等待原因的迭代器。
    private func connectThenRequire(
        _ accepts: @escaping @Sendable (SSHTestAuthAttempt) -> Bool,
        resolve: @escaping PersistentSSHConnection.SettingsResolver,
        approver: @escaping @Sendable (HostKeyChallenge) async -> Bool = { _ in true },
        jumpHost: SSHConnection.ProfileSnapshot.JumpHostSnapshot? = nil,
        jumpAuth: ResolvedAuth? = nil,
        port: Int? = nil,
        server: SSHTestServer,
        requirement: Requirement
    ) async throws -> (PersistentSSHConnection, AsyncStream<String?>.Iterator) {
        let backend = PersistentSSHConnection(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port ?? server.port, jumpHost: jumpHost),
            auth: .password(username: "old-user", password: "pw"), jumpHostAuth: jumpAuth,
            hostKeyVerifier: HostKeyVerifier(modelContainer: try makeContainer()),
            hostKeyApprover: approver, resolveSettings: resolve)
        try await backend.connect()
        requirement.set(accepts)
        var attention = backend.attention.makeAsyncIterator()
        await server.dropAllConnections()
        let reason = await attention.next()
        XCTAssertNotNil(reason ?? nil, "应当停下来等用户")
        return (backend, attention)
    }

    private func startTarget(_ requirement: Requirement,
                             switches: Switches) async throws -> SSHTestServer {
        try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: SSHTestAuthentication(custom: { attempt in
                requirement.allows(attempt)
            }),
            exec: Self.fakeHolder(switches)))
    }

    private func reattached(_ switches: Switches, count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if switches.attachPayloads.withLock({ $0.count }) >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// 认证失败后用户改了**用户名**：重试用的是新用户名（不是建标签时那份）。
    func testRetryPicksUpAnEditedUsername() async throws {
        let switches = Switches()
        let requirement = Requirement()
        let server = try await startTarget(requirement, switches: switches)
        defer { Task { await server.stop() } }
        let profile = SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil)

        let (backend, _) = try await connectThenRequire({ $0.username == "new-user" }, resolve: {
            PersistentSSHConnection.ResolvedSettings(
                profile: profile, auth: .password(username: "new-user", password: "pw"), jump: nil)
        }, server: server, requirement: requirement)

        await backend.retryAfterAttention()
        let ok = await reattached(switches, count: 2)
        XCTAssertTrue(ok, "改了用户名之后应当接回")
        XCTAssertEqual(server.events.authAttempts.last(where: \.accepted)?.username, "new-user")
        await backend.close()
    }

    /// 认证失败后用户把认证方式从密码换成了私钥：重试用私钥登录。
    func testRetryPicksUpASwitchFromPasswordToKey() async throws {
        let switches = Switches()
        let requirement = Requirement()
        let server = try await startTarget(requirement, switches: switches)
        defer { Task { await server.stop() } }
        let profile = SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil)

        let (backend, _) = try await connectThenRequire({ attempt in
            if case .publicKey = attempt.method { return true }
            return false
        }, resolve: {
            PersistentSSHConnection.ResolvedSettings(
                profile: profile,
                auth: .privateKey(username: "old-user", pem: KeyImportFixtures.ed25519OpenSSH, passphrase: nil),
                jump: nil)
        }, server: server, requirement: requirement)

        await backend.retryAfterAttention()
        let ok = await reattached(switches, count: 2)
        XCTAssertTrue(ok, "换成私钥之后应当接回")
        guard case .publicKey = server.events.authAttempts.last(where: \.accepted)?.method else {
            return XCTFail("应当用私钥登录")
        }
        await backend.close()
    }

    /// 跳板机那一跳认证失败，用户改了跳板机（换了一台、填了正确的凭据）：重试走新的跳板机。
    func testRetryPicksUpAnEditedJumpHost() async throws {
        let switches = Switches()
        let requirement = Requirement()
        let target = try await startTarget(Requirement(), switches: switches)
        defer { Task { await target.stop() } }
        let oldBastion = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: SSHTestAuthentication(custom: { attempt in
                requirement.allows(attempt)
            })))
        defer { Task { await oldBastion.stop() } }
        let newBastion = try await SSHTestServer.start(SSHTestServer.Configuration(authentication: .acceptAnyone))
        defer { Task { await newBastion.stop() } }
        let fixed = SSHConnection.ProfileSnapshot(
            host: "127.0.0.1", port: target.port, jumpHost: .init(host: "127.0.0.1", port: newBastion.port))

        let (backend, _) = try await connectThenRequire({ _ in false }, resolve: {
            PersistentSSHConnection.ResolvedSettings(
                profile: fixed, auth: .password(username: "old-user", password: "pw"),
                jump: .password(username: "jumper", password: "right"))
        }, jumpHost: .init(host: "127.0.0.1", port: oldBastion.port),
           jumpAuth: .password(username: "jumper", password: "wrong"),
           port: target.port, server: oldBastion, requirement: requirement)

        await backend.retryAfterAttention()
        let ok = await reattached(switches, count: 2)
        XCTAssertTrue(ok, "改了跳板机之后应当接回")
        XCTAssertFalse(newBastion.events.authAttempts.isEmpty, "走的是新的跳板机")
        await backend.close()
    }

    /// 重读的设置把目标的端口改了：会话 id 属于原来那台机器，拒绝接，停在等用户、说清楚原因，不去登录。
    func testRetryRefusesWhenTheHostMovedToAnotherMachine() async throws {
        let switches = Switches()
        let requirement = Requirement()
        let server = try await startTarget(requirement, switches: switches)
        defer { Task { await server.stop() } }
        let moved = SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port + 1, jumpHost: nil)

        let waiting = try await connectThenRequire({ _ in false }, resolve: {
            PersistentSSHConnection.ResolvedSettings(
                profile: moved, auth: .password(username: "old-user", password: "pw"), jump: nil)
        }, server: server, requirement: requirement)
        let backend = waiting.0
        var attention = waiting.1
        let attemptsBefore = server.events.authAttempts.count

        await backend.retryAfterAttention()
        let reason = await attention.next()
        XCTAssertEqual(reason ?? nil, PersistentSSHConnection.HostMovedError().errorDescription)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.events.authAttempts.count, attemptsBefore, "不去新地址登录")
        XCTAssertFalse(backend.hostSessionHasEnded)
        await backend.close()
    }

    /// 停在等用户时关标签：后台去结束主机上的会话时不弹主机密钥确认（标签已经没了）。
    func testClosingWhileWaitingNeverPromptsForTheHostKey() async throws {
        let switches = Switches()
        let first = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: Self.fakeHolder(switches)))
        let port = first.port
        let prompts = PromptCounter()
        let backend = PersistentSSHConnection(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil),
            auth: .password(username: "tester", password: "pw"), jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: try makeContainer()),
            hostKeyApprover: { _ in prompts.next() == 1 })
        try await backend.connect()
        XCTAssertEqual(prompts.count, 1)

        // 同一个端口上换了一台主机密钥不同的服务器：重连要确认密钥，用户（替身）拒绝 → 停下来等用户。
        var attention = backend.attention.makeAsyncIterator()
        await first.stop()
        let second: SSHTestServer
        do {
            second = try await SSHTestServer.start(SSHTestServer.Configuration(
                authentication: .acceptAnyone, exec: Self.fakeHolder(switches)), port: port)
        } catch {
            throw XCTSkip("端口 \(port) 一时绑不回来：\(error)")
        }
        defer { Task { await second.stop() } }
        await backend.recheckAfterDisruption(lostInterface: true)
        let reason = await attention.next()
        XCTAssertNotNil(reason ?? nil)
        let promptsBeforeClose = prompts.count

        await backend.close()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(prompts.count, promptsBeforeClose, "标签关了之后不能再弹信任框")
    }

    // MARK: - 第一次接入时连接断了

    private func makeBackend(_ server: SSHTestServer, resumes: Bool) throws -> PersistentSSHConnection {
        PersistentSSHConnection(
            sessionID: UUID(), resumesSession: resumes,
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "x"), jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: try makeContainer()), hostKeyApprover: { _ in true })
    }

    /// 回放到一半连接断了：重连接着接，不退到普通连接（那会悄悄换成一个不保持的 shell），也不说会话没了。
    func testDropDuringFirstReplayRetriesInsteadOfFallingBackToAPlainShell() async throws {
        let switches = Switches()
        switches.dropDuringReplay.withLock { $0 = 1 }
        let server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: Self.fakeHolder(switches)))
        defer { Task { await server.stop() } }
        let backend = try makeBackend(server, resumes: true)

        try await backend.connect()

        XCTAssertEqual(switches.attachPayloads.withLock { $0.count }, 2, "断了之后又接了一次")
        XCTAssertTrue(server.events.ptyRequests.isEmpty, "没有退到普通连接（普通连接会请求伪终端）")
        XCTAssertFalse(backend.hostSessionHasEnded)
        XCTAssertTrue(backend.hasAttachedToHostSession)
        await backend.close()
    }

    /// 一直在回放时断：报连接失败，会话没被当成结束（界面留着 id，下次接着接），也没有开普通 shell。
    func testRepeatedDropsDuringFirstReplayFailWithoutEndingTheSession() async throws {
        let switches = Switches()
        switches.dropDuringReplay.withLock { $0 = 100 }
        let server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: Self.fakeHolder(switches)))
        defer { Task { await server.stop() } }
        let backend = try makeBackend(server, resumes: true)

        do {
            try await backend.connect()
            XCTFail("一直断应当报错")
        } catch {}

        XCTAssertEqual(switches.attachPayloads.withLock { $0.count }, PersistentSSHConnection.firstAttachAttempts)
        XCTAssertTrue(server.events.ptyRequests.isEmpty, "没有退到普通连接")
        XCTAssertFalse(backend.hostSessionHasEnded, "主机上的会话没被当成结束")
        XCTAssertFalse(backend.hasAttachedToHostSession)
        var sawExit = false
        for await _ in backend.exitStream { sawExit = true; break }
        XCTAssertTrue(sawExit, "界面要知道这个后端结束了")
    }

    /// 普通连接（主机用不了保持进程）没连上：不说「会话没了」——从来就没有过。
    func testPlainFallbackThatFailsToConnectDoesNotClaimTheSessionEnded() async throws {
        let attempts = PromptCounter()
        let server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: SSHTestAuthentication(custom: { _ in attempts.next() == 1 }),
            exec: SSHTestExecHandler { _ in .status(127) }))   // 没有 uterm-holder：安装失败 → 普通连接
        defer { Task { await server.stop() } }
        let backend = try makeBackend(server, resumes: false)

        do {
            try await backend.connect()
            XCTFail("普通连接登录被拒，应当报错")
        } catch {}

        XCTAssertFalse(backend.hostSessionHasEnded)
    }
}

