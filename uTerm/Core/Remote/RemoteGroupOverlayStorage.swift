import CryptoKit
import Foundation

// 设备组名册的叠加层（docs/remote-device-group-design.md §7.4「叠加层」，落地见 §16）。
//
// 名册照旧写 iCloud 钥匙串，同时经快通道（`RemoteGroupFastSync`）直接送到别的设备；别的设备收到的记录先放在这里，
// 上层（`RemoteGroupRoster` → `RemoteDeviceGroup`）读到的是「钥匙串 ∪ 快通道收到的」。钥匙串仍是唯一落盘的地方：
// 叠加层、墓碑都只在内存，App 重开就没了，那时钥匙串早该到了。
//
// 合并按 account（以 `RemoteGroupRecord.account` 为准，钥匙串的 `loadAll` 拿不到 account）：
// - 同一 account 两边内容不同时取「后到的」：先比记录里写入者自己的时间（同一个 account 永远是同一台设备写的，
//   它自己的钟是单调的），比不出来再比本机第一次见到这份内容的时刻；
// - 钥匙串的内容追上叠加层（一样了），叠加层那条丢掉；钥匙串一直和叠加层不一样超过 10 分钟，以钥匙串为准；
// - 墓碑（account + 内容摘要）命中的，两边都不返回，同一 account 以后的新内容不受影响。

/// 叠加层里的一条：同步层拿它比对、发送。
nonisolated struct RemoteGroupOverlayItem: Equatable, Sendable {
    var account: String
    /// 原始字节的 SHA-256。
    var digest: Data
    var data: Data
}

