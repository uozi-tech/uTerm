import CryptoKit
import Foundation

/// 一条认证过的中继控制连接（`host` 或 `client`）。真实的是 `RemoteGroupRelayNetworkControl`，测试换成内存里的假中继。
nonisolated protocol RemoteGroupRelayControl: AnyObject, Sendable {
    /// 开始收（只调一次）：消息按序回调，断开（含 `close()`）调一次 `onClose`。回调在任意线程上。
    func start(onMessage: @escaping @Sendable (RemoteRelayMessage) -> Void, onClose: @escaping @Sendable () -> Void)
    /// 按调用的顺序发出。断开之后调用无害。
    func send(_ message: RemoteRelayMessage)
    /// 已经交给 `send` 的发完再断开。
    func close()
}

nonisolated struct RemoteGroupRelayRegistration: Sendable {
    let control: any RemoteGroupRelayControl
    /// 中继的构建版本（`{"ok":true,"server":…}`）。
    let server: String?
}

/// 连中继：以 `host` 身份注册信箱、以 `client` 身份开一条往别人信箱投递的连接。被拒抛 `RemoteRelayError.refused(reason)`。
nonisolated protocol RemoteGroupRelayDialer: Sendable {
    func registerMailbox(_ mailbox: UUID, hostKey: P256.Signing.PrivateKey,
                         config: RemoteRelayConfig) async throws -> RemoteGroupRelayRegistration
    func openClient(config: RemoteRelayConfig) async throws -> RemoteGroupRelayRegistration
}

/// 经真实网络连中继（`RemoteRelayConnection`：分帧、认证）。
nonisolated struct RemoteGroupRelayNetworkDialer: RemoteGroupRelayDialer {
    func registerMailbox(_ mailbox: UUID, hostKey: P256.Signing.PrivateKey,
                         config: RemoteRelayConfig) async throws -> RemoteGroupRelayRegistration {
        // 成员证书只能连一台主机，注册不了。
        guard !config.isCertificate, let memberKey = config.memberKey else { throw RemoteRelayError.notConfigured }
        let id = mailbox.uuidString
        return try await open(config: config) { nonce in
            RemoteRelayRequest(
                role: "host", hostID: id, hostKey: hostKey.publicKey.derRepresentation.base64EncodedString(),
                sig: try RemoteRelaySignature.sign(memberKey, role: "host", relayID: config.relayID, nonce: nonce, parameter: id),
                hostSig: try RemoteRelaySignature.sign(hostKey, role: "host", relayID: config.relayID, nonce: nonce,
                                                       parameter: id))
        }
    }

    func openClient(config: RemoteRelayConfig) async throws -> RemoteGroupRelayRegistration {
        try await open(config: config) { nonce in
            try RemoteRelayRequest.member(role: "client", config: config, nonce: nonce)
        }
    }

    private func open(config: RemoteRelayConfig,
                      request: (String) throws -> RemoteRelayRequest) async throws -> RemoteGroupRelayRegistration {
        let connection = RemoteRelayConnection(config: config)
        do {
            let hello = try await connection.open()
            try await connection.send(try request(hello.nonce))
            let answer = try await connection.answer()
            guard answer.ok else { throw RemoteRelayError.refused(answer.reason ?? "") }
            return RemoteGroupRelayRegistration(control: RemoteGroupRelayNetworkControl(connection: connection),
                                                server: answer.server)
        } catch {
            connection.close()
            throw error
        }
    }
}

