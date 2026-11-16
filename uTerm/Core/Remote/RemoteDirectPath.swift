import CryptoKit
import Foundation

/// 一次直连要用的密钥，从信令的共享密钥和两端随机数派生。
nonisolated struct RemoteDirectKeys: Sendable {
    /// `RemoteP2PTransport` 的控制密钥。
    let datagram: RemoteDatagramKeys
    /// 路径确认专用。和上面分开，序号才不会撞。
    let check: RemoteDatagramKeys
}

/// 一次打洞尝试：收集地址、打通、确认路径双向可用，然后交给 `RemoteP2PTransport`。
///
/// ICE 说「通了」只代表连通性检查过了。这里再用带认证的一来一回确认一次，有两个目的：
/// 单向不通的路径能及时发现并退回中继；手机只有确认之后才在这条路径上发握手。
/// 握手密钥一个会话只有一把，确认前不发，才不会在直连和中继上各用它加密一遍。
nonisolated final class RemoteDirectAttempt: @unchecked Sendable {
    /// 拨号时等多久。连不上时用户多等的就是这些时间，之后走中继。
    static let gatherLimit: Duration = .milliseconds(1200)
    static let connectLimit: Duration = .seconds(3)
    static let verifyLimit: Duration = .milliseconds(1500)
    /// Mac 等手机确认多久：覆盖手机的打通和确认，再留点信令的时间。
    static let hostWaitLimit: Duration = .seconds(8)
    /// 手机发的确认可能丢，Mac 回应之后再撑这么久，好回应它的重发。
    static let hostAnswerLinger: Duration = .seconds(2)

    private final class WeakBox: @unchecked Sendable {
        weak var attempt: RemoteDirectAttempt?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.direct", qos: .userInitiated)
    private let pathHandlers = RemoteICEDatagramPath.Handlers()
    private var agent: RemoteICEAgent?
    private var phase = RemoteICEAgent.Phase.disconnected
    private var gatheringDone = false
    private var checkCipher: RemoteDatagramCipher?
    private var answersChecks = false
    private var confirmed = false
    private var handedOff = false
    /// ICE 头一次报连上的时刻（读数用：把「打洞」和「确认路径」分开）。
    private var connectedAt: ContinuousClock.Instant?

    /// ICE 头一次报连上的时刻；还没连上为 nil。
    var firstConnected: ContinuousClock.Instant? { locked { connectedAt } }

    init?(stunHost: String?, stunPort: UInt16) {
        let box = WeakBox()
        let pathHandlers = self.pathHandlers
        var handlers = RemoteICEAgent.Handlers()
        handlers.onPhase = { phase in
            box.attempt?.record(phase: phase)
            if phase == .failed { pathHandlers.fail() }
        }
        handlers.onGatheringDone = { box.attempt?.recordGatheringDone() }
        // 交给传输层之后这个对象可能已经没了，业务数据不能跟着断。
        handlers.onData = { data in
            if data.first == RemoteDatagramKind.pathCheck.rawValue {
                box.attempt?.receiveCheck(data)
            } else {
                pathHandlers.deliver(data)
            }
        }
        guard let agent = RemoteICEAgent(stunHost: stunHost, stunPort: stunPort, queue: queue, handlers: handlers) else {
            return nil
        }
        self.agent = agent
        box.attempt = self
    }

    deinit {
        if !handedOff { agent?.close() }
    }

    func gather() -> Bool { agent?.gather() ?? false }
    func localDescription() -> String? { agent?.localDescription() }
    func setRemote(_ description: String) -> Bool { agent?.setRemote(description) ?? false }
    /// 应答的一方（Mac）：设对端并收集，见 `RemoteICEAgent.answer`。
    func answer(_ description: String) -> Bool { agent?.answer(description) ?? false }
    func selectedCandidates() -> (local: String, remote: String)? { agent?.selectedCandidates() }

    /// 交出去之前放弃：关掉 agent。交出去之后归传输层管，这里什么也不做。
    func close() {
        let toClose = locked { handedOff ? nil : agent }
        toClose?.close()
    }

    /// 等收集完成或到时限。到时限时已经收集到的地址还能用：本机地址总是最先出来。
    func waitForGathering(limit: Duration) async {
        await poll(limit: limit) { locked { gatheringDone } }
    }

    /// 等 ICE 打通。失败了立刻返回，不用等满。
    func waitForConnection(limit: Duration) async -> Bool {
        var result = false
        await poll(limit: limit) {
            let current = locked { phase }
            result = current.isConnected
            return result || current == .failed
        }
        return result
    }

    /// 手机：发确认，等 Mac 回应。
    func verify(keys: RemoteDatagramKeys, limit: Duration = verifyLimit) async -> Bool {
        locked {
            checkCipher = RemoteDatagramCipher(control: keys)
            answersChecks = false
            confirmed = false
        }
        // 每 100 ms 发一次（确认包可能丢），每 10 ms 看一眼回应到了没有：以前发完就睡 100 ms，回应 20 ms 就到了
        // 也要等满 100 ms 才发现。
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        var nextSend = clock.now
        while clock.now < deadline, !Task.isCancelled {
            if locked({ confirmed }) { return true }
            if clock.now >= nextSend {
                sendCheck()
                nextSend = clock.now + Self.checkResend
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return locked { confirmed }
    }

    /// 路径确认包多久重发一次。
    static let checkResend: Duration = .milliseconds(100)

    /// Mac：等手机发来带认证的确认。收到就回应，并一直回应它后面的重发。
    func waitForCheck(keys: RemoteDatagramKeys, limit: Duration = hostWaitLimit) async -> Bool {
        locked {
            checkCipher = RemoteDatagramCipher(control: keys)
            answersChecks = true
            confirmed = false
        }
        await poll(limit: limit) { locked { confirmed } }
        return locked { confirmed }
    }

    /// 路径确认过了，接上业务。之后 agent 的生死归传输层。
    func makeTransport(keys: RemoteDatagramKeys) -> RemoteP2PTransport? {
        let taken: RemoteICEAgent? = locked {
            guard let agent, !handedOff else { return nil }
            handedOff = true
            return agent
        }
        guard let taken else { return nil }
        return RemoteP2PTransport(path: RemoteICEDatagramPath(agent: taken, handlers: pathHandlers), keys: keys)
    }

    private func poll(limit: Duration, until done: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !done(), clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func record(phase newPhase: RemoteICEAgent.Phase) {
        locked {
            phase = newPhase
            if newPhase.isConnected, connectedAt == nil { connectedAt = .now }
        }
    }

    private func recordGatheringDone() {
        locked { gatheringDone = true }
    }

    private func sendCheck() {
        // 填满到业务包的大小：有的路径小包能过、大包被丢，那种路径不能算通。
        let padding = Data(count: RemoteP2PTransport.datagramBytes - RemoteDatagramCipher.overhead)
        let (agent, sealed): (RemoteICEAgent?, Data?) = locked { (self.agent, checkCipher?.seal(.pathCheck, padding)) }
        if let agent, let sealed { _ = agent.send(sealed) }
    }

    private func receiveCheck(_ datagram: Data) {
        let authentic = locked { checkCipher?.open(datagram)?.kind == .pathCheck }
        guard authentic else { return }
        let answers = locked {
            confirmed = true
            return answersChecks
        }
        if answers { sendCheck() }
    }

    private func locked<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
