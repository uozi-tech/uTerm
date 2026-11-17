import CryptoKit
import Foundation
import XCTest
@testable import uTerm

// 中继信箱用例共用的夹具：内存里的假中继（照 relay/PROTOCOL.md 与 relay/internal/relay/server.go 的行为）、
// 带私钥的测试设备、快的计时。

/// 内存里的假中继：`host` 注册（钥匙绑定、容量、顶替）、`client` 的 `list` / `signal` 转发、`undeliverable`、
/// 每个 `client` 连接最多 64 个 session、单帧 64 KiB 上限（超了像真中继那样断开发送方）。所有转发在一条串行队列上。
final class FakeGroupRelay: RemoteGroupRelayDialer, @unchecked Sendable {
    static let maxFrameBytes = 64 * 1024
    let queue = DispatchQueue(label: "test.fake-group-relay")
    private let lock = NSLock()
    private var bindings: [String: Data] = [:]
    private var hosts: [String: FakeRelayControl] = [:]
    private var clients: Set<ObjectIdentifier> = []
    private var sessions: [String: FakeRelayControl] = [:]
    private var maxHostsValue = 64
    private var largest = 0
    private var oversizedCount = 0
    private var registrations = 0
    private var clientOpens = 0
    private var resets = 0
    private var hellos: [String: Int] = [:]
    private var silentRejections = 0
    private var rejectsEverything = false

    var maxHosts: Int {
        get { lock.withLock { maxHostsValue } }
        set { lock.withLock { maxHostsValue = newValue } }
    }

    /// 在线的主机 ID。
    var onlineHosts: Set<String> { lock.withLock { Set(hosts.keys) } }
    var clientCount: Int { lock.withLock { clients.count } }
    /// 转发过的最大一帧（编码后的 JSON 字节数）、超限被断开的次数。
    var largestFrame: Int { lock.withLock { largest } }
    var oversized: Int { lock.withLock { oversizedCount } }
    /// 收到过几次 `host` 注册（含被拒的）。
    var registrationAttempts: Int { lock.withLock { registrations } }
    /// 信箱回给拨号方的 reset 有几个（看中继上过的 `box`）。
    var resetCount: Int { lock.withLock { resets } }
    /// 开过几次 `client` 连接（含被拒的）。
    var clientAttempts: Int { lock.withLock { clientOpens } }
    /// `from` 往信箱 `to` 发过几个 hello（= 拨过几次）。
    func helloCount(from: UUID, to mailbox: UUID) -> Int {
        lock.withLock { hellos["\(from.uuidString)>\(mailbox.uuidString)", default: 0] }
    }
    var totalHellos: Int { lock.withLock { hellos.values.reduce(0, +) } }

    /// 接下来几次连接（`host` 或 `client`）在认证前一言不发就断开：真实连接上报成 `RemoteRelayError.rejected`。
    /// 认证不过是这样，刚睡醒、网络没好也是这样。
    func rejectSilently(next count: Int) { lock.withLock { silentRejections = count } }
    /// 之后的连接全部这样断开（配置从来就不对）。
    func rejectSilentlyForever() { lock.withLock { rejectsEverything = true } }

    private func takeRejection() -> Bool {
        lock.withLock {
            if rejectsEverything { return true }
            guard silentRejections > 0 else { return false }
            silentRejections -= 1
            return true
        }
    }

    func registerMailbox(_ mailbox: UUID, hostKey: P256.Signing.PrivateKey,
                         config: RemoteRelayConfig) async throws -> RemoteGroupRelayRegistration {
        let id = mailbox.uuidString, key = hostKey.publicKey.derRepresentation
        let control = FakeRelayControl(relay: self, hostID: id)
        lock.withLock { registrations += 1 }
        if takeRejection() { throw RemoteRelayError.rejected }
        let previous: FakeRelayControl? = try lock.withLock {
            if let bound = bindings[id], bound != key { throw RemoteRelayError.refused("hostKey") }
            if hosts[id] == nil, hosts.count >= maxHostsValue { throw RemoteRelayError.refused("full") }
            bindings[id] = key
            defer { hosts[id] = control }
            return hosts[id]
        }
        if let previous {
            queue.async {
                previous.deliver(RemoteRelayMessage(type: "superseded"))
                previous.serverClose()
            }
        }
        return RemoteGroupRelayRegistration(control: control, server: "fake")
    }

    func openClient(config: RemoteRelayConfig) async throws -> RemoteGroupRelayRegistration {
        lock.withLock { clientOpens += 1 }
        if takeRejection() { throw RemoteRelayError.rejected }
        let control = FakeRelayControl(relay: self, hostID: nil)
        _ = lock.withLock { clients.insert(ObjectIdentifier(control)) }
        return RemoteGroupRelayRegistration(control: control, server: "fake")
    }

    /// 测试用：中继这头断开一台主机（那台设备会自己重连）。
    func kick(host: UUID) {
        let control = lock.withLock { hosts[host.uuidString] }
        queue.async { control?.serverClose() }
    }

    // MARK: - 转发（在 queue 上）

