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
    private func startEchoServer(group: EventLoopGroup) async throws -> (Int, @Sendable () async -> Void) {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress?.port ?? 0

        let asyncServer = try NIOAsyncChannel<Channel, Never>(
            wrappingChannelSynchronously: channel)
        let task = Task {
            try? await asyncServer.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await conn in inbound {
                        group.addTask {
                            let ac = try? NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                                wrappingChannelSynchronously: conn)
                            try? await ac?.executeThenClose { i, o in
                                for try await chunk in i { try await o.write(chunk) }
                            }
                        }
                    }
                }
            }
        }
        return (port, { task.cancel(); try? await channel.close() })
    }

    func testLocalForwardRoundTrips() async throws {
        try skipIfNoPassword()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (echoPort, stopEcho) = try await startEchoServer(group: group)

        let profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = 22
        profile.username = testUser
        profile.authMethod = .password

        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))

        // 状态收集（线程安全）。
        actor StatusBox { var last: TunnelStatus = .inactive
            func set(_ s: TunnelStatus) { last = s }
            func get() -> TunnelStatus { last } }
        let box = StatusBox()

        let session = ForwardingSession(
            profile: SSHConnection.ProfileSnapshot(profile),
            auth: .password(username: testUser, password: testPassword!),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true },
            onStatus: { _, status in Task { await box.set(status) } })

        try await session.connect()

        // 选一个高位本地端口转发到 echo 服务。
        let listenPort = Int.random(in: 49152...65500)
        let rule = ForwardingRuleSnapshot(
            id: UUID(), serverID: profile.id, name: "Echo 转发", kind: .local,
            listenHost: "127.0.0.1", listenPort: listenPort,
            destHost: "127.0.0.1", destPort: echoPort, autostart: false)

        await session.start(rule)

        // 给 bind + active 一点时间。
        try await Task.sleep(for: .milliseconds(500))
        let status = await box.get()
        XCTAssertEqual(status, .active, "本地转发应进入 active，实际：\(status)")

        // 经转发端口发字节，应被 echo 回来。
        let client = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: listenPort).get()
        let ac = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
            wrappingChannelSynchronously: client)
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
        let finalStatus = await box.get()
        XCTAssertEqual(finalStatus, .inactive)
        await session.close()

        await stopEcho()
        try? await group.shutdownGracefully()
    }
}
