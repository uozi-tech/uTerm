import XCTest
import SwiftData
import NIOCore
import NIOSSH
import USSHTestServer
@testable import uTerm
@testable import USSHKit

/// `SSHConnection`（终端后端）对着进程内测试服务端走真实握手：PTY 请求、环境变量、输入回显与顺序、
/// 改尺寸、本端关闭、远端断开、探活。`SSHConnectionIntegrationTests` 要本机 sshd，平时跳过；这几条一直跑。
final class SSHConnectionTestServerTests: XCTestCase {

    private var server: SSHTestServer!

    override func setUp() async throws {
        try await super.setUp()
        server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone,
            exec: .routes(["true": .scripted()])))
    }

    override func tearDown() async throws {
        await server?.stop()
        server = nil
        try await super.tearDown()
    }

    private func makeConnection() throws -> SSHConnection {
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        return SSHConnection(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "unused"),
            jumpHostAuth: nil, hostKeyVerifier: verifier, hostKeyApprover: { _ in true })
    }

    /// 收输出直到出现 `marker`（或输出流结束）。
    private func collect(_ connection: SSHConnection, until marker: String,
                         timeout: Duration = .seconds(10)) async throws -> String {
        let items = connection.outputItems
        let task = Task { () -> String in
            var collected = Data()
            for await item in items {
                guard case .bytes(let chunk) = item else { continue }
                collected.append(chunk)
                if String(decoding: collected, as: UTF8.self).contains(marker) { break }
            }
            return String(decoding: collected, as: UTF8.self)
        }
        let timer = Task {
            try await Task.sleep(for: timeout)
            task.cancel()
        }
        defer { timer.cancel() }
        return await task.value
    }

    /// 等 `exitStream` 出一个元素（会话结束）。
    private func waitForExit(_ connection: SSHConnection, timeout: Duration = .seconds(10)) async -> Bool {
        let exit = connection.exitStream
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exit { return true }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func testOpensPTYWithTermAndEnvironmentAndEchoesInput() async throws {
        let connection = try makeConnection()
        await connection.resize(cols: 132, rows: 40)
        try await connection.connect()

        let events = try await server.waitForEvents { $0.shellRequests == 1 }
        XCTAssertEqual(events.ptyRequests.first?.term, "xterm-256color")
        XCTAssertEqual(events.ptyRequests.first?.columns, 132)
        XCTAssertEqual(events.ptyRequests.first?.rows, 40)
        XCTAssertEqual(events.environment["LANG"], "en_US.UTF-8", "远端没有 LANG 时 less / man 把中文当成不可打印")

        await connection.write(Data("hello-uterm".utf8))
        let echoed = try await collect(connection, until: "hello-uterm")
        XCTAssertTrue(echoed.contains("hello-uterm"))
        await connection.close()
    }

    /// 写入与改尺寸走同一条 FIFO：按调用顺序到达远端，不乱序。
    func testWritesArriveInOrderAndResizeIsSent() async throws {
        let connection = try makeConnection()
        try await connection.connect()
        for index in 0..<200 {
            await connection.write(Data("<\(index)>".utf8))
        }
        await connection.resize(cols: 100, rows: 30)
        let echoed = try await collect(connection, until: "<199>")
        let expected = (0..<200).map { "<\($0)>" }.joined()
        XCTAssertEqual(echoed, expected)
        let events = try await server.waitForEvents { !$0.windowChanges.isEmpty }
        XCTAssertEqual(events.windowChanges.last?.columns, 100)
        XCTAssertEqual(events.windowChanges.last?.rows, 30)
        await connection.close()
    }

    /// 本端关闭：会话结束（exitStream 出元素），服务端看到连接断开（共享连接上最后一个租约还掉了）。
    func testLocalCloseEndsSessionAndReleasesTheConnection() async throws {
        let connection = try makeConnection()
        try await connection.connect()
        _ = try await server.waitForEvents { $0.shellRequests == 1 }
        await connection.close()
        let ended = await waitForExit(connection)
        XCTAssertTrue(ended)
        _ = try await server.waitForEvents { $0.closedConnections >= 1 }
    }

    /// 远端 shell 退出（Ctrl-D）：会话自己结束。
    func testRemoteShellExitEndsSession() async throws {
        let connection = try makeConnection()
        try await connection.connect()
        await connection.write(Data([0x04]))
        let ended = await waitForExit(connection)
        XCTAssertTrue(ended)
        await connection.close()
    }

    /// shell 退出了但后台进程还占着伪终端（`sleep 1000 &` 再 `exit`）：sshd 先报退出状态、通道不关。
    /// 会话在退出状态到了之后很快结束（不等那个进程），最后的输出照样送到。
    func testRemoteExitWithABackgroundJobHoldingThePTYEndsSession() async throws {
        await server.stop()
        server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone,
            shell: SSHTestExecHandler { context in
                for await chunk in context.stdin where chunk.readableBytesView.contains(0x04) {
                    try await context.write("logout\r\n")
                    context.channel.triggerUserOutboundEvent(
                        SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
                    break
                }
                for await _ in context.stdin {}      // 后台进程占着，直到客户端关通道
                return .noStatus
            }))
        let connection = try makeConnection()
        try await connection.connect()
        let items = connection.outputItems
        let output = Task { () -> String in
            var collected = Data()
            for await item in items {
                guard case .bytes(let chunk) = item else { continue }
                collected.append(chunk)
            }
            return String(decoding: collected, as: UTF8.self)
        }
        await connection.write(Data([0x04]))
        let started = ContinuousClock.now
        let ended = await waitForExit(connection, timeout: .seconds(5))
        XCTAssertTrue(ended, "退出状态到了之后会话就该结束")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        let collected = await output.value
        XCTAssertTrue(collected.contains("logout"), collected)
        await connection.close()
    }

    /// 服务器掐断 TCP：不等输出流自己察觉，断开回调立刻让会话结束（界面翻到「已断开」）。
    // MARK: - 跳板机：失败类别决定重不重连

    /// 经 `bastion` 连本测试的目标；`password` 是给跳板机的口令。
    private func makeJumpConnection(bastion: SSHTestServer, password: String) throws -> SSHConnection {
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        return SSHConnection(
            profile: SSHConnection.ProfileSnapshot(
                host: "127.0.0.1", port: server.port,
                jumpHost: .init(host: "127.0.0.1", port: bastion.port)),
            auth: .password(username: "tester", password: "unused"),
            jumpHostAuth: .password(username: "jumper", password: password),
            hostKeyVerifier: verifier, hostKeyApprover: { _ in true })
    }

    private func jumpFailure(of connection: SSHConnection) async -> (cause: JumpHostFailureCause, error: Error)? {
        do {
            try await connection.connect()
            await connection.close()
            return nil
        } catch {
            guard case SSHConnection.SSHConnectionError.jumpHostFailed(_, let cause) = error else {
                XCTFail("应当是跳板机失败：\(error)")
                return nil
            }
            return (cause, error)
        }
    }

    /// 跳板机拒绝了口令：配置问题，不能当成网络问题自动重连（反复认证会触发锁号）。
    func testJumpHostRejectingTheCredentialIsAPermanentFailure() async throws {
        let bastion = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: SSHTestAuthentication(passwords: ["jumper": "right"])))
        defer { Task { await bastion.stop() } }

        let failure = await jumpFailure(of: try makeJumpConnection(bastion: bastion, password: "wrong"))
        XCTAssertEqual(failure?.cause, .authentication)
        if let failure {
            XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(failure.error))
        }
    }

    /// 跳板机登录成功、但不肯开到目标的通道：网络这一类，照旧自动重试。
    func testJumpHostRefusingTheTunnelIsRetryable() async throws {
        let bastion = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone, allowsDirectTCPIP: false))
        defer { Task { await bastion.stop() } }

        let failure = await jumpFailure(of: try makeJumpConnection(bastion: bastion, password: "any"))
        XCTAssertEqual(failure?.cause, .unreachable)
        if let failure {
            XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(failure.error))
        }
    }

    /// 两跳都通时照常连上（跳板机的口令对了）。
    func testJumpHostWithTheRightCredentialConnects() async throws {
        let bastion = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: SSHTestAuthentication(passwords: ["jumper": "right"])))
        defer { Task { await bastion.stop() } }

        let failure = await jumpFailure(of: try makeJumpConnection(bastion: bastion, password: "right"))
        XCTAssertNil(failure)
    }

    func testTransportDropEndsSession() async throws {
        let connection = try makeConnection()
        try await connection.connect()
        _ = try await server.waitForEvents { $0.shellRequests == 1 }
        await server.dropAllConnections()
        let ended = await waitForExit(connection)
        XCTAssertTrue(ended)
        await connection.close()
    }

    /// 探活：连接活着时为真；链路卡死（不读不写、TCP 还在）时按时限判死并关掉连接，会话随之结束。
    func testVerifyConnectionAliveDetectsAFrozenLink() async throws {
        let connection = try makeConnection()
        try await connection.connect()
        let alive = await connection.verifyConnectionAlive(timeout: .seconds(5))
        XCTAssertTrue(alive)

        await server.freezeAllConnections()
        let started = ContinuousClock.now
        let frozen = await connection.verifyConnectionAlive(timeout: .seconds(1))
        XCTAssertFalse(frozen)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "超时就返回，不等卡住的探测")
        let ended = await waitForExit(connection)
        XCTAssertTrue(ended)
        await connection.close()
    }
}
