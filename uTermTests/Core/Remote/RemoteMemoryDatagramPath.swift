import CryptoKit
import Foundation
@testable import uTerm

/// 进程内的一对数据报路径，带差网络：丢包、乱序、延迟、限速，瓶颈缓冲满了就丢（和真实路由器一样）。
nonisolated final class RemoteMemoryDatagramPath: RemoteDatagramPath, @unchecked Sendable {
    /// 一个方向的线路。到达时刻由 `RemoteImpairmentSchedule` 算，一个定时器按时刻投递。
    private final class Line: @unchecked Sendable {
        private let queue = DispatchQueue(label: "test.memory-datagram", qos: .userInteractive)
        private var schedule: RemoteImpairmentSchedule
        private var inFlight: [(arrival: TimeInterval, data: Data)] = []
        private var timer: DispatchSourceTimer?
        private var armed = TimeInterval.infinity
        private var closing = false
        /// 关闭之后还在路上的包照样送到，这期间线路自己撑着自己。
        private var keepAlive: Line?
        private let maxQueueDelay: TimeInterval
        var receiver: RemoteMemoryDatagramPath? {
            get { weakReceiver }
            set { weakReceiver = newValue }
        }
        private weak var weakReceiver: RemoteMemoryDatagramPath?
        private(set) var sent = 0
        private(set) var droppedByBuffer = 0
        private(set) var droppedByLoss = 0

        init(impairment: RemoteLinkImpairment, seed: UInt64, maxQueueDelay: TimeInterval) {
            schedule = RemoteImpairmentSchedule(impairment: impairment, isOrdered: false, seed: seed)
            self.maxQueueDelay = maxQueueDelay
        }

        private static var now: TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9 }

        func send(_ data: Data) {
            queue.async { [self] in
                guard !closing else { return }
                let now = Self.now
                sent += 1
                // 瓶颈缓冲满了：这个包进不了队列。
                if schedule.queueDrainsAt - now > maxQueueDelay {
                    droppedByBuffer += 1
                    return
                }
                guard let arrival = schedule.delivery(bytes: data.count, now: now) else {
                    droppedByLoss += 1
                    return
                }
                let position = inFlight.firstIndex { $0.arrival > arrival } ?? inFlight.count
                inFlight.insert((arrival, data), at: position)
                arm()
            }
        }

        func setImpairment(_ impairment: RemoteLinkImpairment) {
            queue.async { self.schedule.impairment = impairment }
        }

        func close() {
            queue.async { [self] in
                // 真实的网络里，发出去的包不会因为发送方关了就消失。
                closing = true
                if inFlight.isEmpty { stop() } else { keepAlive = self }
            }
        }

        var counters: (sent: Int, droppedByBuffer: Int, droppedByLoss: Int) {
            queue.sync { (sent, droppedByBuffer, droppedByLoss) }
        }

        private func arm() {
            guard let first = inFlight.first, first.arrival < armed else { return }
            armed = first.arrival
            if timer == nil {
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.setEventHandler { [weak self] in self?.fire() }
                source.resume()
                timer = source
            }
            timer?.schedule(deadline: .now() + max(0, first.arrival - Self.now), leeway: .microseconds(200))
        }

        private func fire() {
            armed = .infinity
            let now = Self.now
            while let first = inFlight.first, first.arrival <= now {
                inFlight.removeFirst()
                receiver?.deliver(first.data)
            }
            if closing, inFlight.isEmpty {
                stop()
            } else {
                arm()
            }
        }

        private func stop() {
            timer?.cancel()
            timer = nil
            keepAlive = nil
        }
    }

    private let lock = NSLock()
    private var onDatagram: (@Sendable (Data) -> Void)?
    private var pending: [Data] = []
    private let outgoing: Line
    private var closed = false

    private init(outgoing: Line) {
        self.outgoing = outgoing
    }

    static func pair(impairment: RemoteLinkImpairment = .clean, reverse: RemoteLinkImpairment? = nil, seed: UInt64 = 1,
                     maxQueueDelay: TimeInterval = 0.25) -> (RemoteMemoryDatagramPath, RemoteMemoryDatagramPath) {
        let forward = Line(impairment: impairment, seed: seed, maxQueueDelay: maxQueueDelay)
        let backward = Line(impairment: reverse ?? impairment, seed: seed &+ 1000, maxQueueDelay: maxQueueDelay)
        let first = RemoteMemoryDatagramPath(outgoing: forward)
        let second = RemoteMemoryDatagramPath(outgoing: backward)
        forward.receiver = second
        backward.receiver = first
        return (first, second)
    }

    func start(onDatagram: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        self.onDatagram = onDatagram
        let queued = pending
        pending = []
        lock.unlock()
        for datagram in queued { onDatagram(datagram) }
    }

    func send(_ datagram: Data) {
        outgoing.send(datagram)
    }

    func close() {
        lock.lock()
        closed = true
        onDatagram = nil
        lock.unlock()
        outgoing.close()
    }

    func setImpairment(_ impairment: RemoteLinkImpairment) {
        outgoing.setImpairment(impairment)
    }

    /// 发出去的方向的统计。
    var counters: (sent: Int, droppedByBuffer: Int, droppedByLoss: Int) { outgoing.counters }

    fileprivate func deliver(_ datagram: Data) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        guard let handler = onDatagram else {
            pending.append(datagram)
            lock.unlock()
            return
        }
        lock.unlock()
        handler(datagram)
    }
}

/// 一对对称的控制密钥。
nonisolated func makeDatagramKeys() -> (first: RemoteDatagramKeys, second: RemoteDatagramKeys) {
    let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
    return (RemoteDatagramKeys(send: a, receive: b), RemoteDatagramKeys(send: b, receive: a))
}
