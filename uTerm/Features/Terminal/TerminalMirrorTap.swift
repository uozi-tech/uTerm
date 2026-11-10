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

    /// 发给订阅者的一段数据。
    nonisolated enum Chunk: Equatable, Sendable {
        /// 快照的一段。`isFirst`：一张新快照的开头（接收端丢掉手上没收完的那张）；`isLast`：收齐了，可以还原。
        case snapshot(Data, isFirst: Bool, isLast: Bool)
        /// 快照之后的原样字节。
        case output(Data)
    }

    /// 一个镜像订阅者：Mac 端替它攒着还没发出去的数据。`take` 由连接队列调用。
    nonisolated final class Subscriber: @unchecked Sendable {
        let id: UUID
        private let lock = NSLock()
        private var snapshot: Data?
        private var snapshotOffset = 0
        private var pending = Data()
        private var snapshotWanted = true
        private let limit: Int
        private let onReadable: @Sendable () -> Void

        init(id: UUID, limit: Int, onReadable: @escaping @Sendable () -> Void) {
            self.id = id
            self.limit = limit
            self.onReadable = onReadable
        }

        /// 取走最多 `maxBytes` 字节；没有则 nil。快照没发完之前先发快照。
        func take(maxBytes: Int) -> Chunk? {
            lock.lock()
            defer { lock.unlock() }
            if let snapshot {
                let start = snapshotOffset
                let end = min(snapshot.count, start + max(1, maxBytes))
                snapshotOffset = end
                let piece = snapshot.subdata(in: start..<end)
                let isLast = end == snapshot.count
                if isLast { self.snapshot = nil }
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
            return (snapshot.map { $0.count - snapshotOffset } ?? 0) + pending.count
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
                snapshotWanted = true
                return false
            }
            pending.append(bytes)
            return true
        }

        /// 换成一张新快照：它之前还没发出的字节、没发完的旧快照都不必再发。
        fileprivate func replace(with snapshot: Data) {
            lock.lock()
            self.snapshot = snapshot
            snapshotOffset = 0
            pending = Data()
            snapshotWanted = false
            lock.unlock()
        }

        fileprivate func notify() {
            onReadable()
        }
    }

    private let makeSnapshot: @Sendable () -> Data?
    private let exclusively: @Sendable (() -> Void) -> Void
    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]

    /// - `snapshot`：拍一张当前画面的二进制快照。
    /// - `exclusively`：在「没有字节正在喂」的状态下跑一段代码（`TerminalOutputPump.performWhileFeedingPaused`）。
    init(snapshot: @escaping @Sendable () -> Data?, exclusively: @escaping @Sendable (() -> Void) -> Void) {
        makeSnapshot = snapshot
        self.exclusively = exclusively
    }

    var hasSubscribers: Bool { lock.withLock { !subscribers.isEmpty } }

    /// 新订阅者从一张快照开始。
    @discardableResult
    func subscribe(id: UUID, limit: Int = RemoteConstants.maxPendingOutputBytes,
                   onReadable: @escaping @Sendable () -> Void) -> Subscriber {
        let subscriber = Subscriber(id: id, limit: limit, onReadable: onReadable)
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
        var snapshot: Data?
        for subscriber in subscribers {
            if !subscriber.needsSnapshot, subscriber.append(bytes) {
                subscriber.notify()
                continue
            }
            // 等快照的订阅者：这批字节的效果已经在快照里了。
            if snapshot == nil { snapshot = makeSnapshot() }
            guard let snapshot else { continue }
            subscriber.replace(with: snapshot)
            subscriber.notify()
        }
    }

    private var currentSubscribers: [Subscriber] { lock.withLock { Array(subscribers.values) } }

    /// 调用方已经借到泵的锁。
    private func serviceSnapshots() {
        let waiting = currentSubscribers.filter(\.needsSnapshot)
        guard !waiting.isEmpty, let snapshot = makeSnapshot() else { return }
        for subscriber in waiting {
            subscriber.replace(with: snapshot)
            subscriber.notify()
        }
    }
}
