import CryptoKit
import Foundation

/// 手机到一台中继的控制连接：问谁在线、发信令、发起中继。用到时才连，断了下次用到再连。
actor RemoteRelayClient {
    private let config: RemoteRelayConfig
    private var control: RemoteRelayConnection?
    private var opening: Task<RemoteRelayConnection, Error>?
    private var readLoop: Task<Void, Never>?
    private var hostsWaiters: [CheckedContinuation<Set<UUID>, Error>] = []
    private var signalWaiters: [String: CheckedContinuation<String, Error>] = [:]

    init(config: RemoteRelayConfig) {
        self.config = config
    }

    nonisolated var relayConfig: RemoteRelayConfig { config }

    /// 此刻在中继上的 Mac。
    func onlineHosts() async throws -> Set<UUID> {
        let connection = try await connected()
        let hosts: Set<UUID> = try await withCheckedThrowingContinuation { continuation in
            hostsWaiters.append(continuation)
            Task { await self.sendOrFail(connection, RemoteRelayMessage(type: "list")) }
        }
        return hosts
    }

    /// 发一条信令，等 Mac 回复。Mac 不回（不认识这台设备）时按超时处理。
    func signal(to host: UUID, from device: UUID, session: String, box: String,
                timeout: TimeInterval = 5) async throws -> String {
        let connection = try await connected()
        let message = RemoteRelayMessage(type: "signal", session: session, from: device.uuidString,
                                         to: host.uuidString, box: box)
        return try await withCheckedThrowingContinuation { continuation in
            signalWaiters[session] = continuation
            Task {
                await self.sendOrFail(connection, message)
                try? await Task.sleep(for: .seconds(timeout))
                self.finishSignal(session, .failure(RemoteRelayError.notAllowed))
            }
        }
    }

    /// 走中继：等 Mac 回拨接上后，返回到 Mac 的字节流。
    func dial(host: UUID, session: String) async throws -> any RemoteTransport {
        guard let memberKey = config.memberKey else { throw RemoteRelayError.notConfigured }
        let connection = RemoteRelayConnection(config: config)
        do {
            let hello = try await connection.open()
            let signature = try RemoteRelaySignature.sign(memberKey, role: "dial", relayID: config.relayID,
                                                          nonce: hello.nonce, parameter: host.uuidString)
            try await connection.send(RemoteRelayRequest(role: "dial", hostID: host.uuidString, session: session,
                                                         sig: signature))
            // 比中继的 ticket 时限长一点：过期由中继明确告诉我们。
            let answer = try await connection.answer(timeout: 13)
            guard answer.ok else {
                if answer.reason == "offline" { throw RemoteRelayError.macOffline }
                throw RemoteRelayError.refused(answer.reason ?? "")
            }
            return connection.detach()
        } catch {
            connection.close()
            throw error
        }
    }

    func stop() {
        readLoop?.cancel()
        reset(RemoteRelayError.unreachable("已断开"))
    }

    // MARK: - 控制连接

    private func connected() async throws -> RemoteRelayConnection {
        if let control { return control }
        if let opening { return try await opening.value }
        let config = self.config
        let task = Task { () throws -> RemoteRelayConnection in
            guard let memberKey = config.memberKey else { throw RemoteRelayError.notConfigured }
            let connection = RemoteRelayConnection(config: config)
            do {
                let hello = try await connection.open()
                let signature = try RemoteRelaySignature.sign(memberKey, role: "client", relayID: config.relayID,
                                                              nonce: hello.nonce, parameter: "")
                try await connection.send(RemoteRelayRequest(role: "client", sig: signature))
                let answer = try await connection.answer()
                guard answer.ok else { throw RemoteRelayError.refused(answer.reason ?? "") }
                return connection
            } catch {
                connection.close()
                throw error
            }
        }
        opening = task
        defer { opening = nil }
        let connection = try await task.value
        control = connection
        readLoop = Task { await self.read(from: connection) }
        return connection
    }

    private func read(from connection: RemoteRelayConnection) async {
        while !Task.isCancelled {
            do {
                let message: RemoteRelayMessage = try await connection.receive(timeout: nil)
                switch message.type {
                case "hosts":
                    let hosts = Set((message.hosts ?? []).compactMap(UUID.init(uuidString:)))
                    let waiters = hostsWaiters
                    hostsWaiters = []
                    for waiter in waiters { waiter.resume(returning: hosts) }
                case "signal":
                    if let session = message.session, let box = message.box {
                        finishSignal(session, .success(box))
                    }
                case "undeliverable":
                    if let session = message.session { finishSignal(session, .failure(RemoteRelayError.macOffline)) }
                case "ping":
                    try await connection.send(RemoteRelayMessage(type: "pong"))
                default:
                    break
                }
            } catch {
                guard control === connection else { return }
                reset(error)
                return
            }
        }
    }

    private func sendOrFail(_ connection: RemoteRelayConnection, _ message: RemoteRelayMessage) async {
        do {
            try await connection.send(message)
        } catch {
            guard control === connection else { return }
            reset(error)
        }
    }

    private func finishSignal(_ session: String, _ result: Result<String, Error>) {
        signalWaiters.removeValue(forKey: session)?.resume(with: result)
    }

    private func reset(_ error: Error) {
        control?.close()
        control = nil
        let hostsWaiters = self.hostsWaiters
        self.hostsWaiters = []
        for waiter in hostsWaiters { waiter.resume(throwing: error) }
        let signalWaiters = self.signalWaiters
        self.signalWaiters = [:]
        for waiter in signalWaiters.values { waiter.resume(throwing: error) }
    }
}
