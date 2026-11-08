import CryptoKit
import Foundation

/// 手机到一台中继的控制连接：问谁在线、发信令、发起中继。用到时才连，断了下次用到再连。
///
/// 控制连接是常驻的，而中继不给客户端发心跳（静默 200 秒才断）、TCP 保活也要半分钟，所以它死了这边往往不知道：
/// 关掉 Wi-Fi 改走蜂窝后，信令会一直发进绑在 Wi-Fi 上的那条死连接。于是三条规矩：
/// - 网络一变（`networkChanged`）就扔掉它，下次用到时在新网络上重连；
/// - 安静了 `staleAfter` 再用之前先 ping 一下，`pingTimeout` 内没回就当它死了重连；
/// - 每个请求的时限从调用那一刻算起，连带建连与发送：死连接上发送的完成回调可能永远不来。
actor RemoteRelayClient {
    /// 信令默认等多久（从调用算起，含建连、发送、等 Mac 回复）。
    static let signalTimeout: TimeInterval = 8
    static let listTimeout: TimeInterval = 5
    /// 控制连接安静了多久，再用之前要先 ping。
    static let defaultStaleAfter: Duration = .seconds(20)
    static let pingTimeout: Duration = .milliseconds(1500)

    private let config: RemoteRelayConfig
    private var control: RemoteRelayConnection?
    private var opening: Task<RemoteRelayConnection, Error>?
    private var readLoop: Task<Void, Never>?
    private var hostsWaiters: [CheckedContinuation<Set<UUID>, Error>] = []
    private var signalWaiters: [String: CheckedContinuation<String, Error>] = [:]
    /// 已经交给中继（发送完成）的信令。超时时据此区分「中继那段不通」和「Mac 没回」。
    private var sentSignals: [String: ContinuousClock.Instant] = [:]
    private var pongWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var pongToken = 0
    /// 控制连接上最后一次收到东西的时刻。
    private var lastHeard: ContinuousClock.Instant?
    /// 控制连接走的网卡（日志与诊断用）。
    private(set) var controlInterface: String?
    /// 网络变化的代号：建连途中网络变了，建出来的那条不要（可能绑在旧网卡上）。
    private var networkGeneration = 0

    private let staleAfter: Duration

    init(config: RemoteRelayConfig, staleAfter: Duration = RemoteRelayClient.defaultStaleAfter) {
        self.config = config
        self.staleAfter = staleAfter
    }

    nonisolated var relayConfig: RemoteRelayConfig { config }

    /// 此刻在中继上的 Mac。时限从调用算起。
    func onlineHosts(timeout: TimeInterval = listTimeout) async throws -> Set<UUID> {
        try await RemoteDeadline.run(.seconds(timeout), timeoutError: RemoteRelayError.timeout) {
            let connection = try await self.connected()
            return try await self.list(on: connection)
        }
    }

    private func list(on connection: RemoteRelayConnection) async throws -> Set<UUID> {
        try await withCheckedThrowingContinuation { continuation in
            hostsWaiters.append(continuation)
            Task { await self.sendOrFail(connection, RemoteRelayMessage(type: "list")) }
        }
    }

    /// 确保控制连接是通的（建连前预热、诊断用）。返回控制连接走的网卡。
    @discardableResult
    func warmUp(timeout: TimeInterval = RemoteRelayConnection.requestTimeout) async throws -> String? {
        try await RemoteDeadline.run(.seconds(timeout), timeoutError: RemoteRelayError.timeout) {
            _ = try await self.connected()
            return await self.controlInterface
        }
    }

    /// 发一条信令，等 Mac 回复。时限从调用算起，含建连与发送。
    ///
    /// 到时限还没交给中继：中继那段不通（换了网络、中继卡住），抛 `.timeout` 并扔掉这条控制连接，下次重连。
    /// 交给中继了但 Mac 没回：`.noReply`（Mac 睡着了、不认识这台设备，或者网络太差）。
    func signal(to host: UUID, from device: UUID, session: String, box: String,
                timeout: TimeInterval = signalTimeout) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(timeout)
        let connection = try await RemoteDeadline.run(.seconds(timeout), timeoutError: RemoteRelayError.timeout) {
            try await self.connected()
        }
        let message = RemoteRelayMessage(type: "signal", session: session, from: device.uuidString,
                                         to: host.uuidString, box: box)
        return try await withCheckedThrowingContinuation { continuation in
            signalWaiters[session] = continuation
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self.signalTimedOut(session, connection: connection)
            }
            Task {
                await self.sendOrFail(connection, message)
                await self.markSent(session)
            }
        }
    }

    private func markSent(_ session: String) {
        if signalWaiters[session] != nil { sentSignals[session] = .now }
    }

    private func signalTimedOut(_ session: String, connection: RemoteRelayConnection) {
        guard signalWaiters[session] != nil else { return }
        if let sentAt = sentSignals[session] {
            // 发送完成只说明进了本机的发送缓冲，死连接上也会完成。发出之后中继一个字都没再说过：
            // 这条控制连接靠不住，扔掉，下次（自动重试）在新连接上发。
            let heardSince = lastHeard.map { $0 > sentAt } ?? false
            finishSignal(session, .failure(RemoteRelayError.noReply))
            if !heardSince, control === connection { reset(RemoteRelayError.timeout) }
        } else {
            finishSignal(session, .failure(RemoteRelayError.timeout))
            // 连发出去都做不到：这条控制连接多半已经死了（绑在已经没了的网卡上）。
            if control === connection { reset(RemoteRelayError.timeout) }
        }
    }

    /// 网络变了：现在的控制连接可能绑在已经没了的网卡上，扔掉，下次用到时在新网络上重连。
    /// 正在等的请求立刻失败，调用方自己重试，不用等到超时。
    func networkChanged() {
        guard control != nil || opening != nil else {
            networkGeneration += 1
            return
        }
        AppLogger.notice("中继控制连接：网络变化，丢弃旧连接（\(self.controlInterface ?? "?")）", category: RemoteLog.category)
        networkGeneration += 1
        opening = nil
        reset(RemoteRelayError.unreachable(String(localized: "网络已切换")))
    }

    /// 走中继：等 Mac 回拨接上后，返回到 Mac 的字节流。
    func dial(host: UUID, session: String) async throws -> any RemoteTransport {
        guard config.memberKey != nil else { throw RemoteRelayError.notConfigured }
        let connection = RemoteRelayConnection(config: config)
        do {
            let hello = try await connection.open()
            try await connection.send(RemoteRelayRequest.member(
                role: "dial", config: config, nonce: hello.nonce, parameter: host.uuidString,
                hostID: host.uuidString, session: session))
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
        if let control {
            if let lastHeard, ContinuousClock.now - lastHeard < staleAfter { return control }
            if await isAlive(control) { return control }
            AppLogger.notice("中继控制连接：ping 没有回应，重连（\(self.controlInterface ?? "?")）", category: RemoteLog.category)
            if self.control === control { reset(RemoteRelayError.timeout) }
        }
        if let opening { return try await opening.value }
        let config = self.config
        let task = Task { () throws -> RemoteRelayConnection in
            guard config.memberKey != nil else { throw RemoteRelayError.notConfigured }
            let connection = RemoteRelayConnection(config: config)
            do {
                let hello = try await connection.open()
                try await connection.send(RemoteRelayRequest.member(role: "client", config: config,
                                                                    nonce: hello.nonce))
                let answer = try await connection.answer()
                guard answer.ok else { throw RemoteRelayError.refused(answer.reason ?? "") }
                return connection
            } catch {
                connection.close()
                throw error
            }
        }
        let generation = networkGeneration
        opening = task
        defer { if opening == task { opening = nil } }
        let connection = try await task.value
        guard generation == networkGeneration else {
            connection.close()
            throw RemoteRelayError.unreachable(String(localized: "网络已切换"))
        }
        control = connection
        lastHeard = .now
        controlInterface = connection.interfaceLabel
        readLoop = Task { await self.read(from: connection) }
        return connection
    }

    /// 发一个 ping，`pingTimeout` 内等到 pong（或任何别的帧）就算活着。
    private func isAlive(_ connection: RemoteRelayConnection) async -> Bool {
        let before = lastHeard
        pongToken += 1
        let token = pongToken
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pongWaiters[token] = continuation
            Task {
                await self.sendOrFail(connection, RemoteRelayMessage(type: "ping"))
                try? await Task.sleep(for: Self.pingTimeout)
                await self.expirePong(token)
            }
        }
        return control === connection && lastHeard != before
    }

    private func expirePong(_ token: Int) {
        pongWaiters.removeValue(forKey: token)?.resume()
    }

    private func expirePongs() {
        let waiters = pongWaiters
        pongWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    private func read(from connection: RemoteRelayConnection) async {
        while !Task.isCancelled {
            do {
                let message: RemoteRelayMessage = try await connection.receive(timeout: nil)
                guard control === connection else { return }
                lastHeard = .now
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
                case "pong":
                    expirePongs()
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
        sentSignals[session] = nil
        signalWaiters.removeValue(forKey: session)?.resume(with: result)
    }

    private func reset(_ error: Error) {
        control?.close()
        control = nil
        lastHeard = nil
        controlInterface = nil
        expirePongs()
        sentSignals.removeAll()
        let hostsWaiters = self.hostsWaiters
        self.hostsWaiters = []
        for waiter in hostsWaiters { waiter.resume(throwing: error) }
        let signalWaiters = self.signalWaiters
        self.signalWaiters = [:]
        for waiter in signalWaiters.values { waiter.resume(throwing: error) }
    }
}
