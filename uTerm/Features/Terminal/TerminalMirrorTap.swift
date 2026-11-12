import Foundation

/// 把一条终端会话镜像给远端设备（远控接入）。
///
/// 接入时先给订阅者一张快照（影子终端的二进制快照 `ShadowTerminal.snapshot()`，接收端还原进自己的影子终端再回放进
/// 画面），之后把这条会话吃进去的每一批字节原样转给它。接入点是输出泵的 tap（`TerminalOutputPump.onFed`）：
/// 字节刚喂进影子终端、泵的锁还在手上，这时拍的快照正好对应「到这批字节为止」，快照与之后的字节之间不会插进或漏掉字节。
/// 二进制快照带着没走完的半个转义序列，所以任何字节位置上都能拍，不用等解析边界。
///
/// 这里是热路径：没有订阅者时只做一次判空；有订阅者时也只是加锁追加一份字节，编码、加密、发送都交给连接自己的
/// 队列去做。积压超过上限（对端太慢，或在 `cat` 大文件）就丢弃积压、改发快照，所以带宽有上限，也绝不反压 Mac
/// 自己的终端。
///
/// 线程：`didFeed` 在泵喂字节的那条线程上调（泵的锁在手上）；其余方法任何线程可调，要拍快照时自己去借泵的锁
/// （`exclusively`）。
nonisolated final class TerminalMirrorTap: @unchecked Sendable {

    /// 发给订阅者的一段数据（远控进程也认得这个类型，定义在 `RemoteHostSessions.swift`）。
    typealias Chunk = RemoteTerminalChunk

    /// 在泵的锁里拍下、还没裁回滚的一张快照（`ShadowTerminal.untrimmedSnapshot`）。第一个要发它的订阅者在连接队列上裁，
    /// 同一刻拍给几个订阅者的共用这一份结果。
    fileprivate nonisolated final class PendingSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var source: ShadowTerminal.UntrimmedSnapshot?
        private var result = Data()

        init(_ source: ShadowTerminal.UntrimmedSnapshot) {
            self.source = source
        }

        /// 裁好的快照；裁失败时退回整份（多带些回滚，画面一样）。
        var data: Data {
            lock.withLock {
                if let source {
                    result = (try? source.trimmed()) ?? source.full
                    self.source = nil
                }
                return result
            }
        }

        /// 还没裁时按整份算。
        var estimatedCount: Int {
            lock.withLock { source?.full.count ?? result.count }
        }
    }

    /// 一个镜像订阅者：Mac 端替它攒着还没发出去的数据。`take` 由连接队列调用。
    nonisolated final class Subscriber: RemoteTerminalFeed, @unchecked Sendable {
        let id: UUID
        private let lock = NSLock()
        private var snapshot: PendingSnapshot?
        /// `snapshot` 裁好之后的字节（开始发它的时候才裁）。
        private var snapshotBytes: Data?
        private var snapshotOffset = 0
        private var pending = Data()
        private var snapshotWanted = true
        private let limit: Int
        private let onReadable: @Sendable () -> Void
        /// 第一张快照要等它成立才拍（接入时等终端按对端的尺寸钉好）；过了 `readyDeadline` 不再等。之后的快照不等。
        private var firstSnapshotReady: (@Sendable () -> Bool)?
        private var readyDeadline: UInt64 = 0

        init(id: UUID, limit: Int, onReadable: @escaping @Sendable () -> Void) {
            self.id = id
            self.limit = limit
            self.onReadable = onReadable
        }

        fileprivate func waitForFirstSnapshot(until ready: @escaping @Sendable () -> Bool, timeout: TimeInterval) {
            lock.withLock {
                firstSnapshotReady = ready
                readyDeadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1e9)
            }
        }

        /// 此刻能不能给它拍快照。调用方已经借到泵的锁。
        fileprivate var canTakeSnapshot: Bool {
            let check = lock.withLock { () -> (@Sendable () -> Bool)? in
                guard let ready = firstSnapshotReady else { return nil }
                if DispatchTime.now().uptimeNanoseconds >= readyDeadline {
                    firstSnapshotReady = nil
                    return nil
                }
                return ready
            }
            guard let check else { return true }
            guard check() else { return false }
            lock.withLock { firstSnapshotReady = nil }
            return true
        }

        /// 取走最多 `maxBytes` 字节；没有则 nil。快照没发完之前先发快照。
        func take(maxBytes: Int) -> Chunk? {
            // 快照第一次发之前先裁回滚：不拿着订阅者的锁裁（泵那头追加字节要拿这把锁）。
            if let unresolved = lock.withLock({ snapshotBytes == nil ? snapshot : nil }) {
                let bytes = unresolved.data
                lock.withLock { if snapshot === unresolved, snapshotBytes == nil { snapshotBytes = bytes } }
            }
            lock.lock()
            defer { lock.unlock() }
            if let bytes = snapshotBytes {
                let start = snapshotOffset
                let end = min(bytes.count, start + max(1, maxBytes))
                snapshotOffset = end
                // 切片，不拷贝。
                let piece = bytes[(bytes.startIndex + start)..<(bytes.startIndex + end)]
                let isLast = end == bytes.count
                if isLast {
                    snapshot = nil
                    snapshotBytes = nil
                }
                return .snapshot(piece, isFirst: start == 0, isLast: isLast)
            }
            guard !pending.isEmpty else { return nil }
            if pending.count <= maxBytes {
                let all = pending
                pending = Data()
                return .output(all)
            }
            let head = pending.prefix(maxBytes)
            pending = Data(pending.dropFirst(maxBytes))
            return .output(Data(head))
        }

        /// 还没发出去的字节（快照剩下的部分 + 之后的输出）。
        var pendingBytes: Int {
            lock.lock()
            defer { lock.unlock() }
            let snapshotLeft = snapshotBytes.map { $0.count - snapshotOffset } ?? snapshot?.estimatedCount ?? 0
            return snapshotLeft + pending.count
        }

        fileprivate var needsSnapshot: Bool {
            lock.lock()
            defer { lock.unlock() }
            return snapshotWanted
        }

        fileprivate func markNeedsSnapshot() {
            lock.lock()
            snapshotWanted = true
            snapshot = nil
            snapshotBytes = nil
            pending = Data()
            lock.unlock()
        }

        /// 追加一批字节；积压超过上限返回 false（积压已清空，等待快照）。
        fileprivate func append(_ bytes: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard pending.count + bytes.count <= limit else {
                pending = Data()
                snapshot = nil
                snapshotBytes = nil
                snapshotWanted = true
                return false
            }
            pending.append(bytes)
            return true
        }

        /// 换成一张新快照：它之前还没发出的字节、没发完的旧快照都不必再发。
        fileprivate func replace(with snapshot: PendingSnapshot) {
            lock.lock()
            self.snapshot = snapshot
            snapshotBytes = nil
            snapshotOffset = 0
            pending = Data()
            snapshotWanted = false
            lock.unlock()
        }

        fileprivate func notify() {
            onReadable()
        }
    }

    private let makeSnapshot: @Sendable () -> ShadowTerminal.UntrimmedSnapshot?
    private let exclusively: @Sendable (() -> Void) -> Void
    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]

    /// - `snapshot`：拍一张当前画面的二进制快照（在泵的锁里调，只拍整份；裁回滚在连接队列上，见 `PendingSnapshot`）。
    /// - `exclusively`：在「没有字节正在喂」的状态下跑一段代码（`TerminalOutputPump.performWhileFeedingPaused`）。
    init(snapshot: @escaping @Sendable () -> ShadowTerminal.UntrimmedSnapshot?,
         exclusively: @escaping @Sendable (() -> Void) -> Void) {
        makeSnapshot = snapshot
        self.exclusively = exclusively
    }

    var hasSubscribers: Bool { lock.withLock { !subscribers.isEmpty } }

    /// 新订阅者从一张快照开始。
    ///
    /// `firstSnapshotWhen`：第一张快照等它成立才拍（远控接入：终端按对端的尺寸钉好、影子终端报出那个网格之后），
    /// 最多等 `timeout`。这期间的字节不攒（第一张快照里都有）。钉尺寸是异步的（视图改尺寸 → 引擎在 IO 线程上改网格），
    /// 不等的话第一张快照是旧网格的，紧接着因为网格变了再发一张，对端先按错的网格画一下。
    @discardableResult
    func subscribe(id: UUID, limit: Int = RemoteConstants.maxPendingOutputBytes,
                   firstSnapshotWhen ready: (@Sendable () -> Bool)? = nil, timeout: TimeInterval = 1,
                   onReadable: @escaping @Sendable () -> Void) -> Subscriber {
        let subscriber = Subscriber(id: id, limit: limit, onReadable: onReadable)
        if let ready {
            subscriber.waitForFirstSnapshot(until: ready, timeout: timeout)
            // 等到超时也没成立（也没有字节、没有网格变化来叫醒）：到点自己拍。
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout + 0.01) { [weak self] in
                guard let self else { return }
                self.exclusively { self.serviceSnapshots() }
            }
        }
        exclusively {
            self.lock.withLock { self.subscribers[id] = subscriber }
            self.serviceSnapshots()
        }
        return subscriber
    }

    func unsubscribe(id: UUID) {
        lock.withLock { _ = subscribers.removeValue(forKey: id) }
    }

    /// 本地状态发生了不经过字节流的变化（尺寸变化、从检查点还原）：所有订阅者改为重发快照。
    func invalidateAll() {
        guard hasSubscribers else { return }
        exclusively {
            for subscriber in self.currentSubscribers { subscriber.markNeedsSnapshot() }
            self.serviceSnapshots()
        }
    }

    /// 影子终端刚吃进去一批字节（泵的 tap，泵的锁在手上）。
    func didFeed(_ bytes: Data) {
        let subscribers = currentSubscribers
        guard !subscribers.isEmpty else { return }
        var snapshot: PendingSnapshot?
        for subscriber in subscribers {
            if !subscriber.needsSnapshot, subscriber.append(bytes) {
                subscriber.notify()
                continue
            }
            // 等快照的订阅者：这批字节的效果已经在（之后拍的）快照里了。
            guard subscriber.canTakeSnapshot else { continue }
            if snapshot == nil { snapshot = makeSnapshot().map(PendingSnapshot.init) }
            guard let snapshot else { continue }
            subscriber.replace(with: snapshot)
            subscriber.notify()
        }
    }

    private var currentSubscribers: [Subscriber] { lock.withLock { Array(subscribers.values) } }

    /// 调用方已经借到泵的锁。
    private func serviceSnapshots() {
        let waiting = currentSubscribers.filter { $0.needsSnapshot && $0.canTakeSnapshot }
        guard !waiting.isEmpty, let snapshot = makeSnapshot().map(PendingSnapshot.init) else { return }
        for subscriber in waiting {
            subscriber.replace(with: snapshot)
            subscriber.notify()
        }
    }
}
