import Foundation
@preconcurrency import Network

/// 一条差网络的参数。两个方向各按这些参数算，互不影响。
nonisolated struct RemoteLinkImpairment: Equatable, Sendable {
    /// 单程固定延迟（秒）。
    var delay: TimeInterval = 0
    /// 单程附加的随机延迟上限（秒）。
    var jitter: TimeInterval = 0
    /// 每个数据包的丢失概率。TCP 上表现为这个包和后面的数据一起晚到 `retransmitPenalty`。
    var lossRate: Double = 0
    /// 每个数据报被故意延后、让后面的包抢先的概率。只对 UDP 有意义，TCP 永远有序。
    var reorderRate: Double = 0
    /// 限速（字节 / 秒）。nil = 不限。
    var bytesPerSecond: Int?
    /// TCP 上丢一个包要多等多久（模拟重传）。
    var retransmitPenalty: TimeInterval = 0.2

    static let clean = RemoteLinkImpairment()
}

/// 决定每个包什么时候到、到不到。纯函数加确定的随机序列：同一个种子每次结果都一样，测试不靠运气。
nonisolated struct RemoteImpairmentSchedule {
    /// 把 TCP 字节流切成多大的包来算丢包和限速。
    static let segmentBytes = 1400

    var impairment: RemoteLinkImpairment
    let isOrdered: Bool
    private var random: UInt64
    private var nextFree: TimeInterval = 0
    private var lastDelivery: TimeInterval = 0

    init(impairment: RemoteLinkImpairment, isOrdered: Bool, seed: UInt64) {
        self.impairment = impairment
        self.isOrdered = isOrdered
        self.random = seed
    }

    /// 一个包在 `now` 进入链路，返回它离开链路的时刻。nil = 丢了（只有 UDP 会丢）。
    mutating func delivery(bytes: Int, now: TimeInterval) -> TimeInterval? {
        var sendDone = now
        if let rate = impairment.bytesPerSecond {
            nextFree = max(now, nextFree) + Double(bytes) / Double(rate)
            sendDone = nextFree
        }
        let lost = chance(impairment.lossRate)
        if lost && !isOrdered { return nil }
        var arrival = sendDone + impairment.delay + uniform() * impairment.jitter
        if lost { arrival += impairment.retransmitPenalty }
        if !isOrdered, chance(impairment.reorderRate) {
            arrival += max(impairment.delay, 0.02)
        }
        if isOrdered { arrival = max(arrival, lastDelivery) }
        lastDelivery = max(lastDelivery, arrival)
        return arrival
    }

    /// 限速队列排到什么时候了：TCP 代理用它决定何时再读，慢链路才能把背压传回发送端。
    var queueDrainsAt: TimeInterval { nextFree }

    private mutating func chance(_ probability: Double) -> Bool {
        guard probability > 0 else { return false }
        return uniform() < probability
    }

    private mutating func uniform() -> Double {
        // SplitMix64
        random &+= 0x9E37_79B9_7F4A_7C15
        var z = random
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

/// 进程内 TCP 故障代理：测试把手机端的连接指向它，再由它转给真实的 `RemoteHostServer`，
/// 用来模拟「Mac 不可达」「链路卡死」和差网络。不改任何生产代码。
///
/// - `.forwarding`：正常转发（按 `impairment` 加延迟、限速、丢包重传）。
/// - `.refusing`：已有连接全部断开，新连接接受后立刻关闭（对手机端就是连不上 Mac）。
/// - `.stalled`：连接保持，字节不再转发，也不报错（Wi-Fi 假死、对端消失但 TCP 还没超时）。
nonisolated final class RemoteFaultProxy: @unchecked Sendable {
    enum Mode: Sendable {
        case forwarding
        case refusing
        case stalled
    }

    /// 一个方向上等着到达的数据，严格先进先出。到达时刻是单调的（见 `RemoteImpairmentSchedule`）。
    private final class DeliveryLine: @unchecked Sendable {
        private var items: [(delivery: TimeInterval, chunk: Data)] = []
        private var head = 0
        var isTimerArmed = false

        func append(_ chunk: Data, at delivery: TimeInterval) {
            items.append((delivery, chunk))
        }

        var nextDelivery: TimeInterval? {
            head < items.count ? items[head].delivery : nil
        }

        func popDue(now: TimeInterval) -> Data? {
            guard head < items.count, items[head].delivery <= now else { return nil }
            let chunk = items[head].chunk
            head += 1
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
            }
            return chunk
        }
    }

    private final class Pair: @unchecked Sendable {
        let downstream: NWConnection
        let upstream: NWConnection
        let upstreamLine = DeliveryLine()
        let downstreamLine = DeliveryLine()
        var toUpstream: RemoteImpairmentSchedule
        var toDownstream: RemoteImpairmentSchedule

        init(downstream: NWConnection, upstream: NWConnection, impairment: RemoteLinkImpairment, seed: UInt64) {
            self.downstream = downstream
            self.upstream = upstream
            toUpstream = RemoteImpairmentSchedule(impairment: impairment, isOrdered: true, seed: seed)
            toDownstream = RemoteImpairmentSchedule(impairment: impairment, isOrdered: true, seed: seed &+ 1)
        }

        func cancel() {
            downstream.cancel()
            upstream.cancel()
        }
    }

    private let target: NWEndpoint
    private let queue = DispatchQueue(label: "com.uozi.uTerm.tests.fault-proxy")
    private let listener: NWListener
    private let seed: UInt64
    // 以下只在 queue 上读写。
    private var mode = Mode.forwarding
    private var impairment: RemoteLinkImpairment
    private var pairs: [ObjectIdentifier: Pair] = [:]
    private var acceptedCount = 0
    private var portValue: UInt16?

    init(targetPort: UInt16, impairment: RemoteLinkImpairment = .clean, seed: UInt64 = 1) throws {
        target = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!)
        self.impairment = impairment
        self.seed = seed
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.portValue = self.listener.port?.rawValue
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    deinit {
        listener.cancel()
    }

    /// 监听端口；还没就绪时 nil。
    var port: UInt16? {
        queue.sync { portValue }
    }

    /// 连进来过多少条连接（判断手机端是否还在重试）。
    var accepted: Int {
        queue.sync { acceptedCount }
    }

    func setMode(_ newMode: Mode) {
        queue.sync {
            mode = newMode
            guard newMode == .refusing else { return }
            for pair in pairs.values { pair.cancel() }
            pairs.removeAll()
        }
    }

    /// 改网络条件。已有连接和新连接都立刻按新参数算。
    func setImpairment(_ newImpairment: RemoteLinkImpairment) {
        queue.sync {
            impairment = newImpairment
            for pair in pairs.values {
                pair.toUpstream.impairment = newImpairment
                pair.toDownstream.impairment = newImpairment
            }
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for pair in pairs.values { pair.cancel() }
            pairs.removeAll()
        }
    }

    private func accept(_ downstream: NWConnection) {
        acceptedCount += 1
        guard mode != .refusing else {
            downstream.start(queue: queue)
            downstream.cancel()
            return
        }
        let upstream = NWConnection(to: target, using: .tcp)
        let pair = Pair(downstream: downstream, upstream: upstream, impairment: impairment,
                        seed: seed &+ UInt64(acceptedCount) &* 2)
        pairs[ObjectIdentifier(pair)] = pair
        downstream.start(queue: queue)
        upstream.start(queue: queue)
        pump(from: downstream, to: upstream, pair: pair, toUpstream: true)
        pump(from: upstream, to: downstream, pair: pair, toUpstream: false)
    }

    private func pump(from source: NWConnection, to destination: NWConnection, pair: Pair, toUpstream: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var lastDelivery = Self.now
            if let data, !data.isEmpty, self.mode != .stalled {
                lastDelivery = self.forward(data, to: destination, pair: pair, toUpstream: toUpstream)
            }
            if isComplete || error != nil {
                // 排在路上的字节先到，再断开。
                self.queue.asyncAfter(deadline: .now() + max(0, lastDelivery - Self.now)) {
                    pair.cancel()
                    self.pairs[ObjectIdentifier(pair)] = nil
                }
                return
            }
            // 限速时等队列排空再读：不读，内核缓冲满了发送端就慢下来，和真实的慢链路一样。
            let drainsAt = toUpstream ? pair.toUpstream.queueDrainsAt : pair.toDownstream.queueDrainsAt
            let wait = max(0, drainsAt - Self.now)
            guard wait > 0.001 else {
                self.pump(from: source, to: destination, pair: pair, toUpstream: toUpstream)
                return
            }
            self.queue.asyncAfter(deadline: .now() + wait) {
                self.pump(from: source, to: destination, pair: pair, toUpstream: toUpstream)
            }
        }
    }

    /// 切成包逐个算到达时刻，相邻且同一时刻到的合并发送。返回最后一段的到达时刻。
    private func forward(_ data: Data, to destination: NWConnection, pair: Pair, toUpstream: Bool) -> TimeInterval {
        let now = Self.now
        let line = toUpstream ? pair.upstreamLine : pair.downstreamLine
        var offset = data.startIndex
        var batchStart = offset
        var batchDelivery: TimeInterval?
        func flush(upTo end: Data.Index) {
            guard let delivery = batchDelivery, batchStart < end else { return }
            line.append(Data(data[batchStart..<end]), at: delivery)
        }
        while offset < data.endIndex {
            let end = min(offset + RemoteImpairmentSchedule.segmentBytes, data.endIndex)
            let delivery: TimeInterval
            if toUpstream {
                delivery = pair.toUpstream.delivery(bytes: end - offset, now: now) ?? now
            } else {
                delivery = pair.toDownstream.delivery(bytes: end - offset, now: now) ?? now
            }
            if let current = batchDelivery, delivery - current > 0.001 {
                flush(upTo: offset)
                batchStart = offset
                batchDelivery = delivery
            } else if batchDelivery == nil {
                batchDelivery = delivery
            }
            offset = end
        }
        flush(upTo: data.endIndex)
        drain(line, to: destination)
        return batchDelivery ?? now
    }

    /// 一次只挂一个定时器，到点的按排队顺序发。给每段各挂一个 `asyncAfter` 不行：定时器的容差随延迟变长
    /// （约 10%），排队一长，后挂的短定时器会抢在先挂的长定时器前面，TCP 字节流就乱了。
    private func drain(_ line: DeliveryLine, to destination: NWConnection) {
        guard !line.isTimerArmed else { return }
        let now = Self.now
        while let chunk = line.popDue(now: now) {
            if mode != .stalled { destination.send(content: chunk, completion: .contentProcessed { _ in }) }
        }
        guard let next = line.nextDelivery else { return }
        line.isTimerArmed = true
        queue.asyncAfter(deadline: .now() + max(0, next - now)) { [weak self] in
            line.isTimerArmed = false
            self?.drain(line, to: destination)
        }
    }

    fileprivate static var now: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// 进程内 UDP 故障代理：丢包、乱序、延迟、限速，也能整条封死（模拟封 UDP 的网络）。
nonisolated final class RemoteUDPFaultProxy: @unchecked Sendable {
    enum Mode: Sendable {
        case forwarding
        /// 所有数据报都丢掉。
        case blocked
    }

    private final class Flow: @unchecked Sendable {
        let downstream: NWConnection
        let upstream: NWConnection
        var toUpstream: RemoteImpairmentSchedule
        var toDownstream: RemoteImpairmentSchedule

        init(downstream: NWConnection, upstream: NWConnection, impairment: RemoteLinkImpairment, seed: UInt64) {
            self.downstream = downstream
            self.upstream = upstream
            toUpstream = RemoteImpairmentSchedule(impairment: impairment, isOrdered: false, seed: seed)
            toDownstream = RemoteImpairmentSchedule(impairment: impairment, isOrdered: false, seed: seed &+ 1)
        }

        func cancel() {
            downstream.cancel()
            upstream.cancel()
        }
    }

    private let target: NWEndpoint
    private let queue = DispatchQueue(label: "com.uozi.uTerm.tests.udp-fault-proxy")
    private let listener: NWListener
    private let seed: UInt64
    // 以下只在 queue 上读写。
    private var mode = Mode.forwarding
    private var impairment: RemoteLinkImpairment
    private var flows: [ObjectIdentifier: Flow] = [:]
    private var droppedCount = 0
    private var portValue: UInt16?

    init(targetPort: UInt16, impairment: RemoteLinkImpairment = .clean, seed: UInt64 = 1) throws {
        target = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!)
        self.impairment = impairment
        self.seed = seed
        listener = try NWListener(using: .udp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.portValue = self.listener.port?.rawValue
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    deinit {
        listener.cancel()
    }

    var port: UInt16? {
        queue.sync { portValue }
    }

    /// 被 `impairment` 或 `.blocked` 丢掉的数据报数。
    var dropped: Int {
        queue.sync { droppedCount }
    }

    func setMode(_ newMode: Mode) {
        queue.sync { mode = newMode }
    }

    func setImpairment(_ newImpairment: RemoteLinkImpairment) {
        queue.sync {
            impairment = newImpairment
            for flow in flows.values {
                flow.toUpstream.impairment = newImpairment
                flow.toDownstream.impairment = newImpairment
            }
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for flow in flows.values { flow.cancel() }
            flows.removeAll()
        }
    }

    private func accept(_ downstream: NWConnection) {
        let upstream = NWConnection(to: target, using: .udp)
        let flow = Flow(downstream: downstream, upstream: upstream, impairment: impairment,
                        seed: seed &+ UInt64(flows.count) &* 2)
        flows[ObjectIdentifier(flow)] = flow
        downstream.start(queue: queue)
        upstream.start(queue: queue)
        pump(from: downstream, to: upstream, flow: flow, toUpstream: true)
        pump(from: upstream, to: downstream, flow: flow, toUpstream: false)
    }

    private func pump(from source: NWConnection, to destination: NWConnection, flow: Flow, toUpstream: Bool) {
        source.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.forward(data, to: destination, flow: flow, toUpstream: toUpstream)
            }
            if error == nil {
                self.pump(from: source, to: destination, flow: flow, toUpstream: toUpstream)
            }
        }
    }

    private func forward(_ data: Data, to destination: NWConnection, flow: Flow, toUpstream: Bool) {
        guard mode == .forwarding else {
            droppedCount += 1
            return
        }
        let now = RemoteFaultProxy.now
        let delivery: TimeInterval?
        if toUpstream {
            delivery = flow.toUpstream.delivery(bytes: data.count, now: now)
        } else {
            delivery = flow.toDownstream.delivery(bytes: data.count, now: now)
        }
        guard let delivery else {
            droppedCount += 1
            return
        }
        let wait = delivery - now
        guard wait > 0 else {
            destination.send(content: data, completion: .contentProcessed { _ in })
            return
        }
        queue.asyncAfter(deadline: .now() + wait) {
            destination.send(content: data, completion: .contentProcessed { _ in })
        }
    }
}
