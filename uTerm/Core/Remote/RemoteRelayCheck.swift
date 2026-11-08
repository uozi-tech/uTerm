import Foundation
@preconcurrency import Network

/// 从这台设备测一遍中继：TCP 能不能连上、成员密钥认不认、UDP 有没有回 STUN。
///
/// 测的是「这台设备 → 中继」这一段。云厂商安全组没放行时 TCP 就会不通，所以装完从这里测一下
/// 比在服务器上自测有用；但手机走蜂窝时的路径不一定一样。
nonisolated public struct RemoteRelayCheckResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case ok
        case failed
        /// 前一步没过，这一步没法测。
        case skipped
    }

    public var tcp: Outcome
    public var auth: Outcome
    public var udp: Outcome
    /// 从开始连接到读到 hello 的毫秒数。
    public var rttMs: Int?
    /// 中继的构建版本（认证通过才知道）。
    public var serverVersion: String?
    /// 此刻注册在中继上的 Mac 数。
    public var onlineHosts: Int?
    /// UDP 回来的映射地址（本机的公网出口）。
    public var mappedAddress: String?
    /// 失败那一步的原因，给人看的。
    public var problems: [String]

    /// 终端和中继都靠 TCP；UDP 不通只影响打洞（直连），中继照样可用。
    public var isUsable: Bool { tcp == .ok && auth == .ok }
}

nonisolated enum RemoteRelayCheck {
    static func run(config: RemoteRelayConfig, timeout: TimeInterval = 8) async -> RemoteRelayCheckResult {
        async let udp = RemoteRelaySTUNProbe.run(host: config.host, port: config.port)
        var result = await checkTCP(config: config, timeout: timeout)
        switch await udp {
        case .success(let address):
            result.udp = .ok
            result.mappedAddress = address
        case .failure(let reason):
            result.udp = .failed
            result.problems.append(String(localized: "UDP \(String(config.port)) 没有回应（\(reason.description)）：手机和 Mac 无法打洞直连，会一直经中继连接。检查安全组和防火墙是否放行了 UDP。"))
        }
        return result
    }

    private static func checkTCP(config: RemoteRelayConfig, timeout: TimeInterval) async -> RemoteRelayCheckResult {
        var result = RemoteRelayCheckResult(tcp: .failed, auth: .skipped, udp: .skipped, problems: [])
        guard let memberKey = config.memberKey else {
            result.problems.append(String(localized: "这份中继配置里的成员密钥无效，需要重新导入。"))
            return result
        }
        let connection = RemoteRelayConnection(config: config)
        defer { connection.close() }
        let started = Date()
        let hello: RemoteRelayHello
        do {
            hello = try await connection.open(timeout: timeout)
        } catch RemoteRelayError.rejected {
            // TCP 连上了，魔数之后却一言不发：这个端口上不是 uTerm 中继，或者版本不一致。
            result.tcp = .ok
            result.auth = .failed
            result.problems.append(String(localized: "\(config.endpointDescription) 在监听，但不像 uTerm 中继（或中继版本不一致）。检查地址和端口是否指到了别的服务。"))
            return result
        } catch {
            result.problems.append(String(localized: "TCP \(config.endpointDescription) 无法连接（\(error.localizedDescription)）。检查中继是否在运行、云厂商安全组和主机防火墙是否放行了 TCP \(String(config.port))。"))
            return result
        }
        result.tcp = .ok
        result.rttMs = Int(Date().timeIntervalSince(started) * 1000)

        do {
            let signature = try RemoteRelaySignature.sign(memberKey, role: "client", relayID: config.relayID,
                                                          nonce: hello.nonce, parameter: "")
            try await connection.send(RemoteRelayRequest(role: "client", sig: signature))
            let answer = try await connection.answer(timeout: timeout)
            guard answer.ok else { throw RemoteRelayError.refused(answer.reason ?? "") }
            result.auth = .ok
            result.serverVersion = answer.server
            try await connection.send(RemoteRelayMessage(type: "list"))
            // 控制连接上还可能先来一个 pong 之类的帧，读到 hosts 为止。
            for _ in 0..<4 {
                let message: RemoteRelayMessage = try await connection.receive(timeout: timeout)
                if message.type == "hosts" {
                    result.onlineHosts = message.hosts?.count ?? 0
                    break
                }
            }
        } catch RemoteRelayError.rejected where result.auth != .ok {
            result.auth = .failed
            result.problems.append(String(localized: "中继没有接受这份配置，直接断开了连接：成员密钥不对（中继可能更换过密钥），或配置不属于这台中继。需要重新导入。"))
        } catch {
            if result.auth != .ok { result.auth = .failed }
            result.problems.append(error.localizedDescription)
        }
        return result
    }
}

