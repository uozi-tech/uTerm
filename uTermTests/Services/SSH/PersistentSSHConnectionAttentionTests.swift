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
            resolveCredentials: {
                await resolutions.increment()
                return (.password(username: "tester", password: "new"), nil)
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
}