/// 一条真实的中继控制连接：一个任务按序发（信令的密封帧带序号，乱了对端就解不开），一个任务收。
nonisolated final class RemoteGroupRelayNetworkControl: RemoteGroupRelayControl, @unchecked Sendable {
    /// `close()` 之后最多等多久把排着的发完（死连接上发送可能永远不完成）。
    private static let drainTimeout: TimeInterval = 2

    private let connection: RemoteRelayConnection
    private let stream: AsyncStream<RemoteRelayMessage>
    private let outbox: AsyncStream<RemoteRelayMessage>.Continuation
    private let lock = NSLock()
    private var onClose: (@Sendable () -> Void)?
    private var reader: Task<Void, Never>?
    private var isClosed = false

    init(connection: RemoteRelayConnection) {
        self.connection = connection
        (stream, outbox) = AsyncStream.makeStream(of: RemoteRelayMessage.self)
    }

    func start(onMessage: @escaping @Sendable (RemoteRelayMessage) -> Void, onClose: @escaping @Sendable () -> Void) {
        lock.withLock { self.onClose = onClose }
        let connection = connection, stream = stream
        Task { [weak self] in
            for await message in stream {
                do {
                    try await connection.send(message)
                } catch {
                    break
                }
            }
            connection.close()
            self?.finish()
        }
        let reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message: RemoteRelayMessage = try await connection.receive(timeout: nil)
                    onMessage(message)
                } catch {
                    break
                }
            }
            self?.finish()
        }
        let finished = lock.withLock {
            self.reader = reader
            return isClosed
        }
        if finished { reader.cancel() }
    }

    func send(_ message: RemoteRelayMessage) {
        outbox.yield(message)
    }

    func close() {
        outbox.finish()
        let connection = connection
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainTimeout) { connection.close() }
    }

    private func finish() {
        let (callback, reader): ((@Sendable () -> Void)?, Task<Void, Never>?) = lock.withLock {
            guard !isClosed else { return (nil, nil) }
            isClosed = true
            defer { onClose = nil }
            return (onClose, self.reader)
        }
        guard let callback else { return }
        outbox.finish()
        connection.close()
        reader?.cancel()
        callback()
    }
}