/// 一次 STUN Binding Request。请求补到 48 字节，够中继按协议回 IPv6 的映射地址（见 PROTOCOL.md「STUN」）。
nonisolated enum RemoteRelaySTUNProbe {
    static let attempts = 3
    static let attemptInterval: TimeInterval = 1

    static func run(host: String, port: Int) async -> Result<String, ProbeError> {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failure(.init("端口无效")) }
        let transaction = (0..<12).map { _ in UInt8.random(in: 0...255) }
        let request = makeRequest(transaction: transaction)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        let queue = DispatchQueue(label: "com.uozi.uTerm.remote.stun-check")
        let box = ResultBox()
        return await withCheckedContinuation { continuation in
            box.continuation = continuation
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    for attempt in 0..<attempts {
                        queue.asyncAfter(deadline: .now() + Double(attempt) * attemptInterval) {
                            connection.send(content: request, completion: .idempotent)
                        }
                    }
                    receive(on: connection, transaction: transaction, box: box)
                    queue.asyncAfter(deadline: .now() + Double(attempts) * attemptInterval + 1) {
                        box.finish(.failure(.init(String(localized: "超时"))), connection)
                    }
                case .failed(let error), .waiting(let error):
                    box.finish(.failure(.init(error.localizedDescription)), connection)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func receive(on connection: NWConnection, transaction: [UInt8], box: ResultBox) {
        connection.receiveMessage { data, _, _, error in
            if let data, let answer = parse(data, transaction: transaction) {
                box.finish(answer, connection)
            } else if error == nil {
                receive(on: connection, transaction: transaction, box: box)
            }
        }
    }

    static func makeRequest(transaction: [UInt8]) -> Data {
        var data = Data()
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        let software = Array("uTerm relay check".utf8) + [UInt8](repeating: 0x20, count: 7) // 24 字节，4 对齐
        append16(0x0001)                                  // Binding Request
        append16(UInt16(4 + software.count))              // 属性长度
        withUnsafeBytes(of: UInt32(0x2112_A442).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: transaction)
        append16(0x8022)                                  // SOFTWARE
        append16(UInt16(software.count))
        data.append(contentsOf: software)
        return data
    }

    /// 成功回映射地址；中继回 500（请求太短放不下地址）也说明 UDP 通了。
    static func parse(_ data: Data, transaction: [UInt8]) -> Result<String, ProbeError>? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, Array(bytes[8..<20]) == transaction else { return nil }
        let type = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        if type == 0x0111 { return .success(String(localized: "（地址未返回）")) }
        guard type == 0x0101 else { return nil }
        var offset = 20
        while offset + 4 <= bytes.count {
            let attribute = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let length = Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            let value = offset + 4
            guard value + length <= bytes.count else { return nil }
            if attribute == 0x0020, length >= 8 {
                let port = (UInt16(bytes[value + 2]) << 8 | UInt16(bytes[value + 3])) ^ 0x2112
                let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
                if bytes[value + 1] == 1 {
                    let ip = (0..<4).map { String(bytes[value + 4 + $0] ^ cookie[$0]) }.joined(separator: ".")
                    return .success("\(ip):\(port)")
                }
                if bytes[value + 1] == 2, length >= 20 {
                    let mask = cookie + transaction
                    let raw = (0..<16).map { bytes[value + 4 + $0] ^ mask[$0] }
                    let groups = stride(from: 0, to: 16, by: 2).map { String(UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]), radix: 16) }
                    return .success("[\(groups.joined(separator: ":"))]:\(port)")
                }
            }
            offset = value + (length + 3) / 4 * 4
        }
        return nil
    }

    struct ProbeError: Error, Equatable, Sendable, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// 收包、定时器、失败回调都可能先到，只认第一个。
    private final class ResultBox: @unchecked Sendable {
        var continuation: CheckedContinuation<Result<String, ProbeError>, Never>?
        private let lock = NSLock()

        func finish(_ result: Result<String, ProbeError>, _ connection: NWConnection) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            guard let continuation else { return }
            connection.cancel()
            continuation.resume(returning: result)
        }
    }
}