/// 一次删除留下的墓碑：只藏这一份内容，同一 account 的新内容照常。
nonisolated struct RemoteGroupTombstone: Codable, Hashable, Sendable {
    var account: String
    var digest: Data
    /// 删除那台设备的钟（毫秒）。墓碑在这之后 10 分钟作废：带着它转手的设备不会把墓碑一直续下去。
    var deletedAt: RemoteGroupTime

    /// 同一份内容（不看删除时间）。
    var key: Data { Self.key(account: account, digest: digest) }

    static func key(account: String, digest: Data) -> Data {
        Data(SHA256.hash(data: Data(account.utf8) + Data([0]) + digest))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// `ingest` 实际收下的东西。
nonisolated struct RemoteGroupOverlayIngest: Sendable {
    var records: [RemoteGroupOverlayItem] = []
    var tombstones: [RemoteGroupTombstone] = []

    var isEmpty: Bool { records.isEmpty && tombstones.isEmpty }
}

extension RemoteGroupRecord {
    /// 写入者造这条记录的时刻（写入者自己的钟）。叠加层用它比先后，日志用它算「写入后 N 秒」。
    nonisolated var writtenAt: Date {
        switch self {
        case .device(let device): return device.updatedAt
        case .join(let join): return join.createdAt
        case .answer(let answer): return answer.createdAt
        case .done(let done): return done.createdAt
        case .admit(let admit): return admit.signedAt.date
        case .remove(let remove): return remove.removedAt.date
        case .host(let host): return host.signedAt.date
        case .grant(let grant): return grant.signedAt.date
        }
    }

    /// 日志里的种类名（与 account 的前缀相同）。
    nonisolated var kind: String {
        switch self {
        case .device: return "device"
        case .join: return "join"
        case .answer: return "answer"
        case .done: return "done"
        case .admit: return "admit"
        case .remove: return "remove"
        case .host: return "host"
        case .grant: return "grant"
        }
    }
}

/// 包着钥匙串那份名册存储的叠加层。线程安全：内部一把锁，回调在锁外发。
nonisolated final class RemoteGroupOverlayStorage: RemoteSyncedStorage, @unchecked Sendable {
    /// 什么变了：同步层每种都要转发，上层只关心别的设备送来的（`received`）。
    enum Change: Sendable {
        /// 本机写了、删了。
        case local
        /// 快通道送来的（`ingest` 收下了东西）。
        case received
        /// 读钥匙串时发现它的内容变了。
        case base
    }

    static let maxItems = 512
    static let maxItemBytes = 16 * 1024
    static let tombstoneLifetime: TimeInterval = 10 * 60
    /// 叠加层和钥匙串对同一 account 一直不一样，这么久之后以钥匙串为准（写入者的钟往回拨过、钥匙串里的才是新的）。
    static let disagreementLifetime: TimeInterval = 10 * 60
    /// 见过的内容记多久（判断「后到的」、不重复收已经被换掉的旧内容）。还在用的一直记着。
    static let seenLifetime: TimeInterval = 10 * 60
    static let maxSeen = 4096

    private struct Entry {
        var account: String
        var data: Data
        var digest: Data
        var writtenAt: Date
        var arrivedAt: Date
        /// 本机写的（超上限时最后才丢）。
        var isLocal: Bool
    }

    /// 解过的内容：钥匙串每读一次都要解，签名验一遍不便宜。
    private struct Known {
        /// nil = 解不开（垃圾、版本不认识）。
        var record: Meta?
        var firstSeen: Date
        /// 经快通道收下的时刻：钥匙串后来也送到这一份时记一行「晚了多少」，真机上直接比两条路。
        var fastArrival: Date?
    }

    private struct Meta {
        var account: String
        var writtenAt: Date
        var kind: String
        var device: RemoteGroupDevice?
    }

    private struct BaseItem {
        var data: Data
        var digest: Data
        var meta: Meta
        var firstSeen: Date
    }

    let base: any RemoteSyncedStorage
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var tombstones: [Data: RemoteGroupTombstone] = [:]
    /// 本机删了又写回去的内容（同一 account、同一摘要）：别的设备转回来的旧墓碑不再理会。
    private var resurrected: [Data: Date] = [:]
    private var known: [Data: Known] = [:]
    /// 叠加层赢过钥匙串的 account，从哪一刻起（见 `disagreementLifetime`）。
    private var disagreeSince: [String: Date] = [:]
    private var lastBaseDigests: Set<Data>?
    private var observers: [UUID: @Sendable (Change) -> Void] = [:]

    init(base: any RemoteSyncedStorage, now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.now = now
    }

    /// App 里唯一的一份（`RemoteDeviceGroup.live` 的名册与快通道共用）。测试宿主里底下是内存的
    /// （`RemoteLocalState.syncedStorage`）。
    static let live = RemoteGroupOverlayStorage(base: RemoteLocalState.syncedStorage(service: RemoteGroupRoster.service))

    // MARK: - 变化

    /// 有变化时在任意线程上调 `handler`（锁外）。返回的令牌交给 `removeObserver`。
    @discardableResult
    func addObserver(_ handler: @escaping @Sendable (Change) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = handler }
        return token
    }

    func removeObserver(_ token: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }

    private func notify(_ change: Change) {
        let handlers = lock.withLock { Array(observers.values) }
        for handler in handlers { handler(change) }
    }

    // MARK: - RemoteSyncedStorage

    func loadAll() -> [Data] {
        merged().items.map(\.data)
    }

    func save(_ data: Data, account: String) throws {
        try base.save(data, account: account)
        let time = now()
        let digest = digest(data)
        let accepted: Bool = lock.withLock {
            // 太大的、解不开的只进钥匙串，不经快通道。
            guard data.count <= Self.maxItemBytes, let meta = meta(for: data, digest: digest, at: time) else {
                return false
            }
            let key = RemoteGroupTombstone.key(account: meta.account, digest: digest)
            if tombstones.removeValue(forKey: key) != nil { resurrected[key] = time }
            entries[meta.account] = Entry(account: meta.account, data: data, digest: digest, writtenAt: meta.writtenAt,
                                          arrivedAt: time, isLocal: true)
            disagreeSince[meta.account] = nil
            evictIfNeeded()
            return true
        }
        if accepted { notify(.local) }
    }

    func delete(account: String) throws {
        // 先记下这个 account 此刻的内容：钥匙串里的删除还在别的设备的路上时，墓碑先在那边把它藏起来。
        let before = base.loadAll()
        try base.delete(account: account)
        let time = now()
        let changed: Bool = lock.withLock {
            var doomed = decodeBase(before, at: time).filter { $0.meta.account == account }.map(\.digest)
            if let entry = entries.removeValue(forKey: account) { doomed.append(entry.digest) }
            var changed = false
            for digest in doomed {
                let tombstone = RemoteGroupTombstone(account: account, digest: digest, deletedAt: RemoteGroupTime(time))
                if tombstones.updateValue(tombstone, forKey: tombstone.key) == nil { changed = true }
                resurrected[tombstone.key] = nil
            }
            disagreeSince[account] = nil
            trimTombstones()
            return changed
        }
        if changed { notify(.local) }
    }

    func deleteAll() throws {
        try base.deleteAll()
        lock.withLock {
            entries.removeAll()
            disagreeSince.removeAll()
        }
        notify(.local)
    }

    // MARK: - 给同步层

    /// 此刻上层读得到的全集，与活着的墓碑。
    func snapshot() -> (items: [RemoteGroupOverlayItem], tombstones: [RemoteGroupTombstone]) {
        merged()
    }

    /// 本机见过的全部内容摘要：此刻的全集，加上 10 分钟内见过、已被换掉或被拒的。同步时告诉对端「这些不用再发」。
    func seenDigests() -> Set<Data> {
        _ = merged()
        return lock.withLock { Set(known.keys) }
    }

    /// 钥匙串名册里（不算叠加层）的设备条目：快通道只认这些设备。
    func baseDevices() -> [RemoteGroupDevice] {
        let time = now()
        let all = base.loadAll()
        return lock.withLock {
            all.compactMap { data in meta(for: data, digest: digest(data), at: time)?.device }
        }
    }

    /// 收下对端送来的记录与墓碑，返回实际新增的。`peer` 只用来记日志、排查。
    @discardableResult
    func ingest(records: [Data], tombstones incoming: [RemoteGroupTombstone], from peer: UUID?) -> RemoteGroupOverlayIngest {
        let time = now()
        let baseData = base.loadAll()
        var result = RemoteGroupOverlayIngest()
        lock.withLock {
            let baseItems = decodeBase(baseData, at: time)
            for var tombstone in incoming {
                guard tombstone.digest.count == SHA256.byteCount, !tombstone.account.isEmpty,
                      tombstone.account.utf8.count <= 256 else { continue }
                let key = tombstone.key
                if let since = resurrected[key], time.timeIntervalSince(since) < Self.tombstoneLifetime { continue }
                guard tombstones[key] == nil, !isExpired(tombstone, at: time) else { continue }
                // 删除时间写在将来的，最多也只留 10 分钟。
                if tombstone.deletedAt.date > time { tombstone.deletedAt = RemoteGroupTime(time) }
                tombstones[key] = tombstone
                if entries[tombstone.account]?.digest == tombstone.digest { entries[tombstone.account] = nil }
                result.tombstones.append(tombstone)
            }
            trimTombstones()
            for data in records {
                guard data.count <= Self.maxItemBytes else { continue }
                let digest = digest(data)
                let seenBefore = known[digest] != nil
                guard let meta = meta(for: data, digest: digest, at: time) else { continue }
                let key = RemoteGroupTombstone.key(account: meta.account, digest: digest)
                guard tombstones[key] == nil else { continue }
                // 已经有了，或者见过（被换掉了、被拒过）：不是新东西。
                if entries[meta.account]?.digest == digest || seenBefore { continue }
                let rivals = baseItems.filter { $0.meta.account == meta.account && tombstones[RemoteGroupTombstone.key(account: $0.meta.account, digest: $0.digest)] == nil }
                if rivals.contains(where: { $0.digest == digest }) { continue }
                if let current = entries[meta.account], !Self.isNewer(meta.writtenAt, time, than: current.writtenAt, current.arrivedAt) {
                    continue
                }
                if let newest = rivals.max(by: { Self.isNewer($1.meta.writtenAt, $1.firstSeen, than: $0.meta.writtenAt, $0.firstSeen) }),
                   !Self.isNewer(meta.writtenAt, time, than: newest.meta.writtenAt, newest.firstSeen) {
                    continue
                }
                entries[meta.account] = Entry(account: meta.account, data: data, digest: digest, writtenAt: meta.writtenAt,
                                              arrivedAt: time, isLocal: false)
                disagreeSince[meta.account] = nil
                known[digest]?.fastArrival = time
                result.records.append(RemoteGroupOverlayItem(account: meta.account, digest: digest, data: data))
            }
            evictIfNeeded()
        }
        if !result.isEmpty { notify(.received) }
        return result
    }

    // MARK: - 合并

    private func merged() -> (items: [RemoteGroupOverlayItem], tombstones: [RemoteGroupTombstone]) {
        let time = now()
        let baseData = base.loadAll()
        var baseChanged = false
        var lateKeychain: [(kind: String, seconds: TimeInterval)] = []
        let output: (items: [RemoteGroupOverlayItem], tombstones: [RemoteGroupTombstone]) = lock.withLock {
            let baseItems = decodeBase(baseData, at: time)
            let digests = Set(baseItems.map(\.digest))
            for item in baseItems where !(lastBaseDigests?.contains(item.digest) ?? true) {
                guard let arrived = known[item.digest]?.fastArrival else { continue }
                known[item.digest]?.fastArrival = nil
                lateKeychain.append((item.meta.kind, time.timeIntervalSince(arrived)))
            }
            if let last = lastBaseDigests, last != digests { baseChanged = true }
            lastBaseDigests = digests
            pruneTombstones(at: time)
            let live = baseItems.filter { tombstones[RemoteGroupTombstone.key(account: $0.meta.account, digest: $0.digest)] == nil }
            var byAccount: [String: [BaseItem]] = [:]
            for item in live { byAccount[item.meta.account, default: []].append(item) }

            var items: [RemoteGroupOverlayItem] = []
            var overlaid = Set<String>()
            for (account, entry) in entries {
                if tombstones[RemoteGroupTombstone.key(account: account, digest: entry.digest)] != nil {
                    entries[account] = nil
                    continue
                }
                let rivals = byAccount[account] ?? []
                if rivals.contains(where: { $0.digest == entry.digest }) {
                    // 钥匙串追上了。
                    entries[account] = nil
                    disagreeSince[account] = nil
                    continue
                }
                if let newest = rivals.max(by: { Self.isNewer($1.meta.writtenAt, $1.firstSeen, than: $0.meta.writtenAt, $0.firstSeen) }) {
                    guard Self.isNewer(entry.writtenAt, entry.arrivedAt, than: newest.meta.writtenAt, newest.firstSeen) else {
                        entries[account] = nil
                        disagreeSince[account] = nil
                        continue
                    }
                    let since = disagreeSince[account] ?? time
                    disagreeSince[account] = since
                    if time.timeIntervalSince(since) > Self.disagreementLifetime {
                        entries[account] = nil
                        disagreeSince[account] = nil
                        continue
                    }
                } else {
                    disagreeSince[account] = nil
                }
                overlaid.insert(account)
                items.append(RemoteGroupOverlayItem(account: account, digest: entry.digest, data: entry.data))
            }
            for item in live where !overlaid.contains(item.meta.account) {
                items.append(RemoteGroupOverlayItem(account: item.meta.account, digest: item.digest, data: item.data))
            }
            items.sort { ($0.account, $0.digest.base64EncodedString()) < ($1.account, $1.digest.base64EncodedString()) }
            pruneKnown(keeping: Set(items.map(\.digest)).union(digests), at: time)
            return (items, Array(tombstones.values))
        }
        for late in lateKeychain {
            AppLogger.notice("设备组：钥匙串也送到了快通道先收到的 \(late.kind)，晚 " + String(format: "%.1f", late.seconds) + " 秒",
                             category: RemoteLog.category)
        }
        if baseChanged { notify(.base) }
        return output
    }

    /// a 比 b 新：写入者的时间不同就按它；相同（或同一毫秒里写了两份）按本机见到的先后；再相同按摘要定一个。
    private static func isNewer(_ aWritten: Date, _ aArrived: Date, than bWritten: Date, _ bArrived: Date) -> Bool {
        let a = RemoteGroupTime(aWritten), b = RemoteGroupTime(bWritten)
        if a != b { return a > b }
        return aArrived >= bArrived
    }

    // MARK: - 以下都在锁里

    private func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func meta(for data: Data, digest: Data, at time: Date) -> Meta? {
        if let cached = known[digest] { return cached.record }
        let meta = RemoteGroupRecord.decode(data).map { record -> Meta in
            var device: RemoteGroupDevice?
            if case .device(let entry) = record { device = entry }
            return Meta(account: record.account, writtenAt: record.writtenAt, kind: record.kind, device: device)
        }
        known[digest] = Known(record: meta, firstSeen: time)
        return meta
    }

    private func decodeBase(_ data: [Data], at time: Date) -> [BaseItem] {
        data.compactMap { data in
            let digest = digest(data)
            guard let meta = meta(for: data, digest: digest, at: time) else { return nil }
            return BaseItem(data: data, digest: digest, meta: meta, firstSeen: known[digest]?.firstSeen ?? time)
        }
    }

    private func isExpired(_ tombstone: RemoteGroupTombstone, at time: Date) -> Bool {
        time.timeIntervalSince(tombstone.deletedAt.date) > Self.tombstoneLifetime
    }

    private func pruneTombstones(at time: Date) {
        tombstones = tombstones.filter { !isExpired($0.value, at: time) }
        resurrected = resurrected.filter { time.timeIntervalSince($0.value) < Self.tombstoneLifetime }
    }

    private func trimTombstones() {
        guard tombstones.count > Self.maxItems else { return }
        let sorted = tombstones.values.sorted { $0.deletedAt < $1.deletedAt }
        for tombstone in sorted.prefix(tombstones.count - Self.maxItems) { tombstones[tombstone.key] = nil }
    }

    private func evictIfNeeded() {
        while entries.count > Self.maxItems {
            let victims = entries.values.filter { !$0.isLocal }
            let pool = victims.isEmpty ? Array(entries.values) : victims
            guard let oldest = pool.min(by: { $0.arrivedAt < $1.arrivedAt }) else { return }
            entries[oldest.account] = nil
            disagreeSince[oldest.account] = nil
        }
    }

    /// 还在用的（全集里的、钥匙串里的、叠加层里的）一直记着；别的过 10 分钟忘掉，总数也有上限。
    private func pruneKnown(keeping inUse: Set<Data>, at time: Date) {
        let keep = inUse.union(entries.values.map(\.digest))
        known = known.filter { keep.contains($0.key) || time.timeIntervalSince($0.value.firstSeen) < Self.seenLifetime }
        guard known.count > Self.maxSeen else { return }
        let removable = known.filter { !keep.contains($0.key) }.sorted { $0.value.firstSeen < $1.value.firstSeen }
        for (digest, _) in removable.prefix(known.count - Self.maxSeen) { known[digest] = nil }
    }
}
