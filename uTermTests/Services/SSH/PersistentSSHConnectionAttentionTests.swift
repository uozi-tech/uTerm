import Foundation
import NIOCore
import NIOSSH
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
        /// 接入后隔这么久才回 replayEnd（回放还在路上）。
        let replayEndDelay = Mutex(Duration.zero)
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
                        let delay = switches.replayEndDelay.withLock { $0 }
                        if delay > .zero { try await Task.sleep(for: delay) }
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

    // MARK: - 有上限的等待

    /// 连上；同时登记收尾时关掉它（用例中途失败也关，不然它在服务端停掉之后一直重连）。
    private func connect(_ backend: PersistentSSHConnection,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        addTeardownBlock { _ = try? await bounded("收尾时关闭后端") { await backend.close() } }
        try await bounded("connect() 返回", within: 20, file: file, line: line) { try await backend.connect() }
    }

    private func close(_ backend: PersistentSSHConnection,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        try await bounded("close() 返回", file: file, line: line) { await backend.close() }
    }

    private func retry(_ backend: PersistentSSHConnection,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        try await bounded("retryAfterAttention() 返回", file: file, line: line) { await backend.retryAfterAttention() }
    }

    /// 等后端报「接回了」（`reconnecting` 翻回 false）。服务端记下接入请求时回放可能还在路上，
    /// 这之前打的字按设计丢掉（`write` 只在接上时发），所以要打字先等这个。
    private func waitUntilReattached(_ reconnecting: BoundedStream<Bool>,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await reconnecting.first("reconnecting 翻回 false（接回完成）", file: file, line: line) { !$0 }
        XCTAssertEqual(value, false, "reconnecting 流先结束了", file: file, line: line)
    }

    /// 先开始收输出，再 `send`，等输出里出现 `marker`。流先结束了给 false。
    private func echo(of marker: String, from backend: PersistentSSHConnection,
                      file: StaticString = #filePath, line: UInt = #line,
                      after send: () async -> Void) async throws -> Bool {
        let output = Task { () -> Bool in
            for await item in backend.outputItems {
                if case .bytes(let data) = item, String(decoding: data, as: UTF8.self).contains(marker) { return true }
            }
            return false
        }
        await send()
        return try await bounded("「\(marker)」的回显", file: file, line: line) { await output.value }
    }

    func testPermanentReconnectFailureWaitsForTheUserAndResumesTheSameSession() async throws {
        let switches = Switches()
        let configuration = SSHTestServer.Configuration(
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
        try await connect(backend)
        XCTAssertEqual(switches.attachPayloads.withLock { $0.count }, 1)

        // 服务器开始拒绝登录，然后连接断了：重连碰到认证失败，停下来等用户——会话不结束。
        switches.rejectLogins.withLock { $0 = true }
        let attention = BoundedStream(backend.attention)
        let reconnecting = BoundedStream(backend.reconnecting)
        await server.dropAllConnections()
        let reason = try await attention.next("断线重连碰到认证失败后报出的原因")
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
        try await retry(backend)
        let cleared = try await attention.next("点重试之后清掉原因的 nil")
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

        // 接回之后输入照常回显。服务端记下接入请求时回放可能还没收完，先等后端自己说接上了。
        try await waitUntilReattached(reconnecting)
        let echoed = try await echo(of: "after-retry", from: backend) {
            await backend.write(Data("after-retry".utf8))
        }
        XCTAssertTrue(echoed, "接回之后的输入要回显")
        try await close(backend)
    }

    /// 重连时服务端已经收到接入请求、回放还没收完（replayEnd 没到）：这时打的字按设计丢掉，不留着等接上再补发；
    /// 接上之后打的字照常回显。上面那条用例以前就是在这个窗口里打字，偶尔等不到回显、整个套件卡住。
    func testInputBeforeTheReattachFinishesIsDroppedAndInputAfterItEchoes() async throws {
        let switches = Switches()
        let server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: Self.fakeHolder(switches)))
        defer { Task { await server.stop() } }
        let backend = try makeBackend(server, resumes: false)
        try await connect(backend)
        let reconnecting = BoundedStream(backend.reconnecting)
        switches.replayEndDelay.withLock { $0 = .milliseconds(400) }

        await server.dropAllConnections()
        _ = try await server.waitForEvents(timeout: .seconds(10)) { _ in
            switches.attachPayloads.withLock { $0.count } == 2
        }
        // 一个收输出的任务从头收到尾（流只能有一个消费者；中途取消会让流结束）。
        let output = Task { () -> String in
            var collected = Data()
            for await item in backend.outputItems {
                guard case .bytes(let data) = item else { continue }
                collected.append(data)
                if String(decoding: collected, as: UTF8.self).contains("after-reattach") { break }
            }
            return String(decoding: collected, as: UTF8.self)
        }
        await backend.write(Data("too-early".utf8))
        try await waitUntilReattached(reconnecting)
        await backend.write(Data("after-reattach".utf8))
        let collected = try await bounded("「after-reattach」的回显") { await output.value }
        XCTAssertFalse(collected.contains("too-early"), "回放没收完时打的字不该发到主机：\(collected)")
        let echoed = collected.contains("after-reattach")
        XCTAssertTrue(echoed, "接上之后的输入要回显")
        try await close(backend)
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
        try await connect(backend)
        XCTAssertFalse(backend.hostSessionHasEnded)
        await backend.write(Data("quit".utf8))
        let exited: Void? = try await BoundedStream(backend.exitStream).next("保持进程报会话结束后的 exitStream")
        XCTAssertNotNil(exited, "exitStream 结束了却没给过元素")
        XCTAssertTrue(backend.hostSessionHasEnded)
        try await close(backend)
    }

    // MARK: - 第一次就没连上

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// 第一个输出块是历史（`.history`，查询不答）还是实时的（`.bytes`，查询照答）。
    private static func firstOutputIsHistory(_ backend: PersistentSSHConnection) async -> Bool? {
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
            try await connect(first)
            XCTFail("服务器拒了登录，应当连不上")
        } catch {}
        XCTAssertFalse(first.hostSessionHasEnded)
        XCTAssertFalse(first.hasAttachedToHostSession, "没接上过")

        // 界面的规则（`MobileTerminalController`）：接着连同一个 id，接回与否 = 之前就是接回 || 接上过。
        let resumes = false || first.hasAttachedToHostSession
        switches.rejectLogins.withLock { $0 = false }
        let second = backend(resumes: resumes)
        try await connect(second)
        let history = try await bounded("第一个输出块") { await Self.firstOutputIsHistory(second) }
        XCTAssertEqual(history, false, "新会话启动时的输出要按实时处理（终端查询要回答）")
        XCTAssertTrue(server.events.execCommands.last?.contains("--create") ?? false)
        XCTAssertTrue(second.hasAttachedToHostSession)
        try await close(second)

        // 对照：错当成接回的话（修之前的行为），同样的输出被当成历史。
        let wrong = PersistentSSHConnection(
            sessionID: UUID(), resumesSession: true,
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "x"), jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        try await connect(wrong)
        let wrongHistory = try await bounded("第一个输出块") { await Self.firstOutputIsHistory(wrong) }
        XCTAssertEqual(wrongHistory, true)
        try await close(wrong)
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
    ) async throws -> (PersistentSSHConnection, BoundedStream<String?>) {
        let backend = PersistentSSHConnection(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port ?? server.port, jumpHost: jumpHost),
            auth: .password(username: "old-user", password: "pw"), jumpHostAuth: jumpAuth,
            hostKeyVerifier: HostKeyVerifier(modelContainer: try makeContainer()),
            hostKeyApprover: approver, resolveSettings: resolve)
        try await connect(backend)
        requirement.set(accepts)
        let attention = BoundedStream(backend.attention)
        await server.dropAllConnections()
        let reason = try await attention.next("要用户处理的原因")
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

        try await retry(backend)
        let ok = await reattached(switches, count: 2)
        XCTAssertTrue(ok, "改了用户名之后应当接回")
        XCTAssertEqual(server.events.authAttempts.last(where: \.accepted)?.username, "new-user")
        try await close(backend)
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

        try await retry(backend)
        let ok = await reattached(switches, count: 2)
        XCTAssertTrue(ok, "换成私钥之后应当接回")
        guard case .publicKey = server.events.authAttempts.last(where: \.accepted)?.method else {
            return XCTFail("应当用私钥登录")
        }
        try await close(backend)
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

        try await retry(backend)
        let ok = await reattached(switches, count: 2)
        XCTAssertTrue(ok, "改了跳板机之后应当接回")
        XCTAssertFalse(newBastion.events.authAttempts.isEmpty, "走的是新的跳板机")
        try await close(backend)
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
        let attention = waiting.1
        let attemptsBefore = server.events.authAttempts.count

        try await retry(backend)
        let reason = try await attention.next("要用户处理的原因")
        XCTAssertEqual(reason ?? nil, PersistentSSHConnection.HostMovedError().errorDescription)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.events.authAttempts.count, attemptsBefore, "不去新地址登录")
        XCTAssertFalse(backend.hostSessionHasEnded)
        try await close(backend)
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
        try await connect(backend)
        XCTAssertEqual(prompts.count, 1)

        // 同一个端口上换了一台主机密钥不同的服务器：重连要确认密钥，用户（替身）拒绝 → 停下来等用户。
        let attention = BoundedStream(backend.attention)
        await first.stop()
        let second: SSHTestServer
        do {
            second = try await SSHTestServer.start(SSHTestServer.Configuration(
                authentication: .acceptAnyone, exec: Self.fakeHolder(switches)), port: port)
        } catch {
            throw XCTSkip("端口 \(port) 一时绑不回来：\(error)")
        }
        defer { Task { await second.stop() } }
        try await bounded("recheckAfterDisruption 返回") { await backend.recheckAfterDisruption(lostInterface: true) }
        let reason = try await attention.next("要用户处理的原因")
        XCTAssertNotNil(reason ?? nil)
        let promptsBeforeClose = prompts.count

        try await close(backend)
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

    /// 服务器整个不在了（进程退出、容器删掉，端口没人监听）：重连每次都被拒绝。会话不结束、接着试，同时把
    /// 「为什么还没连上」交给界面（拒绝连接），而不是只说「断了」。服务器回来之后接回，原因清掉。
    func testServerGoneReportsWhyReconnectKeepsFailingAndClearsOnReattach() async throws {
        let switches = Switches()
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let server = try await SSHTestServer.start(SSHTestServer.Configuration(
            hostKey: hostKey, authentication: .acceptAnyone, exec: Self.fakeHolder(switches)))
        let port = server.port
        let backend = try makeBackend(server, resumes: false)
        try await connect(backend)
        let failures = BoundedStream(backend.reconnectFailure)

        await server.stop()
        let reason = try await failures.first("重连被拒绝后报出的原因") { $0 != nil }
        let text = try XCTUnwrap(reason ?? nil)
        XCTAssertTrue(text.contains("拒绝了连接"), text)
        XCTAssertTrue(text.contains("127.0.0.1:\(port)"), text)
        XCTAssertFalse(text.contains("断"), "服务器不在不是「断了」：\(text)")
        XCTAssertFalse(backend.hostSessionHasEnded, "主机上的会话不能当成没了")

        // 同一个端口上服务器回来了：接回，原因清掉。
        let again = try await SSHTestServer.start(SSHTestServer.Configuration(
            hostKey: hostKey, authentication: .acceptAnyone, exec: Self.fakeHolder(switches)), port: port)
        defer { Task { await again.stop() } }
        let cleared = try await failures.first("接回后清掉原因的 nil", within: 30) { $0 == nil }
        XCTAssertEqual(cleared ?? "stream ended", nil)
        try await close(backend)
    }

    /// 回放到一半连接断了：重连接着接，不退到普通连接（那会悄悄换成一个不保持的 shell），也不说会话没了。
    func testDropDuringFirstReplayRetriesInsteadOfFallingBackToAPlainShell() async throws {
        let switches = Switches()
        switches.dropDuringReplay.withLock { $0 = 1 }
        let server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: Self.fakeHolder(switches)))
        defer { Task { await server.stop() } }
        let backend = try makeBackend(server, resumes: true)

        try await connect(backend)

        XCTAssertEqual(switches.attachPayloads.withLock { $0.count }, 2, "断了之后又接了一次")
        XCTAssertTrue(server.events.ptyRequests.isEmpty, "没有退到普通连接（普通连接会请求伪终端）")
        XCTAssertFalse(backend.hostSessionHasEnded)
        XCTAssertTrue(backend.hasAttachedToHostSession)
        try await close(backend)
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
            try await connect(backend)
            XCTFail("一直断应当报错")
        } catch {}

        XCTAssertEqual(switches.attachPayloads.withLock { $0.count }, PersistentSSHConnection.firstAttachAttempts)
        XCTAssertTrue(server.events.ptyRequests.isEmpty, "没有退到普通连接")
        XCTAssertFalse(backend.hostSessionHasEnded, "主机上的会话没被当成结束")
        XCTAssertFalse(backend.hasAttachedToHostSession)
        let exited: Void? = try await BoundedStream(backend.exitStream).next("连接失败后的 exitStream")
        XCTAssertNotNil(exited, "界面要知道这个后端结束了")
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
            try await connect(backend)
            XCTFail("普通连接登录被拒，应当报错")
        } catch {}

        XCTAssertFalse(backend.hostSessionHasEnded)
    }
}

