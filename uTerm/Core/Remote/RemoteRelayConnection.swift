import CryptoKit
import Foundation
@preconcurrency import Network

nonisolated struct RemoteRelayHello: Decodable, Sendable {
    var relay: String
    var version: Int
    var relayID: String
    var nonce: String
    /// 中继的构建版本（1.1.0 起才有；更早的版本没有这个字段）。
    var server: String?
}

nonisolated struct RemoteRelayRequest: Encodable, Sendable {
    var role: String
    var hostID: String?
    var hostKey: String?
    var session: String?
    var ticket: String?
    var sig: String?
    var hostSig: String?
}

nonisolated struct RemoteRelayAnswer: Decodable, Sendable {
    var ok: Bool
    var reason: String?
}

/// 控制连接上除第一帧之外的所有帧。
nonisolated struct RemoteRelayMessage: Codable, Sendable {
    var type: String
    var session: String?
    var from: String?
    var to: String?
    var box: String?
    var ticket: String?
    var hosts: [String]?

    init(type: String, session: String? = nil, from: String? = nil, to: String? = nil, box: String? = nil) {
        self.type = type
        self.session = session
        self.from = from
        self.to = to
        self.box = box
    }
}

nonisolated enum RemoteRelayError: LocalizedError, Equatable {
    case unreachable(String)
    case refused(String)
    case timeout
    case malformed
    /// Mac 不在中继上（睡着了、没开公网接入）。
    case macOffline
    /// Mac 认识这台设备，但没有允许它经公网接入。
    case notAllowed
    /// 手机这边的配置缺东西（还没导入中继、不知道 Mac 的公钥）。
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .unreachable(let reason): return "连不上中继服务器：\(reason)"
        case .refused(let reason): return Self.describe(reason)
        case .timeout: return "中继服务器没有响应"
        case .malformed: return "中继服务器的回应无法识别"
        case .macOffline: return "Mac 不在线。它可能睡眠了，或者没有打开公网接入"
        case .notAllowed: return "这台设备还不能经公网连接。请在 Mac 的 设置 › 远程控制 里勾选它"
        case .notConfigured: return "还没有配置中继服务器"
        }
    }

    private static func describe(_ reason: String) -> String {
        switch reason {
        case "auth": return "中继服务器拒绝了这份配置，它可能已经换过密钥。请重新导入"
        case "version": return "中继服务器的版本不兼容，请更新"
        case "full": return "中继服务器已满"
        case "offline": return "Mac 不在线"
        case "hostKey": return "这台 Mac 在中继上的身份对不上。如果重装过，请在服务器上运行 uterm-relay forget"
        case "ticket": return "Mac 没有及时响应"
        default: return "中继服务器拒绝了连接（\(reason)）"
        }
    }
}

nonisolated enum RemoteRelaySignature {
    static let prefix = "uterm-relay-v1"

    static func sign(_ key: P256.Signing.PrivateKey, role: String, relayID: String, nonce: String,
                     parameter: String) throws -> String {
        let message = [prefix, role, relayID, nonce, parameter].joined(separator: "\n")
        return try key.signature(for: Data(message.utf8)).derRepresentation.base64EncodedString()
    }
}

/// 到中继的一条 TCP：帧读写。读帧严格按长度读，不多读一个字节，这样 `detach` 之后对端的字节不会丢。
nonisolated final class RemoteRelayConnection: @unchecked Sendable {
    static let maxFrameBytes = 64 * 1024
    static let requestTimeout: TimeInterval = 8

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.relay", qos: .userInteractive)
    private let config: RemoteRelayConfig
    private var readyWaiter: CheckedContinuation<Void, Error>?

    init(config: RemoteRelayConfig) {
        self.config = config
        let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.port)) ?? .any
        connection = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: RemoteLink.parameters())
    }

    /// 连上并读 hello。
    func open(timeout: TimeInterval = requestTimeout) async throws -> RemoteRelayHello {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                self.readyWaiter = continuation
                self.connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                self.connection.start(queue: self.queue)
            }
        }
        var opening = Data("UTRL".utf8)
        opening.append(1)
        try await sendRaw(opening)
        let hello: RemoteRelayHello = try await receive(timeout: timeout)
        guard hello.relay == "uterm-relay", hello.version == 1 else { throw RemoteRelayError.malformed }
        guard hello.relayID == config.relayID else { throw RemoteRelayError.refused("auth") }
        return hello
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            readyWaiter?.resume()
            readyWaiter = nil
        case .waiting(let error), .failed(let error):
            readyWaiter?.resume(throwing: RemoteRelayError.unreachable(error.localizedDescription))
            readyWaiter = nil
            if case .waiting = state { connection.cancel() }
        case .cancelled:
            readyWaiter?.resume(throwing: RemoteRelayError.unreachable("连接已关闭"))
            readyWaiter = nil
        default:
            break
        }
    }

    func send(_ value: some Encodable & Sendable) async throws {
        let body = try JSONEncoder().encode(value)
        guard body.count <= Self.maxFrameBytes else { throw RemoteRelayError.malformed }
        var frame = Data(capacity: 4 + body.count)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        try await sendRaw(frame)
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RemoteRelayError.unreachable(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// 读一帧。`timeout` 到了就断开连接（读随之失败）；nil = 不设时限（常驻的控制连接靠心跳判死）。
    func receive<Value: Decodable>(timeout: TimeInterval? = requestTimeout, as type: Value.Type = Value.self) async throws -> Value {
        let watchdog = timeout.map { seconds in
            let item = DispatchWorkItem { [connection] in connection.cancel() }
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        defer { watchdog?.cancel() }
        let header = try await read(exactly: 4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= Self.maxFrameBytes else { throw RemoteRelayError.malformed }
        let body = try await read(exactly: length)
        do {
            return try JSONDecoder().decode(Value.self, from: body)
        } catch {
            throw RemoteRelayError.malformed
        }
    }

    private func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RemoteRelayError.unreachable(error?.localizedDescription ?? "连接已断开"))
                }
            }
        }
    }

    /// 收到 `ok` 之后：这条 TCP 从此是对端的字节流。
    func detach() -> any RemoteTransport {
        queue.sync {
            connection.stateUpdateHandler = nil
        }
        return RemoteStartedNWTransport(connection: connection)
    }

    func close() {
        connection.cancel()
    }
}

/// 一条已经连上、在自己队列上跑的 `NWConnection`。回调转到 `RemoteLink` 的队列上。
nonisolated final class RemoteStartedNWTransport: RemoteTransport, @unchecked Sendable {
    private let connection: NWConnection
    private var queue: DispatchQueue?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue, onEvent: @escaping @Sendable (RemoteTransportEvent) -> Void) {
        self.queue = queue
        connection.stateUpdateHandler = { state in
            queue.async {
                switch state {
                case .failed(let error): onEvent(.failed(error))
                case .cancelled: onEvent(.cancelled)
                default: break
                }
            }
        }
        queue.async { onEvent(.ready) }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        let queue = self.queue
        connection.send(content: data, completion: .contentProcessed { error in
            queue?.async { completion(error) }
        })
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        let queue = self.queue
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            queue?.async { completion(data, isComplete, error) }
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
