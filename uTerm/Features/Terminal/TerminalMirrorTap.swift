import Foundation
import SwiftTerm

/// 把一条终端会话镜像给远端设备（远控接入）。
///
/// 接入时先给订阅者一份快照（`Terminal.snapshotSequence`，以 RIS 开头），之后把 Mac 自己的
/// 终端吃进去的每一批字节原样转给它。接入点在 `TerminalSession.flushPendingOutput`，也就是
/// `terminalView.feed` 的旁边，而不是读 SSH 输出的地方：只有在这里，字节顺序与 Mac 终端实际
/// 解析的顺序完全一致，快照与之后的字节也都在 MainActor 上产生，中间不会插进或漏掉字节。
///
/// 这里是热路径：没有订阅者时只做一次判空；有订阅者时也只是加锁追加一份字节，编码、加密、
/// 发送都交给连接自己的队列去做。积压超过上限（对端太慢，或在 `cat` 大文件）就丢弃积压、
/// 改发快照，所以带宽有上限，也绝不反压 Mac 自己的终端。
@MainActor
final class TerminalMirrorTap {

    /// 一个镜像订阅者：Mac 端替它攒着还没发出去的字节。`take` 由连接队列调用，其余在 MainActor 上。
    nonisolated final class Subscriber: @unchecked Sendable {
        let id: UUID
        private let lock = NSLock()
        private var pending = Data()
        private var snapshotWanted = true
        private let limit: Int
        private let onReadable: @Sendable () -> Void

        init(id: UUID, limit: Int, onReadable: @escaping @Sendable () -> Void) {
            self.id = id
            self.limit = limit
            self.onReadable = onReadable
        }

        /// 取走最多 `maxBytes` 字节积压；没有则 nil。
        func take(maxBytes: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else { return nil }
            if pending.count <= maxBytes {
                let all = pending
                pending = Data()
                return all
            }
            let head = pending.prefix(maxBytes)
            pending = Data(pending.dropFirst(maxBytes))
            return Data(head)
        }

        var pendingBytes: Int {
            lock.lock()
            defer { lock.unlock() }
            return pending.count
        }

        fileprivate var needsSnapshot: Bool {
            lock.lock()
            defer { lock.unlock() }
            return snapshotWanted
        }

        fileprivate func markNeedsSnapshot() {
            lock.lock()
            snapshotWanted = true
            pending = Data()
            lock.unlock()
        }

        /// 追加一批字节；积压超过上限返回 false（积压已清空，等待快照）。
        fileprivate func append(_ bytes: ArraySlice<UInt8>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard pending.count + bytes.count <= limit else {
                pending = Data()
                snapshotWanted = true
                return false
            }
            pending.append(contentsOf: bytes)
            return true
        }

        /// 用快照替换积压：快照以 RIS 开头，在它之前还没发出的字节不必再发。
        fileprivate func replace(with snapshot: [UInt8]) {
            lock.lock()
            pending = Data(snapshot)
            snapshotWanted = false
            lock.unlock()
        }

        fileprivate func notify() {
            onReadable()
        }
    }

    private let terminal: () -> Terminal
    private var subscribers: [UUID: Subscriber] = [:]
    private var fallbackTask: Task<Void, Never>?

    /// 解析器迟迟到不了边界（程序输出了半截转义序列就停了）时，最多等这么久就强制拍快照。
    static let snapshotFallbackDelay: Duration = .milliseconds(50)

    init(terminal: @escaping () -> Terminal) {
        self.terminal = terminal
    }

    var hasSubscribers: Bool { !subscribers.isEmpty }

    /// 新订阅者从一份快照开始。
    @discardableResult
    func subscribe(id: UUID, limit: Int = RemoteConstants.maxPendingOutputBytes,
                   onReadable: @escaping @Sendable () -> Void) -> Subscriber {
        let subscriber = Subscriber(id: id, limit: limit, onReadable: onReadable)
        subscribers[id] = subscriber
        serviceSnapshots()
        return subscriber
    }

    func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty {
            fallbackTask?.cancel()
            fallbackTask = nil
        }
    }

    /// 本地状态发生了不经过字节流的变化（清屏、尺寸变化）：所有订阅者改为重发快照。
    func invalidateAll() {
        guard !subscribers.isEmpty else { return }
        for subscriber in subscribers.values { subscriber.markNeedsSnapshot() }
        serviceSnapshots()
    }

    /// Mac 终端刚吃进去一批字节（在 `terminalView.feed` 之后调用）。
    func didFeed(_ bytes: ArraySlice<UInt8>) {
        guard !subscribers.isEmpty else { return }
        var snapshot: [UInt8]?
        var atBoundary: Bool?
        var waiting = false
        for subscriber in subscribers.values {
            if !subscriber.needsSnapshot {
                if subscriber.append(bytes) {
                    subscriber.notify()
                    continue
                }
            }
            // 等快照的订阅者：这批字节的效果会体现在快照里，直接丢掉。
            if atBoundary == nil { atBoundary = terminal().isAtSnapshotBoundary }
            if atBoundary == true {
                if snapshot == nil { snapshot = makeSnapshot() }
                subscriber.replace(with: snapshot!)
                subscriber.notify()
            } else {
                waiting = true
            }
        }
        if waiting { scheduleFallback() }
    }

    private func serviceSnapshots(force: Bool = false) {
        let waiting = subscribers.values.filter(\.needsSnapshot)
        guard !waiting.isEmpty else { return }
        guard force || terminal().isAtSnapshotBoundary else {
            scheduleFallback()
            return
        }
        let snapshot = makeSnapshot()
        for subscriber in waiting {
            subscriber.replace(with: snapshot)
            subscriber.notify()
        }
    }

    private func makeSnapshot() -> [UInt8] {
        terminal().snapshotSequence(scrollbackLimit: RemoteConstants.snapshotScrollback)
    }

    private func scheduleFallback() {
        guard fallbackTask == nil else { return }
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.snapshotFallbackDelay)
            guard let self, !Task.isCancelled else { return }
            self.fallbackTask = nil
            self.serviceSnapshots(force: true)
        }
    }
}
