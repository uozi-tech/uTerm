import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOPosix
import NIOSSH

/// `-D` 动态转发监听器（自实现 SOCKS5 服务）。
///
/// 在 `client.eventLoop` 上 `ServerBootstrap` 绑 `listenHost:listenPort`。每个连接：
///   1. 读字节直到 `SOCKS5Handshake.parseGreeting` 成功 → 回 `greetingReply`；
///   2. 读字节直到 `parseConnect` 成功 → 得目标 `host:port`；
///   3. `createDirectTCPIPChannel` 经 SSH 连到目标；成功回 `connectReply(success:true)`、
///      失败回 `connectReply(success:false)` 并关闭；
///   4. `TunnelGlue.pipe` 双向泵（剩余已读但未消费的字节先 flush 给目标）。
///
/// 保留监听 `Channel` 句柄供 `close()`。bind 失败由 `start()` 抛出。
actor SOCKS5ForwardListener {
    private let connected: ConnectedClient
    private let listenHost: String
    private let listenPort: Int

    private var serverChannel: Channel?

    init(connected: ConnectedClient, listenHost: String, listenPort: Int) {
        self.connected = connected
        self.listenHost = listenHost
        self.listenPort = listenPort
    }

    /// 绑定本地 SOCKS5 监听。bind 失败抛出。
    func start() async throws {
        let eventLoop = connected.target.eventLoop
        let connected = self.connected

        let bootstrap = ServerBootstrap(group: eventLoop)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // 半关键设(#6)：SOCKS 客户端发完请求半关写端(FIN)时不要整通道关闭，否则目标仍在
            // 流式回包就被 glueRemote 取消截断。设 true 让对端 FIN 只让本地入站 EOF、出站仍可写。
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }

        let serverChannel = try await bootstrap.bind(host: listenHost, port: listenPort).get()
        self.serverChannel = serverChannel

        AppLogger.info("动态转发(SOCKS5) 已绑定 \(self.listenHost):\(self.listenPort)",
                       category: ForwardingLog.category)

        let asyncServer = try NIOAsyncChannel<Channel, Never>(
            wrappingChannelSynchronously: serverChannel)

        Task {
            do {
                try await asyncServer.executeThenClose { inbound in
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await localChannel in inbound {
                            group.addTask {
                                await Self.handleAccepted(localChannel, connected: connected)
                            }
                        }
                    }
                }
            } catch {
                // server channel 关闭 → inbound 结束 → 正常退出。
            }
        }
    }

    /// 处理一个 SOCKS5 连接：握手 → CONNECT → direct-tcpip → 粘合。
    ///
    /// 关键约束：NIO 的 `NIOAsyncChannelInboundStream` 是单消费者、其 `AsyncIterator` 不可跨 Task
    /// 共享，且本工程 `SWIFT_APPROACHABLE_CONCURRENCY` 下手动持 `var iterator` 调 `next()` 会被区域
    /// 隔离判为「向 @concurrent 的 next() 发送任务隔离迭代器」而编译失败。`for try await … in` 是工程里
    /// 唯一可编译的消费形态，但一个流只能被一个 `for await` 消费一次。
    ///
    /// 因此用**单循环状态机**消费本地入站：在同一个 `for try await … in inbound` 里先累积字节走 SOCKS5
    /// 握手（greeting → CONNECT），CONNECT 成功即开 direct-tcpip、回 OK 应答；之后同一循环把后续 chunk
    /// 经一座 `AsyncStream` 桥喂给「远端粘合」子任务（本地→目标方向）。远端粘合子任务用 `executeThenClose`
    /// 作用域管 direct-tcpip 通道：从桥读本地→目标、从 `remoteIn` 读目标→本地写回 `outbound`
    /// （`NIOAsyncChannelOutboundWriter` 是 `Sendable`，跨任务写本地出站安全）。
    private static func handleAccepted(
        _ localChannel: Channel,
        connected: ConnectedClient
    ) async {
        do {
            // 本地端开出站半关：glueRemote 在目标 EOF 后 localOutbound.finish() 向 SOCKS 客户端
            // 发 FIN（默认 false 时只本地结束写端、不发 FIN）。
            let localAsync = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: localChannel,
                configuration: .init(isOutboundHalfClosureEnabled: true))

            try await localAsync.executeThenClose { inbound, outbound in
                var phase = HandshakePhase.greeting
                var buffer: [UInt8] = []

                // 本地→目标 字节桥：握手后由本循环 yield，远端子任务消费写给 direct-tcpip。
                let (localToRemote, bridge) = AsyncStream<ByteBuffer>.makeStream()
                // 远端粘合子任务句柄，循环结束 / 出错时等它收尾。
                var remoteTask: Task<Void, Never>?

                for try await readChunk in inbound {
                    var chunk = readChunk
                    if let bytes = chunk.readBytes(length: chunk.readableBytes) {
                        buffer.append(contentsOf: bytes)
                    }

                    // 反复推进握手状态机，直到本 chunk 的累积字节榨干（.incomplete / .relay）。
                    parseLoop: while true {
                        let step = try await Self.advanceHandshake(
                            phase: phase, buffer: &buffer,
                            localChannel: localChannel,
                            outbound: outbound, connected: connected,
                            localToRemote: localToRemote, bridge: bridge,
                            remoteTask: &remoteTask)
                        switch step {
                        case .needMoreBytes:
                            break parseLoop
                        case .done:
                            bridge.finish()
                            return
                        case .advanced(let next):
                            phase = next
                        case .relaying:
                            phase = .relay
                            break parseLoop
                        }
                    }
                }

                // 本地入站结束（EOF / 关闭）：收桥让远端子任务半关目标写端、自然收尾。
                bridge.finish()
                await remoteTask?.value
            }
        } catch {
            // 握手 / 粘合任一步出错 —— 连接已在 executeThenClose 收尾，吞掉。
            try? await localChannel.close()
        }
    }

    /// SOCKS5 握手状态机的阶段。
    private enum HandshakePhase {
        case greeting   // 等 / 解析 greeting
        case connect    // 等 / 解析 CONNECT
        case relay      // 握手完成，纯转发
    }

    /// `advanceHandshake` 单步推进结果。
    private enum HandshakeStep {
        case needMoreBytes              // 当前累积不足，回 `for await` 读更多
        case advanced(HandshakePhase)  // 进入下一握手阶段，继续推进
        case relaying                  // 握手成功、已开通道，转入 relay
        case done                      // 终止本连接（握手失败 / 拒绝）
    }

    /// 推进一步握手状态机。消费 `buffer` 中已就绪的字节；按需回应答 / 开 direct-tcpip /
    /// 派远端粘合子任务 / 把 chunk 经桥转发。把控制流细节收进来，让 `handleAccepted` 的循环精简。
    private static func advanceHandshake(
        phase: HandshakePhase,
        buffer: inout [UInt8],
        localChannel: Channel,
        outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>,
        connected: ConnectedClient,
        localToRemote: AsyncStream<ByteBuffer>,
        bridge: AsyncStream<ByteBuffer>.Continuation,
        remoteTask: inout Task<Void, Never>?
    ) async throws -> HandshakeStep {
        switch phase {
        case .greeting:
            switch SOCKS5Handshake.parseGreeting(buffer) {
            case .incomplete:
                return .needMoreBytes
            case .failure:
                try await Self.writeReply(SOCKS5Handshake.greetingReply(accept: false), to: outbound)
                return .done
            case .ok(let noAuth, let consumed):
                buffer.removeFirst(consumed)
                guard noAuth else {
                    try await Self.writeReply(SOCKS5Handshake.greetingReply(accept: false), to: outbound)
                    return .done
                }
                try await Self.writeReply(SOCKS5Handshake.greetingReply(accept: true), to: outbound)
                return .advanced(.connect)
            }

        case .connect:
            switch SOCKS5Handshake.parseConnect(buffer) {
            case .incomplete:
                return .needMoreBytes
            case .failure:
                try await Self.writeReply(SOCKS5Handshake.connectReply(success: false), to: outbound)
                return .done
            case .ok(let request, let usedBytes):
                buffer.removeFirst(usedBytes)

                // 开 direct-tcpip 到目标。
                let directChannel: Channel
                do {
                    let originator = try SocketAddress(ipAddress: "fe80::1", port: 22)
                    directChannel = try await connected.target.createDirectTCPIPChannel(
                        using: SSHChannelType.DirectTCPIP(
                            targetHost: request.host,
                            targetPort: request.port,
                            originatorAddress: originator),
                        initialize: { $0.eventLoop.makeSucceededVoidFuture() })
                } catch {
                    AppLogger.error(
                        "SOCKS5 开通道失败 → \(request.host):\(request.port)：\(error.localizedDescription)",
                        category: ForwardingLog.category)
                    try await Self.writeReply(SOCKS5Handshake.connectReply(success: false), to: outbound)
                    return .done
                }

                // 成功应答。
                try await Self.writeReply(SOCKS5Handshake.connectReply(success: true), to: outbound)

                // 远端粘合子任务：作用域管 direct-tcpip 通道，双向泵。
                let remoteAsync = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                    wrappingChannelSynchronously: directChannel)
                remoteTask = Task { [bridge] in
                    await Self.glueRemote(
                        remoteAsync,
                        localChannel: localChannel,
                        localToRemote: localToRemote,
                        bridge: bridge,
                        localOutbound: outbound)
                }

                // 把握手后已读但未消费的剩余字节先喂给桥（→ 目标）。
                if !buffer.isEmpty {
                    var leftover = ByteBuffer()
                    leftover.writeBytes(buffer)
                    bridge.yield(leftover)
                    buffer.removeAll(keepingCapacity: false)
                }
                return .relaying
            }

        case .relay:
            // 本地→目标：把本 chunk 的字节经桥喂给远端子任务。
            if !buffer.isEmpty {
                var fwd = ByteBuffer()
                fwd.writeBytes(buffer)
                buffer.removeAll(keepingCapacity: true)
                bridge.yield(fwd)
            }
            return .needMoreBytes
        }
    }

    /// 把一段字节作为应答写到本地出站。
    private static func writeReply(
        _ bytes: [UInt8],
        to outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    ) async throws {
        var reply = ByteBuffer()
        reply.writeBytes(bytes)
        try await outbound.write(reply)
    }

    /// 远端 direct-tcpip 通道的双向粘合：本地→目标取自 `localToRemote` 桥；目标→本地写回
    /// `localOutbound`（`NIOAsyncChannelOutboundWriter` 是 `Sendable`，跨任务写本地出站安全）。
    /// 用 `executeThenClose` 作用域管 direct-tcpip 通道生命周期 —— 闭包返回即关闭，防泄漏。
    ///
    /// **优雅半关**：某方向读到 EOF 时只半关对端写端（`remoteOut.finish()` / `localOutbound.finish()`），
    /// 另一方向继续把缓冲 / 在途字节排空，直到它也读到 EOF；两个方向**都**收尾后才返回。不要在第一个
    /// 方向结束时就 `cancelAll()`，否则会截断仍在流动的对向响应。只有某方向**抛错**时才取消整组、抛出。
    ///
    /// 与 `TunnelGlue.pipe` 的对称两端不同：本地→目标这一向不是真 NIO 入站流，而是 `localToRemote`
    /// **桥**，其结束由 `handleAccepted` 的本地读循环 `bridge.finish()` 控制。若目标→本地先读到 EOF
    /// 却不收桥，本地→目标这向会一直阻塞在桥上、优雅排空永不完成 → 死锁。故目标→本地 EOF 时除半关
    /// 本地写端外，**还要 `bridge.finish()`** 让桥消费向收尾。`AsyncStream.Continuation.finish()` 幂等，
    /// `handleAccepted` 末尾再 `finish()` 一次无害。
    ///
    /// 泄漏紧致性：远端先关时（目标→本地 EOF / 重置），本函数返回后必须主动关掉 `localChannel`，
    /// 否则 `handleAccepted` 里另一 Task 的本地读循环 `for try await … in inbound` 会一直阻塞在本地入站、
    /// 留下半开 socket 且本地→目标桥缓冲可无界增长。故本函数所有退出路径（远端 EOF / 出错 / 取消，
    /// 都会被下面 do/catch 收口、控制流必到函数末尾）末尾 `try? await localChannel.close()`：关本地
    /// → 读循环的 inbound 序列终止 → 其 `executeThenClose` 返回。`Channel.close()` 幂等，本地若已在
    /// 收尾（本地先关那条路径）则无害。
    // internal(非 private)：让转发测试能直接驱动「目标→本地先 EOF 时 bridge.finish() 收桥、
    // 避免本地→目标桥消费向死锁」这条最高风险路径(#6)。
    static func glueRemote(
        _ remoteAsync: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        localChannel: Channel,
        localToRemote: AsyncStream<ByteBuffer>,
        bridge: AsyncStream<ByteBuffer>.Continuation,
        localOutbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    ) async {
        do {
            try await remoteAsync.executeThenClose { remoteIn, remoteOut in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // 本地 → 目标（消费桥）。
                    group.addTask {
                        for await chunk in localToRemote {
                            try await remoteOut.write(chunk)
                        }
                        // 桥结束（本地入站 EOF / 关闭）：半关目标写端，让目标→本地排空。
                        remoteOut.finish()
                    }
                    // 目标 → 本地。
                    group.addTask {
                        for try await chunk in remoteIn {
                            try await localOutbound.write(chunk)
                        }
                        // 目标 EOF：半关本地写端，并收桥让本地→目标这向收尾（否则它阻塞在桥上、
                        // 优雅排空死锁）。`finish()` 幂等。
                        localOutbound.finish()
                        bridge.finish()
                    }
                    // 优雅排空：等**两个**方向都正常结束（各返回一次）。某方向先到 EOF 只半关对端
                    // 写端、不取消对向。任一方向抛错才取消整组并抛出（交由外层 catch 吞掉），避免
                    // 泄漏未结束的子任务。
                    do {
                        while try await group.next() != nil {}
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
            }
        } catch {
            // 任一端重置 / 出错 —— 视作隧道正常结束，吞掉。
        }
        // 远端关闭（含先关那条路径）后主动关本地，解阻塞 handleAccepted 的本地读循环。
        try? await localChannel.close()
    }

    /// 关闭监听通道。
    func close() async {
        if let serverChannel {
            try? await serverChannel.close()
            self.serverChannel = nil
            AppLogger.info("动态转发(SOCKS5) 已停止 \(self.listenHost):\(self.listenPort)",
                           category: ForwardingLog.category)
        }
    }
}
