import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 在 127.0.0.1 上起真实的 `NWListener` / `NWConnection`，跑通握手与双向收发。
final class RemoteLinkTests: XCTestCase {

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [RemoteMessage] = []
        private(set) var closed = false
        func add(_ m: RemoteMessage) { lock.lock(); messages.append(m); lock.unlock() }
        func close() { lock.lock(); closed = true; lock.unlock() }
        var all: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    }

    private func hello(_ staticKey: Curve25519.KeyAgreement.PrivateKey,
                       _ ephemeral: Curve25519.KeyAgreement.PrivateKey, name: String) -> RemoteHello {
        RemoteHello(version: RemoteConstants.protocolVersion, deviceID: UUID(), deviceName: name,
                    ephemeralKey: ephemeral.publicKey.rawRepresentation, staticKey: staticKey.publicKey.rawRepresentation)
    }

    /// 起一个监听、连上它，两端都握手完成后返回。
    private func makePair() async throws -> (client: RemoteLink, server: RemoteLink,
                                             clientInbox: Inbox, serverInbox: Inbox,
                                             codes: (String, String), listener: NWListener) {
        let listener = try NWListener(using: RemoteLink.parameters(), on: .any)
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { accepted.continuation.yield($0) }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        var portIterator = ready.stream.makeAsyncIterator()
        let readyPort = await portIterator.next()
        let port = try XCTUnwrap(readyPort)

        let clientInbox = Inbox(), serverInbox = Inbox()
        let client = RemoteLink(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                                         using: RemoteLink.parameters()))
        client.setHandlers(onMessage: { clientInbox.add($0) }, onClose: { _ in clientInbox.close() })

        let clientStatic = Curve25519.KeyAgreement.PrivateKey(), clientEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let serverStatic = Curve25519.KeyAgreement.PrivateKey(), serverEphemeral = Curve25519.KeyAgreement.PrivateKey()

        // `async let` 里不能再碰 self（XCTestCase 不是 Sendable），握手消息先在外面算好。
        let clientHello = hello(clientStatic, clientEphemeral, name: "phone")
        async let clientResult = client.establish(role: .initiator, hello: clientHello,
                                                  staticKey: clientStatic, ephemeralKey: clientEphemeral)
        var acceptIterator = accepted.stream.makeAsyncIterator()
        let acceptedConnection = await acceptIterator.next()
        let serverConnection = try XCTUnwrap(acceptedConnection)
        let server = RemoteLink(connection: serverConnection)
        server.setHandlers(onMessage: { serverInbox.add($0) }, onClose: { _ in serverInbox.close() })
        let serverResult = try await server.establish(role: .responder, hello: hello(serverStatic, serverEphemeral, name: "mac"),
                                                      staticKey: serverStatic, ephemeralKey: serverEphemeral)
        let clientEstablished = try await clientResult
        XCTAssertEqual(clientEstablished.peer.deviceName, "mac")
        XCTAssertEqual(serverResult.peer.deviceName, "phone")
        return (client, server, clientInbox, serverInbox,
                (clientEstablished.verificationCode, serverResult.verificationCode), listener)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func test_handshake_then_bidirectional_messages_over_loopback() async throws {
        let pair = try await makePair()
        defer { pair.listener.cancel() }
        XCTAssertEqual(pair.codes.0, pair.codes.1)

        pair.client.send(RemoteMessage(.input, channel: 3, payload: Data("ls -la\r".utf8)))
        let big = Data((0..<300_000).map { UInt8($0 % 256) })
        pair.server.send(RemoteMessage(.output, channel: 3, payload: big))
        pair.server.send(RemoteMessage(.pong))

        await waitUntil { pair.serverInbox.all.count == 1 && pair.clientInbox.all.count == 2 }
        XCTAssertEqual(pair.serverInbox.all, [RemoteMessage(.input, channel: 3, payload: Data("ls -la\r".utf8))])
        XCTAssertEqual(pair.clientInbox.all, [RemoteMessage(.output, channel: 3, payload: big), RemoteMessage(.pong)])

        pair.client.close()
        await waitUntil { pair.serverInbox.closed }
        XCTAssertTrue(pair.serverInbox.closed, "一端关闭，另一端应收到关闭")
    }

    func test_connecting_to_nothing_fails_fast() async {
        let link = RemoteLink(connection: NWConnection(host: "127.0.0.1", port: 1, using: RemoteLink.parameters()))
        link.setHandlers(onMessage: { _ in }, onClose: { _ in })
        let key = Curve25519.KeyAgreement.PrivateKey()
        let started = Date()
        do {
            _ = try await link.establish(role: .initiator, hello: hello(key, key, name: "p"), staticKey: key, ephemeralKey: key)
            XCTFail("不该连上")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "端口没人监听时不该等到握手超时")
        }
    }
}
