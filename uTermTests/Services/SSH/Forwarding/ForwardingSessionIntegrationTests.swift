import XCTest
import SwiftData
import NIOCore
import NIOPosix
@testable import uTerm

/// 转发会话集成测试 —— 对本地 sshd 跑真实 `-L` 本地转发。
/// 无 `UTERM_TEST_SSH_PASSWORD` 时 SKIP（不 FAIL），镜像 `SSHConnectionIntegrationTests`。
final class ForwardingSessionIntegrationTests: XCTestCase {
    private let testUser = NSUserName()
    private let testPassword = ProcessInfo.processInfo.environment["UTERM_TEST_SSH_PASSWORD"]

    private func skipIfNoPassword() throws {
        try XCTSkipUnless(testPassword != nil,
            "设置环境变量 UTERM_TEST_SSH_PASSWORD 后运行此集成测试")
    }

    /// 起一个本地 TCP echo 服务，返回 (绑定端口, 关闭闭包)。
    /// `NIOAsyncChannel(wrappingChannelSynchronously:)` 只能在 channel 的 EventLoop 上调（NIO 有 precondition），
    /// 所以在 bind 的子 channel 初始化回调里包，不在测试线程上包。
    private func startEchoServer(group: EventLoopGroup) async throws -> (Int, @Sendable () async -> Void) {
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: child)
                }
            }
        let port = server.channel.localAddress?.port ?? 0
        let task = Task {
            try? await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await conn in inbound {
                        group.addTask {
                            try? await conn.executeThenClose { i, o in
                                for try await chunk in i { try await o.write(chunk) }
                            }
                        }
                    }
                }
            }
        }
        return (port, { task.cancel(); try? await server.channel.close() })
    }

    func testLocalForwardRoundTrips() async throws {
        try skipIfNoPassword()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (echoPort, stopEcho) = try await startEchoServer(group: group)

        // 主机默认本机 sshd，可用 `UTERM_TEST_SSH_HOST` / `_PORT` / `_USER` 指到别的（如 Docker 里的 sshd）；
        // 那时 sshd 看到的 127.0.0.1 是它自己，echo 服务的地址用 `UTERM_TEST_FORWARD_DEST_HOST` 给
        // （Docker Desktop / OrbStack 是 host.docker.internal）。
        let env = ProcessInfo.processInfo.environment
        let user = env["UTERM_TEST_SSH_USER"] ?? testUser
        let profile = ServerProfile()
        profile.host = env["UTERM_TEST_SSH_HOST"] ?? "127.0.0.1"
        profile.port = Int(env["UTERM_TEST_SSH_PORT"] ?? "") ?? 22
        profile.username = user
        profile.authMethod = .password

        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))

        // 状态收集（线程安全）。回调里同步记下：每次回调另起 Task 的话先后次序就没了，读到的可能是旧状态。
        final class StatusBox: @unchecked Sendable {
            private let lock = NSLock()
            private var last: TunnelStatus = .inactive
            func set(_ s: TunnelStatus) { lock.withLock { last = s } }
            func get() -> TunnelStatus { lock.withLock { last } }
        }
        let box = StatusBox()

        let session = ForwardingSession(
            profile: SSHConnection.ProfileSnapshot(profile),
            auth: .password(username: user, password: testPassword!),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true },
            onStatus: { _, status in box.set(status) })

        try await session.connect()

        // 选一个高位本地端口转发到 echo 服务。
        let listenPort = Int.random(in: 49152...65500)
        let rule = ForwardingRuleSnapshot(
            id: UUID(), serverID: profile.id, name: "Echo 转发", kind: .local,
            listenHost: "127.0.0.1", listenPort: listenPort,
            destHost: env["UTERM_TEST_FORWARD_DEST_HOST"] ?? "127.0.0.1", destPort: echoPort, autostart: false)

        await session.start(rule)

        // 给 bind + active 一点时间。
        try await Task.sleep(for: .milliseconds(500))
        let status = box.get()
        XCTAssertEqual(status, .active, "本地转发应进入 active，实际：\(status)")

        // 经转发端口发字节，应被 echo 回来。
        let ac = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: listenPort) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        let echoed: String = try await withTimeout(seconds: 10) {
            (try? await ac.executeThenClose { inbound, outbound -> String in
                try await outbound.write(ByteBuffer(string: "PING\n"))
                var acc = ""
                for try await chunk in inbound {
                    acc += String(buffer: chunk)
                    if acc.contains("PING") { break }
                }
                return acc
            }) ?? ""
        }
        XCTAssertTrue(echoed.contains("PING"), "经转发的 echo 应回 PING，实际：\(echoed)")

        await session.stop(rule.id)
        let finalStatus = box.get()
        XCTAssertEqual(finalStatus, .inactive)
        await session.close()

        await stopEcho()
        try? await group.shutdownGracefully()
    }
}
