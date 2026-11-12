import XCTest
import NIOCore
import NIOEmbedded
import NIOPosix
@preconcurrency import NIOSSH
@testable import uTerm

/// `-R` 入站连接的两块：`ForwardedChannelCodec`（forwarded-tcpip 通道上 `SSHChannelData` ⇄
/// `ByteBuffer`）与 `RemoteForwardBridge.serve`（连本机目标 + 双向泵）。
///
/// 回归背景：2.1.2 之前 `-R` 用的是 Citadel 的 `runRemotePortForward`，它不加编解码，
/// 服务器上有人一连、第一份数据进 `NIOAsyncChannel<ByteBuffer, …>` 就在 `forceAsByteBuffer`
/// 断言，整个 App 崩掉。编解码那半用 `EmbeddedChannel` 测；泵那半用 loopback 上的真 socket
/// 冒充 forwarded-tcpip 通道（不需要 sshd）。
final class RemoteForwardBridgeTests: XCTestCase {

    // MARK: - 编解码

    func testCodecTurnsChannelDataIntoBytesAndBack() throws {
        let channel = EmbeddedChannel(handler: ForwardedChannelCodec())
        defer { _ = try? channel.finish() }

        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "GET /"))))
        XCTAssertEqual(try channel.readInbound(as: ByteBuffer.self), ByteBuffer(string: "GET /"))

        try channel.writeOutbound(ByteBuffer(string: "200 OK"))
        let out = try XCTUnwrap(try channel.readOutbound(as: SSHChannelData.self))
        XCTAssertEqual(out.type, .channel)
        XCTAssertEqual(out.data, .byteBuffer(ByteBuffer(string: "200 OK")))
    }

    func testCodecDropsExtendedData() throws {
        let channel = EmbeddedChannel(handler: ForwardedChannelCodec())
        defer { _ = try? channel.finish() }

        try channel.writeInbound(SSHChannelData(type: .stdErr, data: .byteBuffer(ByteBuffer(string: "noise"))))
        XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
    }

    // MARK: - 泵

    private static func wrap(_ ch: Channel) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> {
        ch.eventLoop.makeCompletedFuture {
            try ch.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: ch,
                configuration: .init(isOutboundHalfClosureEnabled: true))
        }
    }

    /// loopback 服务：每条连接交给 `handle`。返回 (端口, 关闭)。
    private func listen(
        group: EventLoopGroup,
        handle: @escaping @Sendable (NIOAsyncChannel<ByteBuffer, ByteBuffer>) async -> Void
    ) async throws -> (Int, @Sendable () async -> Void) {
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { Self.wrap($0) }
        let port = server.channel.localAddress?.port ?? 0
        let serverChannel = server.channel
        let task = Task {
            try? await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await conn in inbound {
                        group.addTask { await handle(conn) }
                    }
                }
            }
        }
        return (port, { task.cancel(); try? await serverChannel.close() })
    }

    private func connect(group: EventLoopGroup, port: Int) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port) { Self.wrap($0) }
    }

    /// 服务器那头的客户端发请求、收回显：字节两个方向都到，计数器两边都记上。
    func testServeRelaysBothWaysAndCounts() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let counter = TunnelByteCounter()

        // 本机目标：回显。
        let (echoPort, stopEcho) = try await listen(group: group) { conn in
            try? await conn.executeThenClose { inbound, outbound in
                for try await chunk in inbound { try await outbound.write(chunk) }
            }
        }
        // 冒充 forwarded-tcpip 通道：接进来的连接交给被测的 serve。
        let (entryPort, stopEntry) = try await listen(group: group) { conn in
            await RemoteForwardBridge.serve(
                conn, destHost: "127.0.0.1", destPort: echoPort, ruleName: "test", counter: counter)
        }

        let client = try await connect(group: group, port: entryPort)
        let echoed = try await withTimeout(seconds: 10) {
            var got = ""
            try? await client.executeThenClose { inbound, outbound in
                try await outbound.write(ByteBuffer(string: "hello"))
                outbound.finish()
                for try await chunk in inbound { got += String(buffer: chunk) }
            }
            return got
        }
        XCTAssertEqual(echoed, "hello")

        // 计数在泵收尾时才落定，等一下。
        let deadline = Date().addingTimeInterval(5)
        while counter.snapshot.up < 5 || counter.snapshot.down < 5, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(counter.snapshot.down, 5, "下行 = 远端 → 本机（请求）")
        XCTAssertEqual(counter.snapshot.up, 5, "上行 = 本机 → 远端（回显）")

        await stopEntry()
        await stopEcho()
        try? await group.shutdownGracefully()
    }

    /// 本机目标没人监听：这条连接被干净地关掉（对端读到 EOF），进程不能因为
    /// 「NIOAsyncWriter 没 finish 就析构」被 NIO 的 precondition 带走。
    func testServeClosesInboundWhenLocalTargetIsDown() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        // 拿一个刚释放的端口当「没人监听的目标」。
        let probe = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let deadPort = probe.localAddress?.port ?? 0
        try await probe.close()

        let (entryPort, stopEntry) = try await listen(group: group) { conn in
            await RemoteForwardBridge.serve(
                conn, destHost: "127.0.0.1", destPort: deadPort, ruleName: "test",
                counter: TunnelByteCounter())
        }

        let client = try await connect(group: group, port: entryPort)
        let received = try await withTimeout(seconds: 10) {
            var bytes = 0
            try? await client.executeThenClose { inbound, outbound in
                try await outbound.write(ByteBuffer(string: "hello"))
                for try await chunk in inbound { bytes += chunk.readableBytes }
            }
            return bytes
        }
        XCTAssertEqual(received, 0, "目标不可达时什么也不回，直接关")

        await stopEntry()
        try? await group.shutdownGracefully()
    }
}
