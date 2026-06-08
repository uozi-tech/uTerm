import XCTest
import NIOCore
import NIOPosix
@testable import uTerm

/// `TunnelGlue.pipe` 优雅半关 / 排空回归测试。
///
/// 关注点（FIX #5/#6）：旧实现 `try await group.next()` + `defer cancelAll()` 在**第一个**方向
/// 读到 EOF 时就把仍在流动的对向连根拔掉，截断仍在传输的响应。本测试用真 loopback
/// `NIOAsyncChannel`（无 SSH、无密码，可无条件运行）复现该时序：
///
///   - 隧道左端 `a` 的对端在发完一小段后**立刻半关写端** → A→B 这一向很快读到 EOF；
///   - 隧道右端 `b` 的对端在 A→B EOF **之后**才把一大段响应写出来（B→A 仍在流动）。
///
/// 旧实现会在 A→B EOF 时 `cancelAll()`，B→A 那段晚到的响应被截断、`a` 对端收不全。
/// 修复后两个方向都排空，`a` 对端必须收到完整响应。
final class TunnelGlueTests: XCTestCase {

    /// `NIOAsyncChannel` 配置：开启出站半关，让 `outbound.finish()` 真的向对端发 TCP FIN
    /// （默认 `isOutboundHalfClosureEnabled == false` 时只本地结束写端、不发 FIN，对端读不到
    /// EOF → 隧道 A→B 永不结束 → 测试假死）。
    private static let halfCloseConfig = NIOAsyncChannel<ByteBuffer, ByteBuffer>.Configuration(
        isOutboundHalfClosureEnabled: true)

