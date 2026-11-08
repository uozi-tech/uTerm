import CryptoKit
import Foundation
@preconcurrency import Network

/// 中继在魔数之后写回的挑战：32 字节随机数。签名覆盖它的 base64。
///
/// 认证通过之前中继不说任何别的话（没有名字、relayID、版本、失败原因），扫端口的人认不出它。
nonisolated struct RemoteRelayHello: Sendable {
    static let nonceBytes = 32
    var nonce: String
}

nonisolated struct RemoteRelayRequest: Encodable, Sendable {
    var role: String
    var hostID: String?
    var hostKey: String?
    var session: String?
    var ticket: String?
    var sig: String?
    var hostSig: String?
    /// 用成员证书认证时：自己的成员公钥、证书、能连的主机、到期时间。中继 1.3.0 之前不认。
    var member: String?
    var cert: String?
    var scope: String?
    var exp: Int64?

    /// 成员身份的请求（`client` / `dial`）：用配置里的成员私钥签，持证书时一并带上证书。
    static func member(role: String, config: RemoteRelayConfig, nonce: String, parameter: String = "",
                       hostID: String? = nil, session: String? = nil) throws -> RemoteRelayRequest {
        guard let key = config.memberKey else { throw RemoteRelayError.notConfigured }
        // 过期的证书中继只会一言不发地断开；本地先拦下，说清楚怎么续。
        guard !config.isExpired() else { throw RemoteRelayError.certificateExpired }
        var request = RemoteRelayRequest(
            role: role, hostID: hostID, session: session,
            sig: try RemoteRelaySignature.sign(key, role: role, relayID: config.relayID, nonce: nonce,
                                               parameter: parameter))
        if config.isCertificate {
            request.member = config.memberPublicKey
            request.cert = config.cert
            request.scope = config.scope
            request.exp = config.expires
        }
        return request
    }
}

nonisolated struct RemoteRelayAnswer: Decodable, Sendable {
    var ok: Bool
    var reason: String?
    /// 中继的构建版本。只在成员认证通过（`host` / `client`）后才给，匿名探测拿不到；1.1.1 之前没有。
    var server: String?
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
    /// `revoke` / `revoked`：吊销的成员公钥。
    var member: String?
    /// `revoke`：那张证书的到期时间（Unix 秒）。中继记到那时为止。
    var exp: Int64?

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
    /// 中继在我们发出请求后一言不发就断开：认证前的任何失败都是这样（密钥不对、配置不是这台中继的、
    /// 协议版本不一致）。
    case rejected
    /// 对端正常关闭了连接。
    case closed
    case macOffline
    /// Mac 认识这台设备，但没有允许它经公网接入。
    case notAllowed
    /// 手机这边的配置缺东西（还没导入中继、不知道 Mac 的公钥）。
    case notConfigured
    /// 那台 Mac 发的成员证书过期了（设备太久没连过它）。
    case certificateExpired

    var errorDescription: String? {
        switch self {
        case .unreachable(let reason): return "无法连接中继：\(reason)"
        case .refused(let reason): return Self.describe(reason)
        case .timeout: return "中继没有响应"
        case .malformed: return "中继的回应无法识别"
        case .closed: return "连接已断开"
        case .rejected: return "中继没有接受这份配置（成员密钥不对、配置不属于这台中继，或版本不一致），需要重新导入"
        case .macOffline: return "Mac 不在线。它可能已睡眠，或者没有打开「允许经公网接入」"
        case .notAllowed: return "这台设备还不能经公网连接。在 Mac 的「设置 › 远程控制」里的「允许经公网连接的设备」中勾选它"
        case .notConfigured: return "还没有配置中继"
        case .certificateExpired:
            return "这台 Mac 给的中继授权已过期（很久没连过它）。在同一网络里连一次这台 Mac，或重新扫码配对，就会自动续上"
        }
    }

    private static func describe(_ reason: String) -> String {
        switch reason {
        case "full": return "中继已满"
        case "offline": return "Mac 不在线"
        case "hostKey": return "这台 Mac 在中继上登记的身份不一致。如果重装过 uTerm，在中继所在的主机上运行 uterm-relay forget"
        case "ticket": return "Mac 没有及时响应"
        default: return "中继拒绝了连接（\(reason)）"
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
        let watchdog = DispatchWorkItem { [connection] in connection.cancel() }
        queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        let challenge: Data
        do {
            challenge = try await read(exactly: RemoteRelayHello.nonceBytes)
        } catch RemoteRelayError.closed {
            // 魔数之后什么都不回：不是中继，或者协议版本不一致。
            throw RemoteRelayError.rejected
        }
        return RemoteRelayHello(nonce: challenge.base64EncodedString())
    }

    /// 读请求的答复。中继对认证没过的请求一言不发直接断开，这里把它翻成 `.rejected`。
    func answer(timeout: TimeInterval = requestTimeout) async throws -> RemoteRelayAnswer {
        do {
            return try await receive(timeout: timeout)
        } catch RemoteRelayError.closed {
            throw RemoteRelayError.rejected
        }
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
                } else if error == nil, data?.isEmpty ?? true {
                    // 对端正常关闭（FIN），不是网络出错。
                    continuation.resume(throwing: RemoteRelayError.closed)
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
