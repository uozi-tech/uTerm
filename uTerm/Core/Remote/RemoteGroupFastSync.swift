import CryptoKit
import Foundation

// 设备组快通道的同步（docs/remote-device-group-design.md §7.4「同步」，落地见 §16、§17）：线路无关，局域网
// （`RemoteGroupLANConnection`）和中继信箱（`RemoteGroupRelaySession`）都只是一条 `RemoteGroupPeerLink`。
//
// 每条线路上：连上时互发 `sync`（我见过的全部内容摘要 + 墓碑摘要），对方据此只发我没有的；之后本机叠加层或钥匙串一有变化
//（50 毫秒合并一次）就把对方还没有的记录、墓碑直接推过去，此外每 30 秒再对一次 `sync`。从 A 收到的东西记成「A 有」，
// 不会原样回给 A，但会推给别的对端：合并后的名册就是要同步的全集，A、C 互相够不着、都够得着 B 时照样快。

/// 线路种类（日志里写「经局域网 / 中继收到」）。
nonisolated enum RemoteGroupLinkKind: String, Sendable {
    case localNetwork
    case relay

    var label: String {
        switch self {
        case .localNetwork: return "局域网"
        case .relay: return "中继"
        }
    }

    /// 同一台对端同时够得着几条线路时用哪条：大的优先（局域网 > 中继，像远控那样挑最快的）。
    var priority: Int {
        switch self {
        case .localNetwork: return 2
        case .relay: return 1
        }
    }
}

/// 一条已认证、已加密的对端连接：快通道的线路抽象。局域网是 `RemoteGroupLANConnection`，中继信箱是
/// `RemoteGroupRelaySession`。
///
/// 实现要保证：`peer` 是对方用钥匙串名册里 `device.<id>` 记录的远控公钥证明过身份的那台（叠加层收到的 `device` 不算）；
/// 帧按发送顺序、不重不漏地交出（重放、乱序、被改的帧不交，直接断开）；单帧至少能装 `RemoteGroupFastSync.maxPayload`。
nonisolated protocol RemoteGroupPeerLink: AnyObject, Sendable {
    /// 对端在钥匙串名册里的条目。
    var peer: RemoteGroupDevice { get }
    var kind: RemoteGroupLinkKind { get }
    /// 把收帧、断开交给同步层（只调一次）。调用之前已经收到的帧先存着，调用后按序交出。回调可以在任意线程上。
    /// 线路断了（含 `close()`）调一次 `onClose`，之后不再有 `onFrame`。
    func activate(onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void)
    /// 发一帧。断开之后调用无害。
    func send(_ frame: Data)
    func close()
}

/// 快通道上的消息。编码是带版本号的 JSON；版本不认识、类型不认识的整条忽略。
nonisolated enum RemoteGroupSyncMessage: Equatable, Sendable {
    /// 我见过的全部内容摘要（`have`，每个 32 字节首尾相接）与墓碑摘要（`dead`，`RemoteGroupTombstone.key`）。
    /// 一帧放不下时分几条发，前面的 `more` 为真。`reply`：这是对一条 `sync` 的回复，收到的一方不再回。
    case sync(have: Data, dead: Data, reply: Bool, more: Bool)
    /// 一批原始记录（钥匙串里那样的字节）。
    case records([Data])
    case tombstones([RemoteGroupTombstone])

    static let version = 1

    private struct Envelope: Codable {
        var v: Int
        var type: String
        var have: Data?
        var dead: Data?
        var reply: Bool?
        var more: Bool?
        var records: [Data]?
        var tombstones: [RemoteGroupTombstone]?
    }

    func encoded() throws -> Data {
        var envelope = Envelope(v: Self.version, type: "")
        switch self {
        case .sync(let have, let dead, let reply, let more):
            envelope.type = "sync"
            envelope.have = have
            envelope.dead = dead
            envelope.reply = reply
            envelope.more = more
        case .records(let records):
            envelope.type = "records"
            envelope.records = records
        case .tombstones(let tombstones):
            envelope.type = "tombstones"
            envelope.tombstones = tombstones
        }
        return try JSONEncoder().encode(envelope)
    }

    static func decode(_ data: Data) -> RemoteGroupSyncMessage? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.v == version else { return nil }
        switch envelope.type {
        case "sync":
            let have = envelope.have ?? Data(), dead = envelope.dead ?? Data()
            guard have.count % SHA256.byteCount == 0, dead.count % SHA256.byteCount == 0 else { return nil }
            return .sync(have: have, dead: dead, reply: envelope.reply ?? false, more: envelope.more ?? false)
        case "records":
            return .records(envelope.records ?? [])
        case "tombstones":
            return .tombstones(envelope.tombstones ?? [])
        default:
            return nil
        }
    }

    /// 把一串 32 字节的摘要切开。
    static func digests(in packed: Data) -> [Data] {
        stride(from: 0, to: packed.count, by: SHA256.byteCount).map {
            Data(packed[(packed.startIndex + $0)..<(packed.startIndex + $0 + SHA256.byteCount)])
        }
    }
}