    fileprivate func received(_ message: RemoteRelayMessage, from control: FakeRelayControl) {
        let size = (try? JSONEncoder().encode(message).count) ?? 0
        lock.withLock { largest = max(largest, size) }
        guard size <= Self.maxFrameBytes else {
            lock.withLock { oversizedCount += 1 }
            return control.serverClose()
        }
        if message.type == "ping" { return control.deliver(RemoteRelayMessage(type: "pong")) }
        if let hostID = control.hostID {
            guard message.type == "signal", let session = message.session else { return }
            if let box = message.box.flatMap({ Data(base64Encoded: $0) }), case .reset = RemoteGroupRelayBox.decode(box) {
                lock.withLock { resets += 1 }
            }
            let client: FakeRelayControl? = lock.withLock { hosts[hostID] === control ? sessions[session] : nil }
            client?.deliver(RemoteRelayMessage(type: "signal", session: session, box: message.box))
            return
        }
        switch message.type {
        case "list":
            var reply = RemoteRelayMessage(type: "hosts")
            reply.hosts = lock.withLock { Array(hosts.keys) }
            control.deliver(reply)
        case "signal":
            guard let session = message.session, !session.isEmpty else { return control.serverClose() }
            let host: FakeRelayControl?? = lock.withLock {
                if let owner = sessions[session], owner !== control { return .none }
                if sessions[session] == nil, control.sessions.count >= 64 { return .none }
                sessions[session] = control
                control.sessions.insert(session)
                return .some(message.to.flatMap { hosts[$0] })
            }
            guard let host else { return }
            if let box = message.box.flatMap({ Data(base64Encoded: $0) }), case .hello = RemoteGroupRelayBox.decode(box),
               let from = message.from, let to = message.to {
                lock.withLock { hellos["\(from)>\(to)", default: 0] += 1 }
            }
            if let host {
                host.deliver(RemoteRelayMessage(type: "signal", session: session, from: message.from, box: message.box))
            } else {
                control.deliver(RemoteRelayMessage(type: "undeliverable", session: session))
            }
        default:
            break
        }
    }

    fileprivate func disconnected(_ control: FakeRelayControl) {
        lock.withLock {
            if let hostID = control.hostID, hosts[hostID] === control { hosts[hostID] = nil }
            clients.remove(ObjectIdentifier(control))
            for session in control.sessions where sessions[session] === control { sessions[session] = nil }
        }
    }
}

/// 假中继上的一条控制连接。
final class FakeRelayControl: RemoteGroupRelayControl, @unchecked Sendable {
    let hostID: String?
    /// 这条 `client` 连接开过的 session（只在假中继的锁里碰）。
    fileprivate var sessions: Set<String> = []
    private weak var relay: FakeGroupRelay?
    private let lock = NSLock()
    private var onMessage: (@Sendable (RemoteRelayMessage) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var pending: [RemoteRelayMessage] = []
    private var closed = false

    fileprivate init(relay: FakeGroupRelay, hostID: String?) {
        self.relay = relay
        self.hostID = hostID
    }

    func start(onMessage: @escaping @Sendable (RemoteRelayMessage) -> Void, onClose: @escaping @Sendable () -> Void) {
        let (frames, isClosed): ([RemoteRelayMessage], Bool) = lock.withLock {
            self.onMessage = onMessage
            self.onClose = onClose
            defer { pending = [] }
            return (pending, closed)
        }
        if isClosed { return onClose() }
        for frame in frames { onMessage(frame) }
    }

    func send(_ message: RemoteRelayMessage) {
        guard let relay, !lock.withLock({ closed }) else { return }
        relay.queue.async { [self] in
            guard !lock.withLock({ closed }) else { return }
            relay.received(message, from: self)
        }
    }

    func close() {
        guard let relay else { return }
        // 排在已经交给 send 的后面：先发完再断。
        relay.queue.async { [self] in serverClose() }
    }

    /// 中继发给这条连接（在中继的队列上调）。
    fileprivate func deliver(_ message: RemoteRelayMessage) {
        let handler: (@Sendable (RemoteRelayMessage) -> Void)? = lock.withLock {
            guard !closed else { return nil }
            if onMessage == nil { pending.append(message) }
            return onMessage
        }
        handler?(message)
    }

    /// 断开（中继这头）。
    fileprivate func serverClose() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer { onClose = nil; onMessage = nil }
            return onClose
        }
        relay?.disconnected(self)
        handler?()
    }
}

/// 一份可以改的「默认中继配置」。
final class RelayConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RemoteRelayConfig?
    init(_ value: RemoteRelayConfig?) { self.value = value }
    var config: RemoteRelayConfig? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

enum RelayFixtures {
    /// 一份能注册主机的配置（假中继不看它的内容；真实中继的用例自己读环境变量）。
    static func memberConfig() -> RemoteRelayConfig {
        RemoteRelayConfig(name: "测试", host: "127.0.0.1", port: 47399, relayID: "TEST-RELAY",
                          key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString())
    }

