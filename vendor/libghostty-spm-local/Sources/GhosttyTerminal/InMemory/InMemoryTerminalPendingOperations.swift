import Foundation

/// Host output not yet handed to a surface, oldest first.
///
/// A head index makes taking the oldest entry O(1): `removeFirst` on an
/// array shifts every queued entry, so a backlog of n tiny writes — a chatty
/// transport outrunning a slow parse — took O(n²) to drain. A running byte
/// count spares the detached cap a rescan of the queue on every write.
struct InMemoryTerminalPendingOperations {
    enum Operation {
        case write(Data)
        /// uTerm 本地补丁：重建出来的历史（`receiveReplay`），交给 surface 时不产生应答。
        case replay(Data)
        case processExit(exitCode: UInt32, runtimeMilliseconds: UInt64)
    }

    private struct Entry {
        var operation: Operation
        /// The newest append this entry holds; a coalesced write holds several.
        var sequence: Int
    }

    /// Consumed and trimmed slots are `nil` until compaction drops them, so
    /// their bytes are released at once.
    private var storage: [Entry?] = []
    private var head = 0
    private(set) var count = 0
    private(set) var writeByteCount = 0
    /// uTerm 本地补丁：排着的回放字节。单独记：离线上限（`trimWrites`）只管实时输出，不能因为
    /// 排着一段大回放就把后面的实时输出裁掉。
    private(set) var replayByteCount = 0
    /// Numbers every append, so a waiter can tell when everything appended
    /// before it has left the queue — handed over or trimmed away.
    private(set) var appendedSequence = 0
    private(set) var retiredSequence = 0

    var isEmpty: Bool {
        count == 0
    }

    mutating func append(_ operation: Operation) {
        switch operation {
        case let .write(data): writeByteCount += data.count
        case let .replay(data): replayByteCount += data.count
        case .processExit: break
        }
        appendedSequence += 1
        storage.append(Entry(operation: operation, sequence: appendedSequence))
        count += 1
    }

    /// Appends to the newest entry when it is a write, so a detached flood
    /// stays one entry. The slot is cleared first so the append is in place.
    mutating func appendCoalescing(_ data: Data) {
        let last = storage.count - 1
        guard last >= head, case var .write(merged)? = storage[last]?.operation else {
            append(.write(data))
            return
        }
        storage[last] = nil
        merged.append(data)
        appendedSequence += 1
        storage[last] = Entry(operation: .write(merged), sequence: appendedSequence)
        writeByteCount += data.count
    }

    mutating func popFirst() -> Operation? {
        while head < storage.count {
            let entry = storage[head]
            storage[head] = nil
            head += 1
            guard let entry else { continue }
            count -= 1
            switch entry.operation {
            case let .write(data): writeByteCount -= data.count
            case let .replay(data): replayByteCount -= data.count
            case .processExit: break
            }
            retiredSequence = entry.sequence
            compact()
            return entry.operation
        }
        compact()
        return nil
    }

    /// Drops the oldest queued bytes past `limit`; process exits are kept.
    mutating func trimWrites(toLimit limit: Int) {
        var excess = writeByteCount - limit
        var index = head
        while excess > 0, index < storage.count {
            guard let entry = storage[index], case var .write(data) = entry.operation else {
                index += 1
                continue
            }
            storage[index] = nil
            let dropped = min(excess, data.count)
            excess -= dropped
            writeByteCount -= dropped
            if dropped == data.count {
                count -= 1
                retiredSequence = max(retiredSequence, entry.sequence)
            } else {
                data.removeFirst(dropped)
                storage[index] = Entry(operation: .write(Data(data)), sequence: entry.sequence)
            }
            index += 1
        }
    }

    /// uTerm 本地补丁：丢掉所有还没交给 surface 的输出（实时的和回放的），进程退出留着。返回丢了多少字节。
    mutating func removeAllOutput() -> Int {
        var dropped = 0
        for index in head ..< storage.count {
            guard let entry = storage[index] else { continue }
            switch entry.operation {
            case let .write(data), let .replay(data):
                dropped += data.count
                storage[index] = nil
                count -= 1
                retiredSequence = max(retiredSequence, entry.sequence)
            case .processExit:
                break
            }
        }
        writeByteCount = 0
        replayByteCount = 0
        return dropped
    }

    /// Amortized O(1): the consumed prefix is dropped only once it is at
    /// least half the storage.
    private mutating func compact() {
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 1024, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}