/// 快通道的中继一侧（docs/remote-device-group-design.md §7.4「中继信箱」，落地见 §17）。
///
/// - **信箱**：拿默认中继配置里的成员密钥，以 `host` 身份注册 `RemoteGroupMailbox.hostID(for: 本机设备 ID)`，
///   用只存本机的信箱钥匙签。收到的 `signal` 是别的设备拨进来的线路；`incoming`（有人要走中继拨号）不理；
///   被顶替（`superseded`）不马上重连，过一阵再试。
/// - **投递**：一条 `client` 连接，`list` 看哪些信箱在线（连上时马上问，之后每 15 秒），对在线的、钥匙串名册里登记过的
///   设备各开一个 `session`。每台对端在这条连接上固定用一个 session（中继给每条 `client` 连接最多记 64 个 session，
///   从不忘），重拨时在同一个 session 上重新握手。
/// - **挑线路**：和局域网一样由设备 ID 小的一方先拨，大的一方看到对方在线 5 秒还没连上才自己拨；两条都通时两边按同一条
///   规则留一条（拨号的是 ID 小的那条，同一方拨的留新的）。和这台对端已经连着局域网时不拨（同步层也不让中继顶掉局域网）。
/// - 两条控制连接各自 60 秒 ping 一次，20 秒没有回音就重连；断了按退避重连（1 秒起翻倍，最多 60 秒）。默认中继配置
///   每 30 秒看一眼，换了就全部重来；没有、或者是成员证书（注册不了主机）时整条线路不开。
///
/// 状态都在自己的队列上，所有线路（`RemoteGroupRelaySession`）也由这个队列驱动。
nonisolated final class RemoteGroupRelayService: @unchecked Sendable {
    struct Timing: Sendable {
        var tick: TimeInterval = 1
        var listInterval: TimeInterval = 15
        var configInterval: TimeInterval = 30
        var pingInterval: TimeInterval = 60
        var pongTimeout: TimeInterval = 20
        var fallbackDialDelay: TimeInterval = 5
        /// 控制连接断了以后重连的退避上限。
        var maxBackoff: TimeInterval = 60
        /// 一台对端拨不通时的退避上限。
        var maxDialBackoff: TimeInterval = 30
        /// 被中继拒绝（满了、信箱 ID 绑着别的钥匙、成员密钥不认）或被顶替之后多久再试，每次翻倍。
        var refusedRetry: TimeInterval = 300
        var maxRefusedRetry: TimeInterval = 3600
        var link = RemoteGroupRelaySession.Timing.standard

        static let standard = Timing()
    }

    /// 拥有者（快通道）给的东西。
    struct Options: Sendable {
        /// 默认中继配置。
        var config: @Sendable () -> RemoteRelayConfig?
        /// 本机信箱的主机钥匙。
        var mailboxKey: @Sendable () throws -> P256.Signing.PrivateKey
        var dialer: any RemoteGroupRelayDialer
        var timing: Timing = .standard
        /// 网络一变就重连两条控制连接（App 里开；测试里关）。
        var watchesNetwork = false

        /// App 里用的：iCloud 钥匙串里的默认中继、钥匙串里的信箱钥匙、真实网络。
        static func live() -> Options {
            Options(config: { RemoteRelayConfigStore().load() }, mailboxKey: { try RemoteGroupMailbox.hostKey() },
                    dialer: RemoteGroupRelayNetworkDialer(), watchesNetwork: true)
        }
    }

    /// 同时在握手的拨进来的线路最多几条。
    static let maxInboundHandshakes = 16
    /// 往外拨的对端最多几台（中继给每条 `client` 连接最多 64 个 session）。
    static let maxPeers = 60
    private static let maxResets = 256

    private enum Line: String {
        case mailbox
        case client
    }

    /// 一条控制连接的状态。
    private struct ControlState {
        var control: (any RemoteGroupRelayControl)?
        /// 每次连上加一：断开、收到的消息按它认是不是还是这一条。
        var instance = 0
        var connecting = false
        var retryAt = Date.distantPast
        var backoff: TimeInterval = 1
        var refusedBackoff: TimeInterval = 0
        var lastHeard = Date()
        var lastPing = Date()
        var pingAsked: Date?
        /// 被顶替了：断开后按 `refusedBackoff` 等。
        var superseded = false
        /// 上一次记日志的失败原因：同样的失败不重复记。
        var lastFailure: String?
    }

    private struct PeerState {
        var onlineSince: Date?
        var retryAt = Date.distantPast
        var backoff: TimeInterval = 1
        var attempts = 0
    }

    let local: RemoteGroupDevice
    let mailboxID: UUID
    private let identityKey: Curve25519.KeyAgreement.PrivateKey
    private let trusted: @Sendable () -> [RemoteGroupDevice]
    private let hasPreferredLink: @Sendable (UUID) -> Bool
    private let onLink: @Sendable (any RemoteGroupPeerLink) -> Void
    private let options: Options
    private var timing: Timing { options.timing }
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.group-relay")
    private var running = false
    /// 每次 start / stop / 换配置加一：在路上的建连结果按它认作废没有。
    private var generation = 0
    private var timer: DispatchSourceTimer?
    private var config: RemoteRelayConfig?
    private var configCheckedAt = Date.distantPast
    private var configNote: String?
    private var mailboxKeyCache: P256.Signing.PrivateKey?
    private var mailbox = ControlState()
    private var client = ControlState()
    /// 上一次 `list` 回来的在线主机（含别人的远控主机与信箱）。
    private var online: Set<UUID> = []
    private var listed = false
    private var lastList = Date.distantPast
    /// 上一次 `list` 时读的钥匙串名册（按设备 ID 分组）：每秒的检查不去读钥匙串。
    private var candidates: [UUID: [RemoteGroupDevice]] = [:]
    private var peers: [UUID: PeerState] = [:]
    /// 当前 `client` 连接上每台对端固定用的 session。
    private var peerSessions: [UUID: String] = [:]
    /// 本机拨出去的线路（session → 线路）与拨进本机信箱的（session → 线路），含还在握手的。
    private var outbound: [String: RemoteGroupRelaySession] = [:]
    private var inbound: [String: RemoteGroupRelaySession] = [:]
    /// 握好手、交给了同步层的（每台对端一条）。
    private var active: [UUID: RemoteGroupRelaySession] = [:]
    private var resetsSent: [Data] = []
    /// 网络变化的监听（只在主线程上碰）。
    nonisolated(unsafe) private var networkWatcher: RemoteNetworkWatcher?

    init(local: RemoteGroupDevice, identityKey: Curve25519.KeyAgreement.PrivateKey,
         trusted: @escaping @Sendable () -> [RemoteGroupDevice], options: Options,
         hasPreferredLink: @escaping @Sendable (UUID) -> Bool = { _ in false },
         onLink: @escaping @Sendable (any RemoteGroupPeerLink) -> Void) {
        self.local = local
        mailboxID = RemoteGroupMailbox.hostID(for: local.id)
        self.identityKey = identityKey
        self.trusted = trusted
        self.options = options
        self.hasPreferredLink = hasPreferredLink
        self.onLink = onLink
    }

    // MARK: - 测试、诊断

    /// 已握好手的对端。
    var connectedPeers: [UUID] { queue.sync { Array(active.keys) } }
    /// 两条控制连接是不是连着。
    var isRegistered: Bool { queue.sync { mailbox.control != nil } }
    var isListening: Bool { queue.sync { client.control != nil } }
    /// 握好手的那条是谁拨的。
    func opener(for peer: UUID) -> UUID? { queue.sync { active[peer]?.opener } }

    /// 测试用：不告诉对端就停（模拟断网、进程被杀）：先扔掉两条控制连接，线路收掉时的 `bye` 发不出去。
    func stopAbruptlyForTesting() {
        queue.sync {
            running = false
            generation += 1
            timer?.cancel()
            timer = nil
            for line in [Line.mailbox, .client] {
                let control = state(line).control
                update(line) { $0 = ControlState(instance: $0.instance + 1) }
                control?.close()
            }
            tearDown()
        }
    }

    /// 测试用：信箱这头忘掉所有拨进来的线路、不告诉拨号方（像信箱刚重连过）。
    func forgetInboundForTesting() {
        queue.sync {
            let all = Array(inbound.values)
            inbound = [:]
            for link in all { link.end(RemoteGroupRelayLinkError.reset) }
        }
    }

    // MARK: - 起停

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            generation += 1
            configCheckedAt = .distantPast
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timing.tick, repeating: timing.tick)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            tick()
        }
        if options.watchesNetwork {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.networkWatcher == nil else { return }
                    self.networkWatcher = RemoteNetworkWatcher { [weak self] snapshot in
                        if snapshot.isSatisfied { self?.networkChanged() }
                    }
                }
            }
        }
    }

    /// 关掉所有线路（先告诉对端）和两条控制连接。
    func stop() {
        queue.sync {
            running = false
            generation += 1
            timer?.cancel()
            timer = nil
            tearDown()
            config = nil
            configNote = nil
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.networkWatcher = nil }
        }
    }

    /// 同步层说和这台对端的线路（局域网）断了：信箱在线就马上拨中继，不等下一拍。
    func linkLost(_ peer: UUID) {
        queue.async { [self] in
            guard running, peers[peer] != nil else { return }
            peers[peer]?.retryAt = .distantPast
            dialDue(now: Date())
        }
    }

    private func networkChanged() {
        queue.async { [self] in
            guard running else { return }
            for line in [Line.mailbox, .client] {
                update(line) {
                    $0.backoff = 1
                    $0.retryAt = .distantPast
                }
                state(line).control?.close()
            }
        }
    }

    /// 关掉所有线路与控制连接（不改 running）。
    private func tearDown() {
        for session in Array(outbound.values) + Array(inbound.values) { session.end(RemoteGroupRelayLinkError.closed) }
        outbound = [:]
        inbound = [:]
        active = [:]
        peerSessions = [:]
        peers = [:]
        online = []
        listed = false
        candidates = [:]
        for line in [Line.mailbox, .client] {
            state(line).control?.close()
            update(line) { $0 = ControlState(instance: $0.instance + 1) }
        }
    }

    // MARK: - 每一拍

    private func tick() {
        guard running else { return }
        let now = Date()
        if now.timeIntervalSince(configCheckedAt) >= timing.configInterval { refreshConfig(now: now) }
        guard config != nil else { return }
        maintain(.mailbox, now: now)
        maintain(.client, now: now)
        if let control = client.control, now.timeIntervalSince(lastList) >= timing.listInterval {
            lastList = now
            control.send(RemoteRelayMessage(type: "list"))
        }
        for session in Array(outbound.values) + Array(inbound.values) { session.tick(now: now) }
        dialDue(now: now)
    }

    private func refreshConfig(now: Date) {
        configCheckedAt = now
        let loaded = options.config()
        var usable: RemoteRelayConfig?
        let note: String
        if let loaded {
            if loaded.isCertificate {
                note = "默认中继只有成员证书，注册不了信箱，中继这条不开"
            } else if !loaded.isValid {
                note = "默认中继的配置无效，中继这条不开"
            } else {
                usable = loaded
                note = "用默认中继 \(loaded.endpointDescription)"
            }
        } else {
            note = "没有默认中继，中继这条不开"
        }
        if note != configNote {
            configNote = note
            AppLogger.notice("设备组：快通道\(note)", category: RemoteLog.category)
        }
        guard usable != config else { return }
        if config != nil { tearDown() }
        generation += 1
        config = usable
        mailboxKeyCache = nil
    }

    // MARK: - 控制连接

    private func state(_ line: Line) -> ControlState {
        line == .mailbox ? mailbox : client
    }

    private func update(_ line: Line, _ change: (inout ControlState) -> Void) {
        if line == .mailbox { change(&mailbox) } else { change(&client) }
    }

    private func maintain(_ line: Line, now: Date) {
        let current = state(line)
        guard let control = current.control else {
            if !current.connecting, now >= current.retryAt { connect(line) }
            return
        }
        if let asked = current.pingAsked {
            if current.lastHeard >= asked {
                update(line) { $0.pingAsked = nil }
            } else if now.timeIntervalSince(asked) >= timing.pongTimeout {
                // 只有中继本身的回答才算数：反向代理会替它回 TCP keepalive。
                let message = "设备组：中继\(line == .mailbox ? "信箱" : "投递")连接 \(Int(timing.pongTimeout)) 秒没有回音，重连"
                AppLogger.info(message, category: RemoteLog.category)
                control.close()
                return controlClosed(line, instance: current.instance)
            }
        } else if now.timeIntervalSince(current.lastPing) >= timing.pingInterval {
            update(line) {
                $0.lastPing = now
                $0.pingAsked = now
            }
            control.send(RemoteRelayMessage(type: "ping"))
        }
    }

    private func connect(_ line: Line) {
        guard let config else { return }
        let dialer = options.dialer, generation = generation, mailboxID = mailboxID
        let hostKey: P256.Signing.PrivateKey?
        if line == .mailbox {
            if mailboxKeyCache == nil {
                do {
                    mailboxKeyCache = try options.mailboxKey()
                } catch {
                    return connectFailed(line, error: error, generation: generation)
                }
            }
            hostKey = mailboxKeyCache
        } else {
            hostKey = nil
        }
        update(line) { $0.connecting = true }
        Task { [weak self] in
            do {
                let registration: RemoteGroupRelayRegistration
                if let hostKey {
                    registration = try await dialer.registerMailbox(mailboxID, hostKey: hostKey, config: config)
                } else {
                    registration = try await dialer.openClient(config: config)
                }
                guard let self else { return registration.control.close() }
                self.queue.async { self.connected(line, registration, generation: generation) }
            } catch {
                guard let self else { return }
                self.queue.async { self.connectFailed(line, error: error, generation: generation) }
            }
        }
    }

    private func connected(_ line: Line, _ registration: RemoteGroupRelayRegistration, generation: Int) {
        guard running, generation == self.generation, let config else { return registration.control.close() }
        let now = Date()
        update(line) {
            $0.control = registration.control
            $0.instance += 1
            $0.connecting = false
            $0.backoff = 1
            $0.refusedBackoff = 0
            $0.superseded = false
            $0.lastFailure = nil
            $0.lastHeard = now
            $0.lastPing = now
            $0.pingAsked = nil
        }
        let instance = state(line).instance
        registration.control.start(onMessage: { [weak self] message in
            guard let self else { return }
            self.queue.async { self.handle(message, on: line, instance: instance) }
        }, onClose: { [weak self] in
            guard let self else { return }
            self.queue.async { self.controlClosed(line, instance: instance) }
        })
        switch line {
        case .mailbox:
            AppLogger.notice("设备组：信箱已注册到中继 \(config.endpointDescription)（中继 \(registration.server ?? "?")）",
                             category: RemoteLog.category)
        case .client:
            peerSessions = [:]
            lastList = now
            registration.control.send(RemoteRelayMessage(type: "list"))
        }
    }

    private func connectFailed(_ line: Line, error: Error, generation: Int) {
        guard running, generation == self.generation else { return }
        let now = Date()
        let what = line == .mailbox ? "信箱注册" : "连中继"
        var reason = error.localizedDescription
        var refused = false
        if case RemoteRelayError.refused(let code) = error {
            refused = true
            switch code {
            case "full": reason = "中继已满（在线主机数或控制连接数到了上限）"
            case "hostKey": reason = "这个信箱 ID（\(mailboxID.uuidString)）在中继上绑着别的钥匙，可在中继上 uterm-relay forget 它"
            default: reason = "中继拒绝了（\(code)）"
            }
        } else if case RemoteRelayError.rejected = error {
            refused = true
        } else if case RemoteRelayError.notConfigured = error {
            refused = true
        } else if line == .mailbox, mailboxKeyCache == nil {
            refused = true
            reason = "读不到信箱钥匙：\(reason)"
        }
        var delay: TimeInterval = 0
        update(line) {
            $0.connecting = false
            if refused {
                $0.refusedBackoff = $0.refusedBackoff == 0 ? timing.refusedRetry : min($0.refusedBackoff * 2, timing.maxRefusedRetry)
                delay = $0.refusedBackoff
            } else {
                delay = $0.backoff
                $0.backoff = min($0.backoff * 2, timing.maxBackoff)
            }
            $0.retryAt = now.addingTimeInterval(delay)
        }
        // 同一个原因只记一次（网络不通时每次重连都会失败）。
        guard state(line).lastFailure != reason else { return }
        update(line) { $0.lastFailure = reason }
        let message = "设备组：中继\(what)失败：\(reason)，\(Int(delay.rounded())) 秒后再试"
        if refused {
            AppLogger.notice(message, category: RemoteLog.category)
        } else {
            AppLogger.info(message, category: RemoteLog.category)
        }
    }

    private func controlClosed(_ line: Line, instance: Int) {
        let current = state(line)
        guard current.instance == instance, current.control != nil else { return }
        let now = Date()
        var delay: TimeInterval = 0
        update(line) {
            $0.control = nil
            $0.instance += 1
            if $0.superseded {
                $0.refusedBackoff = $0.refusedBackoff == 0 ? timing.refusedRetry : min($0.refusedBackoff * 2, timing.maxRefusedRetry)
                delay = $0.refusedBackoff
            } else {
                delay = min($0.backoff, timing.maxBackoff)
                $0.backoff = min($0.backoff * 2, timing.maxBackoff)
            }
            $0.retryAt = now.addingTimeInterval(delay)
        }
        switch line {
        case .mailbox:
            for session in inbound.values { session.end(RemoteGroupRelayLinkError.closed) }
            inbound = [:]
        case .client:
            for session in outbound.values { session.end(RemoteGroupRelayLinkError.closed) }
            outbound = [:]
            peerSessions = [:]
            online = []
            listed = false
        }
        guard running else { return }
        AppLogger.info("设备组：中继\(line == .mailbox ? "信箱" : "投递")连接断开，\(Int(delay.rounded())) 秒后重连",
                       category: RemoteLog.category)
    }

    // MARK: - 收

    private func handle(_ message: RemoteRelayMessage, on line: Line, instance: Int) {
        guard running, state(line).instance == instance, let control = state(line).control else { return }
        update(line) { $0.lastHeard = Date() }
        switch (line, message.type) {
        case (_, "ping"):
            control.send(RemoteRelayMessage(type: "pong"))
        case (.mailbox, "signal"):
            handleMailboxSignal(message)
        case (.mailbox, "superseded"):
            AppLogger.notice("设备组：信箱被顶替（另一个进程用同一台设备的身份注册了信箱），过一阵再注册",
                             category: RemoteLog.category)
            update(.mailbox) { $0.superseded = true }
            control.close()
            controlClosed(.mailbox, instance: instance)
        case (.client, "hosts"):
            online = Set((message.hosts ?? []).compactMap(UUID.init(uuidString:)))
            listed = true
            refreshCandidates()
            dialDue(now: Date())
        case (.client, "signal"):
            guard let session = message.session, let box = message.box.flatMap({ Data(base64Encoded: $0) }),
                  let decoded = RemoteGroupRelayBox.decode(box), let link = outbound[session] else { return }
            link.receive(decoded)
        case (.client, "undeliverable"):
            guard let session = message.session, let link = outbound[session] else { return }
            online.remove(RemoteGroupMailbox.hostID(for: link.peer.id))
            link.end(RemoteGroupRelayLinkError.undeliverable)
        default:
            // `incoming`（有人要走中继拨号）、`pong` 等：不理。
            break
        }
    }

    private func handleMailboxSignal(_ message: RemoteRelayMessage) {
        guard let session = message.session, let box = message.box.flatMap({ Data(base64Encoded: $0) }),
              let decoded = RemoteGroupRelayBox.decode(box) else { return }
        switch decoded {
        case .hello(let hello):
            // 和它连着局域网：不回（拨号那头握手超时后退避，同步层也不会让中继顶掉局域网）。
            guard let from = message.from.flatMap(UUID.init(uuidString:)), !hasPreferredLink(from) else { return }
            // 同一个 session 上重新握手：拨号那头重拨了（只有它能往这个 session 里写）。
            if let old = inbound.removeValue(forKey: session) { old.end(RemoteGroupRelayLinkError.replaced) }
            guard inbound.values.filter({ !$0.isEstablished }).count < Self.maxInboundHandshakes else { return }
            guard let link = RemoteGroupRelaySession.accept(
                hello, from: from, session: session, local: local, identityKey: identityKey, trusted: trusted(),
                queue: queue, timing: timing.link, emit: { [weak self] box in self?.emitFromMailbox(box, session: session) })
            else {
                AppLogger.debug("设备组：信箱收到名册外（或公钥对不上）的 \(from.uuidString.prefix(8)) 拨号，不理",
                                category: RemoteLog.category)
                return
            }
            inbound[session] = link
            begin(link)
        case .sealed(let linkID, _):
            if let link = inbound[session], link.linkID == linkID {
                link.receive(decoded)
            } else if !resetsSent.contains(linkID) {
                // 信箱重连过、不认识这条链路：让拨号那头马上重拨，不用等它超时。
                resetsSent.append(linkID)
                if resetsSent.count > Self.maxResets { resetsSent.removeFirst() }
                emitFromMailbox(RemoteGroupRelayBox.reset(linkID: linkID).encoded(), session: session)
            }
        case .reply, .reset:
            break
        }
    }

    private func emitFromMailbox(_ box: Data, session: String) {
        mailbox.control?.send(RemoteRelayMessage(type: "signal", session: session, box: box.base64EncodedString()))
    }

    private func emitFromClient(_ box: Data, session: String, to peer: UUID) {
        client.control?.send(RemoteRelayMessage(type: "signal", session: session, from: local.id.uuidString,
                                                to: RemoteGroupMailbox.hostID(for: peer).uuidString,
                                                box: box.base64EncodedString()))
    }

    // MARK: - 拨

    private func refreshCandidates() {
        var grouped: [UUID: [RemoteGroupDevice]] = [:]
        for device in trusted() where device.id != local.id && device.hasValidKeys {
            grouped[device.id, default: []].append(device)
        }
        // 同一个 ID 有几条（钥匙串圈里的人能写）时新的先试，拨不通轮着换。
        candidates = grouped.mapValues { $0.sorted { $0.updatedAt > $1.updatedAt } }
        for id in peers.keys where candidates[id] == nil && active[id] == nil { peers[id] = nil }
    }

    private func dialDue(now: Date) {
        guard running, listed, client.control != nil else { return }
        for id in candidates.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entries = candidates[id], !entries.isEmpty else { continue }
            guard online.contains(RemoteGroupMailbox.hostID(for: id)) else {
                peers[id]?.onlineSince = nil
                continue
            }
            var peer = peers[id] ?? PeerState()
            if peer.onlineSince == nil { peer.onlineSince = now }
            peers[id] = peer
            guard active[id] == nil, peer.retryAt <= now,
                  !outbound.values.contains(where: { $0.peer.id == id }),
                  !inbound.values.contains(where: { $0.peer.id == id }) else { continue }
            let leads = RemoteGroupLANService.leads(local.id, over: id)
            guard leads || now.timeIntervalSince(peer.onlineSince ?? now) >= timing.fallbackDialDelay else { continue }
            // 局域网连着：不拨（同步层也不会让中继顶掉它）。
            guard !hasPreferredLink(id) else { continue }
            guard let session = peerSessions[id] ?? newSession() else { continue }
            peerSessions[id] = session
            let entry = entries[peer.attempts % entries.count]
            peers[id]?.attempts += 1
            let link = RemoteGroupRelaySession(
                dialing: entry, session: session, local: local, identityKey: identityKey, queue: queue, timing: timing.link,
                now: now, emit: { [weak self] box in self?.emitFromClient(box, session: session, to: id) })
            outbound[session] = link
            begin(link)
        }
    }

    /// 这条 `client` 连接上的一个新 session；已经用满时为 nil。
    private func newSession() -> String? {
        guard peerSessions.count < Self.maxPeers else { return nil }
        return RemoteGroupRelayBox.random(16).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func begin(_ link: RemoteGroupRelaySession) {
        link.start(onEstablished: { [weak self] link in self?.established(link) },
                   onEnded: { [weak self] link, wasEstablished, error in
                       self?.ended(link, wasEstablished: wasEstablished, error: error)
                   })
    }

    // MARK: - 握手之后

    private func established(_ link: RemoteGroupRelaySession) {
        guard running else { return link.end(RemoteGroupRelayLinkError.closed) }
        let peer = link.peer.id
        if let existing = active[peer], existing !== link {
            guard Self.prefers(link, over: existing, local: local.id, peer: peer) else {
                return link.end(RemoteGroupRelayLinkError.replaced)
            }
            active[peer] = nil
            existing.end(RemoteGroupRelayLinkError.replaced)
        }
        active[peer] = link
        peers[peer, default: PeerState()].backoff = 1
        let direction = link.role == .client ? "本机拨出" : "对方拨入"
        AppLogger.notice("设备组：和「\(link.peer.name)」的中继线路已连上（\(direction)）", category: RemoteLog.category)
        onLink(link)
    }

    private func ended(_ link: RemoteGroupRelaySession, wasEstablished: Bool, error: Error) {
        if outbound[link.session] === link { outbound[link.session] = nil }
        if inbound[link.session] === link { inbound[link.session] = nil }
        let peer = link.peer.id
        if active[peer] === link {
            active[peer] = nil
            if running {
                AppLogger.info("设备组：和「\(link.peer.name)」的中继线路断开：\(error.localizedDescription)",
                               category: RemoteLog.category)
            }
        } else if !wasEstablished, link.role == .client {
            AppLogger.debug("设备组：往「\(link.peer.name)」的信箱没拨通：\(error.localizedDescription)", category: RemoteLog.category)
        }
        guard link.role == .client, var state = peers[peer] else { return }
        let now = Date()
        // 握好手又被对端关掉的（多半是对端那边局域网还连着），也按退避来，免得每秒拨一次。
        if wasEstablished, (error as? RemoteGroupRelayLinkError) != .closedByPeer {
            state.backoff = 1
            state.retryAt = now.addingTimeInterval(1)
        } else {
            state.retryAt = now.addingTimeInterval(state.backoff)
            state.backoff = min(state.backoff * 2, timing.maxDialBackoff)
        }
        peers[peer] = state
    }

    /// 同一对设备之间留哪条：拨号的是 ID 小的那台的优先，同一方拨的留新的。两边按同一条规则挑，结果一样。
    static func prefers(_ candidate: RemoteGroupRelaySession, over existing: RemoteGroupRelaySession,
                        local: UUID, peer: UUID) -> Bool {
        let leader = RemoteGroupLANService.leads(local, over: peer) ? local : peer
        let candidateLeads = candidate.opener == leader, existingLeads = existing.opener == leader
        if candidateLeads != existingLeads { return candidateLeads }
        return true
    }
}