    /// 在子 channel 的 EL 上 wrap 成 `NIOAsyncChannel`（满足 `wrappingChannelSynchronously` 的
    /// `preconditionInEventLoop()`），并设 `allowRemoteHalfClosure` 让本端在对端 FIN 后仍可继续读。
    private static func wrapOnEventLoop(
        _ ch: Channel
    ) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> {
        ch.eventLoop.makeCompletedFuture {
            try ch.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: ch, configuration: halfCloseConfig)
        }
    }

    /// 起一个 loopback TCP 服务，每个连接交给 `handle` 处理（在独立子任务里）。返回 (端口, 关闭闭包)。
    private func startServer(
        group: EventLoopGroup,
        handle: @escaping @Sendable (NIOAsyncChannel<ByteBuffer, ByteBuffer>) async -> Void
    ) async throws -> (Int, @Sendable () async -> Void) {
        let asyncServer = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { childChannel in
                Self.wrapOnEventLoop(childChannel)
            }
        let port = asyncServer.channel.localAddress?.port ?? 0
        let serverChannel = asyncServer.channel

        let task = Task {
            try? await asyncServer.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { tg in
                    for try await conn in inbound {
                        tg.addTask { await handle(conn) }
                    }
                }
            }
        }
        return (port, { task.cancel(); try? await serverChannel.close() })
    }

    /// 连到 loopback 端口，得到一个 `NIOAsyncChannel`（隧道的一端）。
    private func connect(
        group: EventLoopGroup, port: Int
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: port) { ch in
                Self.wrapOnEventLoop(ch)
            }
    }

    /// 核心回归：A→B 先 EOF，之后 B→A 仍有大段数据，必须全部排空送达（不被早取消截断）。
    func testPipeDrainsLateResponseAfterPeerHalfClose() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        // 大段「响应」：足够大以确保它分布在 pipeline / 水位缓冲里，截断会明显丢字节。
        let responseLen = 64 * 1024
        let response = ByteBuffer(bytes: [UInt8](repeating: 0xAB, count: responseLen))

        // a 的对端（隧道左端外侧 = SOCKS/本地 客户端侧）：
        //   发一行请求 → 立刻半关写端（让 A→B 很快 EOF）→ 读回全部响应字节并计数。
        let received = AsyncStream<Int>.makeStream()
        let receivedCont = received.continuation
        let aPeerHandler: @Sendable (NIOAsyncChannel<ByteBuffer, ByteBuffer>) async -> Void = { ac in
            try? await ac.executeThenClose { inbound, outbound in
                try await outbound.write(ByteBuffer(string: "REQ"))
                // 半关写端：触发隧道里 A→B 方向读到 EOF。
                outbound.finish()
                var total = 0
                for try await chunk in inbound { total += chunk.readableBytes }
                receivedCont.yield(total)
                receivedCont.finish()
            }
        }

        // b 的对端（隧道右端外侧 = 目标服务器侧）：
        //   读到请求后等一会儿（确保 A→B EOF 已先发生），再把大段响应写出，然后半关。
        let bPeerHandler: @Sendable (NIOAsyncChannel<ByteBuffer, ByteBuffer>) async -> Void = { ac in
            try? await ac.executeThenClose { inbound, outbound in
                // 完整消费入站（A→B 方向喂来的 "REQ" + 随后的 EOF）——`executeThenClose`
                // 要求入站被读到 EOF，否则收尾时会 precondition。读到第一段即写大段响应。
                var responded = false
                for try await _ in inbound {
                    if !responded {
                        responded = true
                        // 给隧道一点时间把 A→B 的 EOF 半关传播过来（旧实现此刻会 cancelAll）。
                        try? await Task.sleep(for: .milliseconds(200))
                        try await outbound.write(response)
                        outbound.finish()
                    }
                }
            }
        }

        let (aPort, stopA) = try await startServer(group: group, handle: aPeerHandler)
        let (bPort, stopB) = try await startServer(group: group, handle: bPeerHandler)

        let a = try await connect(group: group, port: aPort)
        let b = try await connect(group: group, port: bPort)

        // 隧道粘合（被测对象）。
        let glue = Task { await TunnelGlue.pipe(a, b) }

        // a 对端应收到**完整** responseLen 字节（修复前会被早取消截断 < responseLen）。
        let total = try await withTimeout(seconds: 10) {
            var got = 0
            for await n in received.stream { got = n }
            return got
        }
        XCTAssertEqual(total, responseLen,
            "晚于 A→B EOF 写出的 B→A 响应必须全部排空送达，未被早取消截断")

        await glue.value
        await stopA()
        await stopB()
        try? await group.shutdownGracefully()
    }

    /// FIX #6 回归：`SOCKS5ForwardListener.glueRemote` 在「目标→本地先 EOF」时必须自己
    /// `bridge.finish()` 收桥 —— 否则「本地→目标」子任务会永远阻塞在 `for await … in localToRemote`
    /// 上、`group.next()` 永不集齐两端、优雅排空**死锁**。
    ///
    /// 这里桥**不**从外部 finish：只能靠 glueRemote 在远端 EOF 时收桥。若回归（删掉
    /// SOCKS5ForwardListener.swift 里目标→本地分支的 `bridge.finish()`），glueRemote 永不返回 →
    /// `withTimeout` 触发、测试失败而非整套假死。消费形态贴合生产：glueRemote 在子 Task 跑（只用
    /// Sendable 的 outbound/桥/远端通道），本地入站在 `executeThenClose` 主体里消费，避免把单消费者
    /// 入站流跨 Task 发送（区域隔离会编译失败）。
    func testGlueRemoteFinishesBridgeOnRemoteEOFAvoidsDeadlock() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        // 远端「目标服务器」侧：立刻半关写端 → glueRemote 的 remoteIn 立刻 EOF（目标→本地先结束）；
        // 再排空入站直到我方 remoteOut.finish() 的 FIN 到达。
        let remotePeer: @Sendable (NIOAsyncChannel<ByteBuffer, ByteBuffer>) async -> Void = { ac in
            try? await ac.executeThenClose { inbound, outbound in
                outbound.finish()
                for try await _ in inbound {}
            }
        }
        // 本地「SOCKS 客户端」侧：保持连接，读到 EOF（glueRemote 末尾 close 本地通道）即返回。
        let localPeer: @Sendable (NIOAsyncChannel<ByteBuffer, ByteBuffer>) async -> Void = { ac in
            try? await ac.executeThenClose { inbound, _ in
                for try await _ in inbound {}
            }
        }

        let (remotePort, stopRemote) = try await startServer(group: group, handle: remotePeer)
        let (localPort, stopLocal) = try await startServer(group: group, handle: localPeer)

        let remoteAsync = try await connect(group: group, port: remotePort)
        let localAsync = try await connect(group: group, port: localPort)
        let localRaw = localAsync.channel

        // 桥：故意**不**外部 finish —— 必须靠 glueRemote 在远端 EOF 时自己收桥。
        let (localToRemote, bridge) = AsyncStream<ByteBuffer>.makeStream()

        // withTimeout 的 operation 是非抛出闭包；用 try? 吸收 executeThenClose 的抛出
        // （本测断言的是「不死锁/不超时」，而非内部数据正确性）。死锁则 withTimeout 抛超时、测试失败。
        try await withTimeout(seconds: 10) {
            try? await localAsync.executeThenClose { localIn, localOut in
                // glueRemote 在子 Task 跑：只捕获 Sendable 的 localOut / 桥 / 远端通道，不碰 localIn。
                let glueTask = Task {
                    await SOCKS5ForwardListener.glueRemote(
                        remoteAsync,
                        localChannel: localRaw,
                        localToRemote: localToRemote,
                        bridge: bridge,
                        localOutbound: localOut)
                }
                // 本地入站在主体消费到 EOF（glueRemote 收尾会 close localRaw → EOF）。
                for try await _ in localIn {}
                await glueTask.value
            }
        }

        await stopRemote()
        await stopLocal()
        try? await group.shutdownGracefully()
    }
}
