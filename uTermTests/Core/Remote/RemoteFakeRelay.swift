import Foundation
@preconcurrency import Network
@testable import uTerm

/// 进程内的假中继：只会 `RemoteRelayClient` 控制连接那几句（魔数 → 挑战 → 认证 → list / ping / signal），
/// 不验签。用来在快速测试里模拟「控制连接还在、其实已经死了」这类只有真机切网才见得到的情况。
///
/// - `stallExisting()`：已有的连接从此一言不发、也不读（关 Wi-Fi 后绑在 Wi-Fi 上的那条），新连接照常。
/// - `answersSignals`：false 时信令收下但不回（Mac 不在、不认识这台设备）。
nonisolated final class RemoteFakeRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.fake-relay")
    private let listener: NWListener
    private var portValue: UInt16?
    private var connections: [ObjectIdentifier: (connection: NWConnection, stalled: Bool)] = [:]
    private var acceptedCount = 0
    private var answers = true
    private var ignoresPings = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.portValue = self.listener.port?.rawValue
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    deinit { stop() }

    func stop() {
        queue.sync {
            listener.cancel()
            for entry in connections.values { entry.connection.cancel() }
            connections.removeAll()
        }
    }

    var port: UInt16? { queue.sync { portValue } }
    /// 一共接受过几条连接（判断客户端是不是重连了）。
    var accepted: Int { queue.sync { acceptedCount } }

    var answersSignals: Bool {
        get { queue.sync { answers } }
        set { queue.sync { answers = newValue } }
    }

    /// 收到 ping 不回 pong（中继卡住）。
    var ignoresPing: Bool {
        get { queue.sync { ignoresPings } }
        set { queue.sync { ignoresPings = newValue } }
    }

    func stallExisting() {
        queue.sync {
            for key in connections.keys { connections[key]?.stalled = true }
        }
    }

    func waitUntilReady() async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(5)
        while port == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard let port else { throw RemoteRelayError.unreachable("假中继没起来") }
        return port
    }

    func config() async throws -> RemoteRelayConfig {
        RemoteRelayConfig(name: "假中继", host: "127.0.0.1", port: Int(try await waitUntilReady()), relayID: "fake",
                          key: Data(repeating: 7, count: 32).base64EncodedString())
    }

    // MARK: - 协议

    private func accept(_ connection: NWConnection) {
        acceptedCount += 1
        connections[ObjectIdentifier(connection)] = (connection, false)
        connection.start(queue: queue)
        read(connection, exactly: 5) { [weak self] _ in
            guard let self else { return }
            connection.send(content: Data(repeating: 9, count: RemoteRelayHello.nonceBytes), completion: .idempotent)
            self.readFrame(connection) { _ in
                self.sendFrame(["ok": true, "server": "fake"], on: connection)
                self.serve(connection)
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        readFrame(connection) { [weak self] frame in
            guard let self else { return }
            switch frame["type"] as? String {
            case "list":
                self.sendFrame(["type": "hosts", "hosts": [String]()], on: connection)
            case "ping":
                if !self.ignoresPings { self.sendFrame(["type": "pong"], on: connection) }
            case "signal":
                if self.answers, let session = frame["session"] as? String {
                    self.sendFrame(["type": "signal", "session": session, "box": "reply"], on: connection)
                }
            default:
                break
            }
            self.serve(connection)
        }
    }

    private func isStalled(_ connection: NWConnection) -> Bool {
        connections[ObjectIdentifier(connection)]?.stalled ?? true
    }

    private func read(_ connection: NWConnection, exactly count: Int, then: @escaping (Data) -> Void) {
        guard !isStalled(connection) else { return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count == count, !self.isStalled(connection) else { return }
            then(data)
        }
    }

    private func readFrame(_ connection: NWConnection, then: @escaping ([String: Any]) -> Void) {
        read(connection, exactly: 4) { [weak self] header in
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            self?.read(connection, exactly: length) { body in
                then((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
            }
        }
    }

    private func sendFrame(_ object: [String: Any], on connection: NWConnection) {
        guard !isStalled(connection), let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var frame = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        connection.send(content: frame, completion: .idempotent)
    }
}
