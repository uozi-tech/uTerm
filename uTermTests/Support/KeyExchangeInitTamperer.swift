import Foundation
import NIOCore
import NIOPosix

// 抄自 uAppKit 的 `Tests/USSHKitTests/Support/KeyExchangeInitTamperer.swift`（那边的测试夹具不导出），只加了 `nonisolated`。

/// 本机 TCP 中间人：两个方向都原样转发，只有每个方向的第一个 SSH_MSG_KEXINIT（消息 20）交给 `rewrite` 改写算法列表后
/// 重新分包。第一次 NEWKEYS 之前的包是明文、没有 MAC（RFC 4253 §6），所以能改；包数不变，序号（含 strict KEX）不受影响。
/// 改过的 KEXINIT 会让两端算出的交换哈希不同——这正是要测的：篡改只能让连接失败，不能让它悄悄协商成别的算法。
///
/// `rewrite` 收到第几条 TCP 连接（0 起）、哪个方向、十个 name-list（RFC 4253 §7.1 的顺序：kex、主机密钥、加密 c→s、
/// 加密 s→c、MAC c→s、MAC s→c、压缩 c→s、压缩 s→c、语言 c→s、语言 s→c）。
nonisolated final class KeyExchangeInitTamperer: @unchecked Sendable {
    nonisolated enum Direction: Sendable { case clientToServer, serverToClient }

    static let keyExchange = 0
    static let hostKey = 1

    let port: Int
    private let listener: any Channel
    private let counter: Counter

    /// 已经接进来的 TCP 连接数。
    var connections: Int { counter.count }

    private init(port: Int, listener: any Channel, counter: Counter) {
        self.port = port
        self.listener = listener
        self.counter = counter
    }

    static func start(
        targetPort: Int,
        rewrite: @escaping @Sendable (_ connection: Int, _ direction: Direction, _ lists: inout [[String]]) -> Void
    ) async throws -> KeyExchangeInitTamperer {
        let counter = Counter()
        let group = MultiThreadedEventLoopGroup.singleton
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { inbound in
                let index = counter.next()
                // 入站先不读，等出站连上、两头的 handler 都装好再开始读。
                return ClientBootstrap(group: inbound.eventLoop)
                    .channelInitializer { outbound in
                        outbound.eventLoop.makeCompletedFuture {
                            try outbound.pipeline.syncOperations.addHandlers([
                                ByteToMessageHandler(KexInitRewriter { rewrite(index, .serverToClient, &$0) }),
                                Relay(peer: inbound),
                            ])
                        }
                    }
                    .connect(host: "127.0.0.1", port: targetPort)
                    .flatMapThrowing { outbound in
                        try inbound.pipeline.syncOperations.addHandlers([
                            ByteToMessageHandler(KexInitRewriter { rewrite(index, .clientToServer, &$0) }),
                            Relay(peer: outbound),
                        ])
                        inbound.closeFuture.whenComplete { _ in outbound.close(promise: nil) }
                        outbound.closeFuture.whenComplete { _ in inbound.close(promise: nil) }
                    }
                    .flatMap { inbound.setOption(.autoRead, value: true) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return KeyExchangeInitTamperer(port: listener.localAddress!.port!, listener: listener, counter: counter)
    }

    func stop() async {
        try? await listener.close()
    }

    nonisolated private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func next() -> Int {
            lock.withLock {
                defer { value += 1 }
                return value
            }
        }
    }

    /// 收到什么就写给 `peer`。
    nonisolated private final class Relay: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let peer: any Channel

        init(peer: any Channel) { self.peer = peer }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            peer.close(promise: nil)
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }

    /// 一个方向：版本行原样，之后按 SSH 包切分，改写第一个 KEXINIT，之后的字节原样。
    nonisolated private struct KexInitRewriter: ByteToMessageDecoder {
        typealias InboundOut = ByteBuffer
        let rewrite: @Sendable (inout [[String]]) -> Void
        var sawVersion = false
        var done = false

        init(rewrite: @escaping @Sendable (inout [[String]]) -> Void) {
            self.rewrite = rewrite
        }

        mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
            if done {
                context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: buffer.readableBytes)!))
                return .needMoreData
            }
            if !sawVersion {
                guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else { return .needMoreData }
                let length = newline - buffer.readerIndex + 1
                context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: length)!))
                sawVersion = true
                return .continue
            }
            guard let packetLength = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self),
                  buffer.readableBytes >= 4 + Int(packetLength) else {
                return .needMoreData
            }
            var packet = buffer.readSlice(length: 4 + Int(packetLength))!
            let original = packet
            _ = packet.readInteger(as: UInt32.self)
            let padding = Int(packet.readInteger(as: UInt8.self)!)
            var payload = packet.readSlice(length: packet.readableBytes - padding)!
            guard payload.getInteger(at: payload.readerIndex, as: UInt8.self) == 20 else {
                context.fireChannelRead(wrapInboundOut(original))
                return .continue
            }
            done = true
            payload.moveReaderIndex(forwardBy: 1)
            let cookie = payload.readBytes(length: 16)!
            var lists: [[String]] = []
            for _ in 0..<10 {
                let length = Int(payload.readInteger(as: UInt32.self)!)
                let text = payload.readString(length: length)!
                lists.append(text.isEmpty ? [] : text.split(separator: ",").map(String.init))
            }
            let rest = payload.readBytes(length: payload.readableBytes)!   // first_kex_packet_follows + reserved
            rewrite(&lists)
            var newPayload = ByteBuffer()
            newPayload.writeInteger(UInt8(20))
            newPayload.writeBytes(cookie)
            for list in lists {
                let text = list.joined(separator: ",")
                newPayload.writeInteger(UInt32(text.utf8.count))
                newPayload.writeString(text)
            }
            newPayload.writeBytes(rest)
            // 块大小 8、填充至少 4 字节（RFC 4253 §6）。
            var paddingLength = 8 - (5 + newPayload.readableBytes) % 8
            if paddingLength < 4 { paddingLength += 8 }
            var out = ByteBuffer()
            out.writeInteger(UInt32(1 + newPayload.readableBytes + paddingLength))
            out.writeInteger(UInt8(paddingLength))
            out.writeBuffer(&newPayload)
            out.writeBytes([UInt8](repeating: 0, count: paddingLength))
            context.fireChannelRead(wrapInboundOut(out))
            return .continue
        }
    }
}
