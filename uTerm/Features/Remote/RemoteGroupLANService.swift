import CryptoKit
import Foundation
@preconcurrency import Network

/// 快通道的局域网一侧（docs/remote-device-group-design.md §7.4，落地见 §16）：Bonjour `_uterm-group._tcp`
///（TXT 带本机设备 ID），每台设备既听又找。
///
/// - 两台互相发现时由设备 ID 小的一方发起；大的一方发现对方 5 秒后还没连上才自己发起（单向发现时也连得上）。
///   两台同时连出了两条时，两边按同一条规则留一条：发起方是 ID 小的那条，同一方发起的留新的。
/// - 只连钥匙串名册里有 `device.<id>` 的设备（`RemoteGroupLANConnection` 握手时再核一遍公钥）；对端的记录还没到时
///   按退避重试（1 秒起、翻倍、最多 30 秒），记录到了之后最多 30 秒补连上。
/// - 握好手的连接交给 `onLink`（同步层）。
///
/// 服务类型必须写进两端 Info.plist 的 `NSBonjourServices`。状态都在自己的队列上。
nonisolated final class RemoteGroupLANService: @unchecked Sendable {
    static let serviceType = "_uterm-group._tcp"
    static let deviceIDKey = "id"
    static let fallbackDialDelay: TimeInterval = 5
    static let maxBackoff: TimeInterval = 30
    static let maxHandshaking = 8

    private struct Peer {
        var endpoint: NWEndpoint
        var discoveredAt: Date
        var retryAt: Date
        var backoff: TimeInterval = 1
    }

    let local: RemoteGroupDevice
    private let identityKey: Curve25519.KeyAgreement.PrivateKey
    private let trusted: @Sendable () -> [RemoteGroupDevice]
    private let advertises: Bool
    private let browses: Bool
    private let onLink: @Sendable (any RemoteGroupPeerLink) -> Void
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.group-lan-service")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [UUID: Peer] = [:]
    private var handshaking: [ObjectIdentifier: RemoteGroupLANConnection] = [:]
    private var dialing: Set<UUID> = []
    private var active: [UUID: RemoteGroupLANConnection] = [:]
    /// 每条留下的连接一个令牌：断开的回调按它认是不是还是那一条。
    private var activeTokens: [UUID: UUID] = [:]
    private var timer: DispatchSourceTimer?
    private var running = false
    private var listenerPort: UInt16?

    init(local: RemoteGroupDevice, identityKey: Curve25519.KeyAgreement.PrivateKey,
         trusted: @escaping @Sendable () -> [RemoteGroupDevice], advertises: Bool = true, browses: Bool = true,
         onLink: @escaping @Sendable (any RemoteGroupPeerLink) -> Void) {
        self.local = local
        self.identityKey = identityKey
        self.trusted = trusted
        self.advertises = advertises
        self.browses = browses
        self.onLink = onLink
    }

    /// 监听的端口（测试直接连它）。还没监听好时为 nil。
    var port: UInt16? { queue.sync { listenerPort } }

    /// 已握好手的对端（测试、诊断用）。
    var connectedPeers: [UUID] { queue.sync { Array(active.keys) } }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            startListener()
            if browses { startBrowser() }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.dialDue() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            listener?.cancel()
            listener = nil
            listenerPort = nil
            browser?.cancel()
            browser = nil
            peers = [:]
            dialing = []
            let all = Array(handshaking.values) + Array(active.values)
            handshaking = [:]
            active = [:]
            activeTokens = [:]
            for connection in all { connection.close() }
        }
    }

    /// 直接连一个端点（测试用；Bonjour 发现的也走这里）。
    func connect(to endpoint: NWEndpoint, peer: UUID) {
        queue.async { [self] in dial(endpoint, peer: peer) }
    }

    // MARK: - 监听

    private func startListener() {
        do {
            let listener = try NWListener(using: RemoteLink.parameters(), on: .any)
            if advertises {
                let txt = NWTXTRecord([Self.deviceIDKey: local.id.uuidString])
                listener.service = NWListener.Service(name: local.id.uuidString, type: Self.serviceType, txtRecord: txt)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listenerPort = self.listener?.port?.rawValue
                case .failed(let error):
                    AppLogger.notice("设备组：快通道监听失败：\(error.localizedDescription)", category: RemoteLog.category)
                    self.listener?.cancel()
                    self.listener = nil
                    self.listenerPort = nil
                    // 过一会儿再试（本地网络权限刚授予、网卡刚起来）。
                    self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, self.running, self.listener == nil else { return }
                        self.startListener()
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            AppLogger.notice("设备组：快通道没能监听：\(error.localizedDescription)", category: RemoteLog.category)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard running, handshaking.count < Self.maxHandshaking else { return connection.cancel() }
        handshake(RemoteGroupLANConnection(connection: connection, role: .responder, local: local,
                                           identityKey: identityKey, trusted: trusted), peer: nil)
    }

    // MARK: - 发现与发起

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, case .failed = state else { return }
            self.browser?.cancel()
            self.browser = nil
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.running, self.browser == nil else { return }
                self.startBrowser()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var seen: [UUID: NWEndpoint] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let raw = txt[Self.deviceIDKey],
                  let id = UUID(uuidString: raw), id != local.id else { continue }
            seen[id] = result.endpoint
        }
        let now = Date()
        for (id, endpoint) in seen {
            if var peer = peers[id] {
                if peer.endpoint != endpoint {
                    peer.endpoint = endpoint
                    peer.retryAt = now
                    peer.backoff = 1
                }
                peers[id] = peer
            } else {
                peers[id] = Peer(endpoint: endpoint, discoveredAt: now, retryAt: now)
            }
        }
        for id in peers.keys where seen[id] == nil { peers[id] = nil }
        dialDue()
    }

    /// 每秒一次：该连没连上的发起。
    private func dialDue() {
        guard running, !peers.isEmpty else { return }
        let now = Date()
        let known = Set(trusted().map(\.id))
        for (id, peer) in peers where active[id] == nil && !dialing.contains(id) && peer.retryAt <= now {
            // 名册里还没有它：不去碰（等它的 `device` 记录同步过来）。
            guard known.contains(id) else { continue }
            let leads = Self.leads(local.id, over: id)
            guard leads || now.timeIntervalSince(peer.discoveredAt) >= Self.fallbackDialDelay else { continue }
            dial(peer.endpoint, peer: id)
        }
    }

    private func dial(_ endpoint: NWEndpoint, peer: UUID) {
        guard running, active[peer] == nil, !dialing.contains(peer) else { return }
        dialing.insert(peer)
        let connection = NWConnection(to: endpoint, using: RemoteLink.parameters())
        handshake(RemoteGroupLANConnection(connection: connection, role: .initiator(expected: peer), local: local,
                                           identityKey: identityKey, trusted: trusted), peer: peer)
    }

    /// 两台里由谁发起：设备 ID 的字符串小的那台。
    static func leads(_ a: UUID, over b: UUID) -> Bool {
        a.uuidString < b.uuidString
    }

    // MARK: - 握手之后

    private func handshake(_ connection: RemoteGroupLANConnection, peer dialed: UUID?) {
        let id = ObjectIdentifier(connection)
        handshaking[id] = connection
        connection.start(onEstablished: { [weak self] connection in
            guard let self else { return connection.close() }
            self.queue.async { self.established(connection, dialed: dialed) }
        }, onFailed: { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.handshaking[id] = nil
                if let dialed {
                    self.dialing.remove(dialed)
                    self.backOff(dialed)
                    AppLogger.debug("设备组：快通道没连上 \(dialed.uuidString.prefix(8))：\(error.localizedDescription)",
                                    category: RemoteLog.category)
                }
            }
        })
    }

    private func established(_ connection: RemoteGroupLANConnection, dialed: UUID?) {
        handshaking[ObjectIdentifier(connection)] = nil
        if let dialed { dialing.remove(dialed) }
        guard running else { return connection.close() }
        let peer = connection.peer.id
        if let existing = active[peer] {
            guard Self.prefers(connection, over: existing, local: local.id, peer: peer) else { return connection.close() }
            existing.close()
        }
        active[peer] = connection
        let token = UUID()
        activeTokens[peer] = token
        if var known = peers[peer] {
            known.backoff = 1
            peers[peer] = known
        }
        let wrapper = ClosingLink(connection: connection) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.activeTokens[peer] == token else { return }
                self.active[peer] = nil
                self.activeTokens[peer] = nil
                self.backOff(peer, initial: true)
            }
        }
        onLink(wrapper)
    }

    /// 同一对设备之间留哪条：发起方是 ID 小的那台的优先，同一方发起的留新的。两边按同一条规则挑，结果一样。
    private static func prefers(_ candidate: RemoteGroupLANConnection, over existing: RemoteGroupLANConnection,
                                local: UUID, peer: UUID) -> Bool {
        let leader = leads(local, over: peer) ? local : peer
        let candidateLeads = candidate.initiatorID == leader, existingLeads = existing.initiatorID == leader
        if candidateLeads != existingLeads { return candidateLeads }
        return true
    }

    private func backOff(_ peer: UUID, initial: Bool = false) {
        guard var known = peers[peer] else { return }
        known.backoff = initial ? 1 : min(known.backoff * 2, Self.maxBackoff)
        known.retryAt = Date().addingTimeInterval(known.backoff)
        peers[peer] = known
    }
}

/// 交给同步层的连接：断开时也告诉局域网服务（腾出位置、准备重连）。
nonisolated private final class ClosingLink: RemoteGroupPeerLink, @unchecked Sendable {
    private let connection: RemoteGroupLANConnection
    private let onClosed: @Sendable () -> Void

    init(connection: RemoteGroupLANConnection, onClosed: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.onClosed = onClosed
    }

    var peer: RemoteGroupDevice { connection.peer }
    var kind: RemoteGroupLinkKind { connection.kind }

    func activate(onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let onClosed = onClosed
        connection.activate(onFrame: onFrame, onClose: {
            onClosed()
            onClose()
        })
    }

    func send(_ frame: Data) { connection.send(frame) }
    func close() { connection.close() }
}
