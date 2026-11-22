import CryptoKit
import XCTest
@testable import uTerm

/// `RemoteLink` 只依赖 `RemoteTransport` 的语义：换一个不是 `NWConnection` 的实现，握手、收发、背压、关闭都要照常。
final class RemoteTransportTests: XCTestCase {

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [RemoteMessage] = []
        private var closedFlag = false
        private var writableCount = 0
        func add(_ message: RemoteMessage) { lock.lock(); messages.append(message); lock.unlock() }
        func close() { lock.lock(); closedFlag = true; lock.unlock() }
        func writable() { lock.lock(); writableCount += 1; lock.unlock() }
        var all: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return messages }
        var closed: Bool { lock.lock(); defer { lock.unlock() }; return closedFlag }
        var writableEvents: Int { lock.lock(); defer { lock.unlock() }; return writableCount }
    }

    private func hello(_ staticKey: Curve25519.KeyAgreement.PrivateKey,
                       _ ephemeral: Curve25519.KeyAgreement.PrivateKey, name: String) -> RemoteHello {
        RemoteHello(version: RemoteConstants.protocolVersion, deviceID: UUID(), deviceName: name,
                    ephemeralKey: ephemeral.publicKey.rawRepresentation,
                    staticKey: staticKey.publicKey.rawRepresentation)
    }

    private func establishedPair() async throws -> (client: RemoteLink, server: RemoteLink, clientSide: RemoteMemoryTransport,
                                                    serverSide: RemoteMemoryTransport, clientInbox: Inbox, serverInbox: Inbox) {
        let (clientSide, serverSide) = RemoteMemoryTransport.pair()
        let client = RemoteLink(transport: clientSide), server = RemoteLink(transport: serverSide)
        let clientInbox = Inbox(), serverInbox = Inbox()
        client.setHandlers(onMessage: { clientInbox.add($0) }, onClose: { _ in clientInbox.close() })
        server.setHandlers(onMessage: { serverInbox.add($0) }, onClose: { _ in serverInbox.close() },
                           onWritable: { serverInbox.writable() })
        let clientStatic = Curve25519.KeyAgreement.PrivateKey(), clientEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let serverStatic = Curve25519.KeyAgreement.PrivateKey(), serverEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let clientHello = hello(clientStatic, clientEphemeral, name: "phone")
        let serverHello = hello(serverStatic, serverEphemeral, name: "mac")
        async let clientResult = client.establish(role: .initiator, hello: clientHello, staticKey: clientStatic,
                                                  ephemeralKey: clientEphemeral)
        let serverResult = try await server.establish(role: .responder, hello: serverHello, staticKey: serverStatic,
                                                      ephemeralKey: serverEphemeral)
        let clientEstablished = try await clientResult
        XCTAssertEqual(clientEstablished.verificationCode, serverResult.verificationCode)
        return (client, server, clientSide, serverSide, clientInbox, serverInbox)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    /// 回前台的探测要真等到回音：App 刚从挂起回来时心跳会把「上次收到」拨到现在（挂起期间收不到东西不算死），
    /// 以前探测看的也是这只钟，回前台的探测因此永远判活，死连接要等心跳的 20 秒才发现，画面一直卡着。
    ///
    /// 顺序做成真机上的样子：先发探测，再让链路队列停一阵（心跳的定时器隔了好几拍才来 = 挂起过），
    /// 心跳把钟拨回去之后探测的时限才到。对端一直不出声，探测必须判死。
    func test_foreground_probe_still_fails_when_the_suspension_reset_lands_after_it() async throws {
        let pair = try await establishedPair()
        // 心跳 0.1 秒一拍，隔 0.3 秒以上算挂起过；判死要 30 秒，测试里只有探测能判死。
        pair.client.startHeartbeat(RemoteHeartbeat(pingInterval: 0.3, replyLimit: 30, probeReplyLimit: 0.6))
        try await Task.sleep(for: .milliseconds(200))
        pair.client.probe(replyLimit: 0.6)
        pair.client.queue.async { Thread.sleep(forTimeInterval: 0.35) }
        let failed = await waitUntil(2) { pair.clientInbox.closed }
        XCTAssertTrue(failed, "挂起复位不能让回前台的探测失效")
    }

    func test_handshake_and_large_frames_cross_a_non_network_transport() async throws {
        let pair = try await establishedPair()
        let big = Data((0..<1_500_000).map { UInt8($0 % 251) })
        pair.server.send(RemoteMessage(.output, channel: 2, payload: big))
        pair.client.send(RemoteMessage(.input, channel: 2, payload: Data("x".utf8)))

        let delivered = await waitUntil { pair.clientInbox.all.count == 1 && pair.serverInbox.all.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(pair.clientInbox.all.first?.payload, big)
        XCTAssertEqual(pair.serverInbox.all.first?.payload, Data("x".utf8))
        pair.client.close()
    }

    /// 终端输出的快照兜底靠这条：链路没确认时 `canSendMore` 必须变假，确认后要通知可写。
    func test_held_send_completions_drive_backpressure_and_writable_event() async throws {
        let pair = try await establishedPair()
        pair.serverSide.holdsSendCompletions = true
        let chunk = Data(repeating: 7, count: RemoteConstants.maxInflightBytes + 1024)

        let blocked: Bool = await withCheckedContinuation { continuation in
            pair.server.queue.async {
                pair.server.sendOnQueue(RemoteMessage(.output, channel: 1, payload: chunk))
                continuation.resume(returning: !pair.server.canSendMore)
            }
        }
        XCTAssertTrue(blocked, "未确认的字节超过上限后不该再放行")
        XCTAssertEqual(pair.serverInbox.writableEvents, 0)

        pair.serverSide.releaseSendCompletions()
        let writable = await waitUntil { pair.serverInbox.writableEvents == 1 }
        XCTAssertTrue(writable, "确认回来后要通知可写")
        let drained: Bool = await withCheckedContinuation { continuation in
            pair.server.queue.async { continuation.resume(returning: pair.server.canSendMore) }
        }
        XCTAssertTrue(drained)
        pair.client.close()
    }

    /// 视频有自己的流控。一个关键帧不能让终端以为链路堵了、改发快照。
    func test_video_does_not_count_against_terminal_backpressure() async throws {
        let pair = try await establishedPair()
        pair.serverSide.holdsSendCompletions = true
        let keyframe = Data(repeating: 7, count: RemoteConstants.maxInflightBytes + 1024)
        let open: Bool = await withCheckedContinuation { continuation in
            pair.server.queue.async {
                pair.server.sendOnQueue(RemoteMessage(.desktopFrame, channel: 1, payload: keyframe),
                                        countsTowardBackpressure: false)
                continuation.resume(returning: pair.server.canSendMore)
            }
        }
        XCTAssertTrue(open)
        pair.serverSide.releaseSendCompletions()
        pair.client.close()
    }

    func test_peer_cancel_closes_the_other_side() async throws {
        let pair = try await establishedPair()
        pair.client.close()
        let closed = await waitUntil { pair.serverInbox.closed }
        XCTAssertTrue(closed)
        XCTAssertTrue(pair.clientInbox.closed)
    }

    func test_failure_before_ready_fails_the_handshake() async {
        final class Failing: RemoteTransport, @unchecked Sendable {
            func start(queue: DispatchQueue, onEvent: @escaping @Sendable (RemoteTransportEvent) -> Void) {
                queue.async { onEvent(.waiting(RemoteProtocolError.closed)) }
            }
            func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {}
            func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {}
            func cancel() {}
        }
        let link = RemoteLink(transport: Failing())
        link.setHandlers(onMessage: { _ in }, onClose: { _ in })
        let key = Curve25519.KeyAgreement.PrivateKey()
        do {
            _ = try await link.establish(role: .initiator, hello: hello(key, key, name: "p"), staticKey: key, ephemeralKey: key)
            XCTFail("不该成功")
        } catch {
            XCTAssertTrue(error is RemoteProtocolError)
        }
    }
}
