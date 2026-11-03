import Foundation

/// Small, thread-safe staging buffer between process output and SwiftTerm.
/// It bounds live-render memory by dropping whole stale chunks when full.
nonisolated final class TerminalOutputBuffer: @unchecked Sendable {
    private struct Chunk {
        let generation: Int
        let data: Data
    }

    private let lock = NSLock()
    private let capacityBytes: Int
    private var chunks: [Chunk] = []
    private var head = 0
    private var bufferedBytes = 0
    /// Tasks 在 `waitForData()` 中暂停的延续。`append()` / `clear()` 都会清空
    /// 此列表并 resume 所有等待者 —— 这让 flush loop 在空闲时挂起 0 CPU、
    /// 一字节到达即恢复，取代旧的 100ms 轮询。
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(capacityBytes: Int = 4 * 1024 * 1024) {
        self.capacityBytes = max(1024, capacityBytes)
    }

    func append(_ data: Data, generation: Int) {
        guard !data.isEmpty else { return }

        lock.lock()

        let chunk: Chunk
        if data.count > capacityBytes {
            let keepStart = data.index(data.endIndex, offsetBy: -capacityBytes)
            let kept = data[keepStart..<data.endIndex]
            chunk = Chunk(generation: generation, data: Data(kept))
        } else {
            chunk = Chunk(generation: generation, data: data)
        }

        chunks.append(chunk)
        bufferedBytes += chunk.data.count
        dropOverflowLocked()
        compactIfNeededLocked()
        let toWake = takeWaitersLocked()
        lock.unlock()

        resume(toWake)
    }

    func drain(maxBytes: Int, generation: Int) -> Data {
        guard maxBytes > 0 else { return Data() }

        lock.lock()
        defer { lock.unlock() }

        var output = Data()
        output.reserveCapacity(min(maxBytes, bufferedBytes))

        while head < chunks.count, output.count < maxBytes {
            let chunk = chunks[head]
            guard chunk.generation == generation else {
                bufferedBytes -= chunk.data.count
                head += 1
                continue
            }

            let remaining = maxBytes - output.count
            if chunk.data.count <= remaining {
                output.append(chunk.data)
                bufferedBytes -= chunk.data.count
                head += 1
            } else {
                output.append(chunk.data.prefix(remaining))
                let suffix = chunk.data.dropFirst(remaining)
                chunks[head] = Chunk(generation: chunk.generation, data: Data(suffix))
                bufferedBytes -= remaining
            }
        }

        compactIfNeededLocked()
        return output
    }

    /// 当前积压的字节数（含尚未丢弃的旧代次块，作为节流参考已足够）。
    var pendingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferedBytes
    }

    func clear() {
        lock.lock()
        chunks.removeAll(keepingCapacity: true)
        head = 0
        bufferedBytes = 0
        // 唤醒所有等待者，让被取消的 flush task 能感知 generation 重置后退出。
        let toWake = takeWaitersLocked()
        lock.unlock()
        resume(toWake)
    }

    /// 异步挂起直到 buffer 中有数据。调用时已有缓冲字节则立即返回，
    /// 避免 drain→wait 之间的丢信号竞态。`clear()` 也会唤醒挂起的等待者。
    func waitForData() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if bufferedBytes > 0 {
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    private func takeWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        guard !waiters.isEmpty else { return [] }
        let snapshot = waiters
        waiters.removeAll(keepingCapacity: true)
        return snapshot
    }

    /// 始终在锁外 resume，避免在持锁期间触发等待者继续逻辑可能反入本类。
    private func resume(_ continuations: [CheckedContinuation<Void, Never>]) {
        for cont in continuations { cont.resume() }
    }

    private func dropOverflowLocked() {
        while bufferedBytes > capacityBytes, head < chunks.count {
            let chunk = chunks[head]
            bufferedBytes -= chunk.data.count
            head += 1
        }
    }

    private func compactIfNeededLocked() {
        guard head > 64, head * 2 > chunks.count else { return }
        chunks.removeFirst(head)
        head = 0
    }
}