    /// 快的计时：每拍 50 毫秒，几秒内就能看到重连、超时、补拨。
    static func fastTiming(fallback: TimeInterval = 0.3, idle: TimeInterval = 2) -> RemoteGroupRelayService.Timing {
        var timing = RemoteGroupRelayService.Timing()
        timing.tick = 0.05
        timing.listInterval = 0.3
        timing.configInterval = 0.2
        timing.pingInterval = 1
        timing.pongTimeout = 1
        timing.fallbackDialDelay = fallback
        timing.maxBackoff = 0.3
        timing.maxDialBackoff = 0.3
        timing.minDialInterval = 0.1
        timing.stableAfter = 1
        timing.raceWindow = 0.5
        timing.refusedRetry = 30
        timing.maxRefusedRetry = 30
        timing.link = RemoteGroupRelaySession.Timing(handshake: 2, ping: 0.4, idle: idle)
        return timing
    }

    static func options(_ relay: any RemoteGroupRelayDialer, config: RelayConfigBox,
                        timing: RemoteGroupRelayService.Timing = fastTiming(),
                        mailboxKey: P256.Signing.PrivateKey = .init()) -> RemoteGroupRelayService.Options {
        RemoteGroupRelayService.Options(config: { config.config }, mailboxKey: { mailboxKey }, dialer: relay, timing: timing)
    }
}

/// 一台测试设备：远控私钥、自己的「钥匙串」、叠加层、快通道（局域网服务建了但不启动；局域网用内存线路直接接进同步层）。
final class RelayNode: @unchecked Sendable {
    let identity: Curve25519.KeyAgreement.PrivateKey
    let device: RemoteGroupDevice
    let keychain: LaggingKeychain
    let overlay: RemoteGroupOverlayStorage
    let channel: RemoteGroupFastChannel
    let mailboxKey: P256.Signing.PrivateKey

    init(_ name: String, relay: (any RemoteGroupRelayDialer)?, config: RelayConfigBox? = nil,
         timing: RemoteGroupRelayService.Timing = RelayFixtures.fastTiming(), syncInterval: TimeInterval = 0.5) {
        let identity = Curve25519.KeyAgreement.PrivateKey(), mailboxKey = P256.Signing.PrivateKey()
        let device = RemoteGroupDevice(id: UUID(), name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                       publicKey: identity.publicKey.rawRepresentation,
                                       signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                                       updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let keychain = LaggingKeychain()
        let overlay = RemoteGroupOverlayStorage(base: keychain)
        let options = relay.map {
            RelayFixtures.options($0, config: config ?? RelayConfigBox(RelayFixtures.memberConfig()), timing: timing,
                                  mailboxKey: mailboxKey)
        }
        self.identity = identity
        self.keychain = keychain
        self.mailboxKey = mailboxKey
        self.device = device
        self.overlay = overlay
        channel = RemoteGroupFastChannel(local: device, identityKey: identity, overlay: overlay, advertises: false,
                                         browses: false, relay: options, syncCoalesceDelay: 0.005, syncInterval: syncInterval) { _ in }
    }

    var id: UUID { device.id }
    var mailboxID: UUID { RemoteGroupMailbox.hostID(for: device.id) }
    var relay: RemoteGroupRelayService { channel.relay! }
    var accounts: Set<String> { Set(overlay.snapshot().items.map(\.account)) }
    var digests: Set<Data> { Set(overlay.snapshot().items.map(\.digest)) }
    var linkKinds: [UUID: RemoteGroupLinkKind] { channel.sync.linkKinds }

    func save(_ record: RemoteGroupRecord) throws {
        try overlay.save(record.encoded(), account: record.account)
    }

    /// 每台设备首次启动就写了自己的 `device`，钥匙串早同步到了：只有这些记录大家都有。
    static func registerEverywhere(_ nodes: [RelayNode]) throws {
        for node in nodes {
            for other in nodes { try other.keychain.put(.device(node.device)) }
        }
    }

    /// 只开中继这条（局域网服务不起：要局域网就用 `connectLAN`）。
    func startRelay() {
        channel.relay?.start()
    }

    /// 一条内存里的「局域网」线路，直接交给两边的同步层。
    @discardableResult
    static func connectLAN(_ a: RelayNode, _ b: RelayNode) -> (atA: MemoryGroupLink, atB: MemoryGroupLink) {
        let pair = MemoryGroupLink.pair(a.device, b.device, kind: .localNetwork)
        a.channel.sync.add(pair.atA)
        b.channel.sync.add(pair.atB)
        return pair
    }
}

extension XCTestCase {
    func relayNode(_ name: String, relay: (any RemoteGroupRelayDialer)?, config: RelayConfigBox? = nil,
                   timing: RemoteGroupRelayService.Timing = RelayFixtures.fastTiming(),
                   syncInterval: TimeInterval = 0.5) -> RelayNode {
        let node = RelayNode(name, relay: relay, config: config, timing: timing, syncInterval: syncInterval)
        let channel = node.channel
        addTeardownBlock { channel.stop() }
        return node
    }
}
