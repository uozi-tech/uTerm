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

    init(capacityBytes: Int = 4 * 1024 * 1024) {
        self.capacityBytes = max(1024, capacityBytes)
    }

    func append(_ data: Data, generation: Int) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

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

    func clear() {
        lock.lock()
        chunks.removeAll(keepingCapacity: true)
        head = 0
        bufferedBytes = 0
        lock.unlock()
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