/// 快通道的同步层。线程安全：状态都在自己的串行队列上。
nonisolated final class RemoteGroupFastSync: @unchecked Sendable {
    /// 一条消息编码后的上限。中继一帧 64 KiB 装不下 base64 之后的它，中继线路自己分片（`RemoteGroupRelayHandshake`）。
    static let maxPayload = 48 * 1024
    static let coalesceDelay: TimeInterval = 0.05
    static let syncInterval: TimeInterval = 30
    /// 一条 `sync` 里最多放几个摘要（32 字节，base64 之后约 43 字节）。
    static let digestsPerSync = 1000
    /// 一帧里一次 `sync` 累积的摘要总数上限（对端说的比这多就不信它）。
    static let maxAnnouncedDigests = 16 * 1024

    /// 别的设备送来了新东西。
    struct Received: Sendable {
        let peer: RemoteGroupDevice
        let kind: RemoteGroupLinkKind
        let ingest: RemoteGroupOverlayIngest
    }

    private final class LinkState {
        let link: any RemoteGroupPeerLink
        /// 对端有（或者见过、不要）的内容摘要。
        var peerHas = Set<Data>()
        var peerDead = Set<Data>()
        /// 分几条来的 `sync` 还没收完。
        var pendingHave = Set<Data>()
        var pendingDead = Set<Data>()
        /// 收到过对端完整的一次 `sync`：之前不主动推（不知道它有什么）。
        var synced = false

        init(link: any RemoteGroupPeerLink) {
            self.link = link
        }
    }

    let overlay: RemoteGroupOverlayStorage
    private let coalesceDelay: TimeInterval
    private let syncInterval: TimeInterval
    private let onReceive: @Sendable (Received) -> Void
    private let onLinkClosed: (@Sendable (UUID, RemoteGroupLinkKind) -> Void)?
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.group-sync")
    private var links: [UUID: LinkState] = [:]
    private var pushScheduled = false
    private var timer: DispatchSourceTimer?
    private var observer: UUID?
    private var stopped = false

    init(overlay: RemoteGroupOverlayStorage, coalesceDelay: TimeInterval = RemoteGroupFastSync.coalesceDelay,
         syncInterval: TimeInterval = RemoteGroupFastSync.syncInterval,
         onLinkClosed: (@Sendable (UUID, RemoteGroupLinkKind) -> Void)? = nil,
         onReceive: @escaping @Sendable (Received) -> Void) {
        self.overlay = overlay
        self.coalesceDelay = coalesceDelay
        self.syncInterval = syncInterval
        self.onLinkClosed = onLinkClosed
        self.onReceive = onReceive
        observer = overlay.addObserver { [weak self] _ in self?.schedulePush() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + syncInterval, repeating: syncInterval)
        timer.setEventHandler { [weak self] in self?.syncAll() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        if let observer { overlay.removeObserver(observer) }
    }

    /// 接上一条线路：马上发一次 `sync`。
    ///
    /// 同一台对端已经有线路时按种类挑（`RemoteGroupLinkKind.priority`）：已有的更好（局域网在、来的是中继）就关掉新来的；
    /// 否则换成新来的、关掉旧的。同一种线路里挑哪条由线路自己的服务先挑好（新来的就是要留的）。换线路时沿用对端「有什么」
    /// 的账，推送不中断，新线路上照常对一次 `sync`，不会把全部记录重推一遍。
    func add(_ link: any RemoteGroupPeerLink) {
        queue.async { [self] in
            guard !stopped else { return link.close() }
            let existing = links.filter { $0.value.link.peer.id == link.peer.id && $0.value.link !== link }
            if existing.values.contains(where: { $0.link.kind.priority > link.kind.priority }) {
                return link.close()
            }
            let state = LinkState(link: link)
            for (token, old) in existing {
                links[token] = nil
                old.link.close()
                state.peerHas.formUnion(old.peerHas)
                state.peerDead.formUnion(old.peerDead)
                state.synced = state.synced || old.synced
            }
            let token = UUID()
            links[token] = state
            let peer = link.peer.id, kind = link.kind, name = link.peer.name
            let replaced = existing.isEmpty ? "" : "，换下\(existing.values.map { $0.link.kind.label }.joined(separator: "、"))"
            AppLogger.notice("设备组：快通道和「\(name)」走\(kind.label)\(replaced)", category: RemoteLog.category)
            link.activate(onFrame: { [weak self] frame in
                guard let self else { return }
                self.queue.async { self.handle(frame, on: token) }
            }, onClose: { [weak self] in
                guard let self else { return }
                self.queue.async {
                    // 被新线路换下的那条：`links` 里早没有它了，对端也没断。
                    guard self.links.removeValue(forKey: token) != nil, !self.stopped else { return }
                    AppLogger.notice("设备组：快通道和「\(name)」的\(kind.label)线路断了", category: RemoteLog.category)
                    self.onLinkClosed?(peer, kind)
                }
            })
            sendSync(to: state, reply: false)
        }
    }

    /// 此刻和这台对端用的线路（没连着为 nil）。
    func linkKind(for peer: UUID) -> RemoteGroupLinkKind? {
        queue.sync { links.values.first { $0.link.peer.id == peer }?.link.kind }
    }

    /// 关掉所有线路、不再同步。
    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
            let all = links.values.map(\.link)
            links = [:]
            for link in all { link.close() }
        }
        if let observer {
            overlay.removeObserver(observer)
            self.observer = nil
        }
    }

    /// 此刻连着的对端（测试、诊断用）。
    var connectedPeers: [UUID] {
        queue.sync { links.values.map(\.link.peer.id) }
    }

    /// 此刻每台对端用的线路（测试、诊断用）。
    var linkKinds: [UUID: RemoteGroupLinkKind] {
        queue.sync { Dictionary(links.values.map { ($0.link.peer.id, $0.link.kind) }, uniquingKeysWith: { a, _ in a }) }
    }

    // MARK: - 发

    private func schedulePush() {
        queue.async { [self] in
            guard !stopped, !pushScheduled else { return }
            pushScheduled = true
            queue.asyncAfter(deadline: .now() + coalesceDelay) { [self] in
                pushScheduled = false
                pushAll()
            }
        }
    }

    private func pushAll() {
        guard !stopped, links.values.contains(where: \.synced) else { return }
        let snapshot = overlay.snapshot()
        for state in links.values where state.synced {
            push(snapshot, to: state)
        }
    }

    /// 把对端还没有的记录与墓碑推过去。
    private func push(_ snapshot: (items: [RemoteGroupOverlayItem], tombstones: [RemoteGroupTombstone]), to state: LinkState) {
        let tombstones = snapshot.tombstones.filter { !state.peerDead.contains($0.key) }
        let items = snapshot.items.filter { !state.peerHas.contains($0.digest) }
        for batch in Self.batches(tombstones, size: { $0.account.utf8.count + 120 }) {
            send(.tombstones(batch), on: state)
        }
        for batch in Self.batches(items, size: { ($0.data.count + 2) / 3 * 4 + 4 }) {
            send(.records(batch.map(\.data)), on: state)
        }
        state.peerDead.formUnion(tombstones.map(\.key))
        state.peerHas.formUnion(items.map(\.digest))
    }

    private func syncAll() {
        guard !stopped else { return }
        for state in links.values { sendSync(to: state, reply: false) }
    }

    private func sendSync(to state: LinkState, reply: Bool) {
        let have = Array(overlay.seenDigests())
        let dead = overlay.snapshot().tombstones.map(\.key)
        let all = have.map { (digest: $0, dead: false) } + dead.map { (digest: $0, dead: true) }
        var start = 0
        repeat {
            let chunk = all[start..<min(all.count, start + Self.digestsPerSync)]
            start += Self.digestsPerSync
            send(.sync(have: Data(chunk.filter { !$0.dead }.flatMap(\.digest)),
                       dead: Data(chunk.filter(\.dead).flatMap(\.digest)),
                       reply: reply, more: start < all.count), on: state)
        } while start < all.count
    }

    private func send(_ message: RemoteGroupSyncMessage, on state: LinkState) {
        guard let frame = try? message.encoded() else { return }
        state.link.send(frame)
    }

    /// 按编码后的大小切批（单条超过上限的照样单独成一批：叠加层收的每条不超过 16 KiB）。
    private static func batches<T>(_ items: [T], size: (T) -> Int) -> [[T]] {
        var batches: [[T]] = []
        var current: [T] = []
        var bytes = 64
        for item in items {
            let cost = size(item) + 4
            if !current.isEmpty, bytes + cost > maxPayload {
                batches.append(current)
                current = []
                bytes = 64
            }
            current.append(item)
            bytes += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    // MARK: - 收

    private func handle(_ frame: Data, on token: UUID) {
        guard !stopped, let state = links[token], let message = RemoteGroupSyncMessage.decode(frame) else { return }
        let link = state.link
        switch message {
        case .sync(let have, let dead, let reply, let more):
            state.pendingHave.formUnion(RemoteGroupSyncMessage.digests(in: have))
            state.pendingDead.formUnion(RemoteGroupSyncMessage.digests(in: dead))
            guard state.pendingHave.count + state.pendingDead.count <= Self.maxAnnouncedDigests else {
                AppLogger.notice("设备组：「\(link.peer.name)」报的摘要太多，断开", category: RemoteLog.category)
                links[token] = nil
                return link.close()
            }
            guard !more else { return }
            state.peerHas = state.pendingHave
            state.peerDead = state.pendingDead
            state.pendingHave = []
            state.pendingDead = []
            state.synced = true
            push(overlay.snapshot(), to: state)
            if !reply { sendSync(to: state, reply: true) }
        case .records(let records):
            let digests = records.map { Data(SHA256.hash(data: $0)) }
            // 先记「它有」再收：收下之后的那次推送不会把它们原样回给它。
            state.peerHas.formUnion(digests)
            let ingest = overlay.ingest(records: records, tombstones: [], from: link.peer.id)
            report(ingest, from: link)
        case .tombstones(let tombstones):
            state.peerDead.formUnion(tombstones.map(\.key))
            let ingest = overlay.ingest(records: [], tombstones: tombstones, from: link.peer.id)
            report(ingest, from: link)
        }
    }

    private func report(_ ingest: RemoteGroupOverlayIngest, from link: any RemoteGroupPeerLink) {
        guard !ingest.isEmpty else { return }
        Self.log(ingest, from: link.peer, kind: link.kind, now: Date())
        onReceive(Received(peer: link.peer, kind: link.kind, ingest: ingest))
    }

    /// `设备组：经局域网收到「X」的 admit，写入后 N 秒`。N 用记录里写入者的时间（含两台的钟差），和钥匙串那条日志
    /// （`RemoteDeviceGroup.noteArrivals`）并排比。一次收到很多条（刚连上补齐）时只记一行汇总。
    static func log(_ ingest: RemoteGroupOverlayIngest, from peer: RemoteGroupDevice, kind: RemoteGroupLinkKind, now: Date) {
        let records = ingest.records.compactMap { RemoteGroupRecord.decode($0.data) }
        if records.count > 6 {
            var counts: [String: Int] = [:]
            for record in records { counts[record.kind, default: 0] += 1 }
            let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: "、")
            AppLogger.notice("设备组：经\(kind.label)收到「\(peer.name)」的 \(records.count) 条记录（\(summary)）",
                             category: RemoteLog.category)
        } else {
            for record in records {
                let seconds = now.timeIntervalSince(record.writtenAt)
                let age = seconds.isFinite ? "，写入后 " + String(format: "%.1f", seconds) + " 秒" : ""
                AppLogger.notice("设备组：经\(kind.label)收到「\(peer.name)」的 \(record.kind)\(age)",
                                 category: RemoteLog.category)
            }
        }
        if !ingest.tombstones.isEmpty {
            AppLogger.notice("设备组：经\(kind.label)收到「\(peer.name)」的 \(ingest.tombstones.count) 个删除",
                             category: RemoteLog.category)
        }
    }
}
