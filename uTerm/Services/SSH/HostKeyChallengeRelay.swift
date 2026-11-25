import Foundation

/// host-key 审批的 UI 桥接：把 SSH 层异步的 host-key 挑战转成一个驱动 sheet 的
/// `pendingChallenge`，并在用户裁决后 resume 挂起的连接任务。
///
/// 由 `PaneModel` / `FileBrowserModel` / 端口转发窗口 / iOS 根视图等共用。iOS 全 App 只有一个 relay，
/// 几个标签可能同时在问，所以问题**排队**（一次弹一个），而不是新的顶掉旧的：以前被顶掉的那一问按「拒绝」
/// 结束，那个连接就停在「要用户处理」、不再自动重试，可用户根本没看到它。问的是同一件事（`coalescingKey`
/// 相同：同一台主机同一把钥匙，或同一台主机的加密方式）时并成一问，一次回答给所有在等的。
///
/// 询问响应取消：等回答的连接任务被取消（关标签、超时），它那一份立刻按「没人回答」（`HostKeyAbandonment`）
/// 结束、从队列里撤掉，不会把连接挂住；一问里所有人都走了，弹层也随之撤掉。
///
/// 续延正确性：每个等待者恰好被 resume 一次——用户裁决（`resolve`，整问一起）、自己被取消（`cancel`）、
/// 持有者 `abandon`、`self` 已释放。都是先从队列里摘掉再 resume，双重 resume 结构上不可能。
@MainActor
@Observable
final class HostKeyChallengeRelay {
    /// 待用户裁决的主机密钥挑战（驱动视图层的 sheet）：队首那一问。
    var pendingChallenge: HostKeyChallenge?
    /// 这个 relay 背后有没有人会回答。命令行 `forward-start` 的一次性 relay 是 false：请求一结束就没人轮询它，
    /// 后台重连不能把问题投到它上面（`ForwardingCoordinator` 据此改用界面的 relay 或直接拒绝）。
    let isInteractive: Bool

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct Ask {
        let challenge: HostKeyChallenge
        var waiters: [Waiter]
    }

    @ObservationIgnored private var queue: [Ask] = []
    /// 取消比入队先到的那几个（取消处理与入队是两个主线程任务，先后没有保证）。
    @ObservationIgnored private var cancelledBeforeQueued: Set<UUID> = []

    init(interactive: Bool = true) {
        isInteractive = interactive
    }

    /// host-key sheet 的裁决出口：回答队首那一问（并在它上面的每个等待者），然后亮出下一问。
    func resolve(_ trusted: Bool) {
        guard !queue.isEmpty else { return }
        let ask = queue.removeFirst()
        pendingChallenge = queue.first?.challenge
        for waiter in ask.waiters { waiter.continuation.resume(returning: trusted) }
    }

    /// 持有者被关掉（标签 / 窗口 dispose）：挂着的挑战全部按「拒绝」结束，但记成「没人回答」而不是用户拒绝——
    /// 别的标签合并在这次询问上时（`HostKeyApprovalCoalescer`）要重新问，不能跟着失败。
    func abandon() {
        let asks = queue
        queue = []
        pendingChallenge = nil
        for ask in asks {
            for waiter in ask.waiters {
                HostKeyAbandonment.mark(waiter.id)
                waiter.continuation.resume(returning: false)
            }
        }
    }

    /// 构造交给 SSH 层的 host-key 审批闭包。`@Sendable`：跨隔离域传给连接任务。
    func makeApprover() -> @Sendable (HostKeyChallenge) async -> Bool {
        { [weak self] challenge in
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    Task { @MainActor in
                        guard let self else { continuation.resume(returning: false); return }
                        self.enqueue(challenge, continuation)
                    }
                }
            } onCancel: {
                Task { @MainActor in self?.cancel(challenge.id) }
            }
        }
    }

    private func enqueue(_ challenge: HostKeyChallenge, _ continuation: CheckedContinuation<Bool, Never>) {
        if cancelledBeforeQueued.remove(challenge.id) != nil {
            HostKeyAbandonment.mark(challenge.id)
            continuation.resume(returning: false)
            return
        }
        let waiter = Waiter(id: challenge.id, continuation: continuation)
        if let index = queue.firstIndex(where: { $0.challenge.coalescingKey == challenge.coalescingKey }) {
            queue[index].waiters.append(waiter)
        } else {
            queue.append(Ask(challenge: challenge, waiters: [waiter]))
        }
        pendingChallenge = queue.first?.challenge
    }

    /// 某个等待者的连接任务被取消：只撤它这一份（记成没人回答）；一问里没人等了就整问撤掉。
    private func cancel(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.waiters.contains { $0.id == id } }) else {
            cancelledBeforeQueued.insert(id)
            return
        }
        let waiterIndex = queue[index].waiters.firstIndex { $0.id == id }!
        let waiter = queue[index].waiters.remove(at: waiterIndex)
        if queue[index].waiters.isEmpty { queue.remove(at: index) }
        pendingChallenge = queue.first?.challenge
        HostKeyAbandonment.mark(waiter.id)
        waiter.continuation.resume(returning: false)
    }
}

/// 被 `abandon()` 结束的挑战。只活到合并器取走为止。
nonisolated enum HostKeyAbandonment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var abandoned: Set<UUID> = []

    static func mark(_ id: UUID) {
        lock.withLock { _ = abandoned.insert(id) }
    }

    /// 取走并返回这次挑战是不是被放弃的。
    static func take(_ id: UUID) -> Bool {
        lock.withLock { abandoned.remove(id) != nil }
    }
}

/// 同时打开同一台新主机的几个标签，每个都各握一次手，但只问用户一次：一个窗口同时只能弹一个 sheet，
/// 后来的弹不出来，那个标签就永远卡在「连接中」。Mac 的保持终端（`HeldSSHBackend`）问主机密钥、两端的
/// `LegacyAlgorithmGate` 问加密方式都经它。
///
/// 响应取消：等着的连接任务被取消时，它那一份立刻按「拒绝」返回（不等别人那一问）；一问里所有人都走了，
/// 正在问的那个审批任务也被取消（relay 随之撤掉弹层）。问的那个标签关掉了（「没人回答」）时，还在等的重新问。
actor HostKeyApprovalCoalescer {
    static let shared = HostKeyApprovalCoalescer()

    private enum Outcome { case approved, rejected, abandoned }

    /// 只在 actor 上读写；`@unchecked Sendable` 是为了让取消处理（不在 actor 上）能把它带回 actor。
    private final class Ask: @unchecked Sendable {
        let token = UUID()
        var task: Task<Void, Never>?
        var outcome: Outcome?
        var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]
    }

    private var inFlight: [String: Ask] = [:]

    func approve(_ challenge: HostKeyChallenge, approver: @escaping @Sendable (HostKeyChallenge) async -> Bool) async -> Bool {
        let key = challenge.coalescingKey
        while !Task.isCancelled {
            let ask = inFlight[key] ?? start(key, challenge, approver)
            let waiterID = UUID()
            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                    if let outcome = ask.outcome {
                        continuation.resume(returning: outcome)
                    } else {
                        ask.waiters[waiterID] = continuation
                    }
                }
            } onCancel: {
                Task { await self.leave(key, ask, waiterID) }
            }
            switch outcome {
            case .approved: return true
            case .rejected: return false
            // 问的那个标签关掉了，用户没回答：由还在等的重新问（自己被取消的话循环条件会挡住）。
            case .abandoned: continue
            }
        }
        return false
    }

    private func start(_ key: String, _ challenge: HostKeyChallenge,
                       _ approver: @escaping @Sendable (HostKeyChallenge) async -> Bool) -> Ask {
        let ask = Ask()
        inFlight[key] = ask
        ask.task = Task {
            let approved = await approver(challenge)
            let outcome: Outcome = approved ? .approved : (HostKeyAbandonment.take(challenge.id) ? .abandoned : .rejected)
            self.finish(key, ask, outcome)
        }
        return ask
    }

    private func finish(_ key: String, _ ask: Ask, _ outcome: Outcome) {
        if inFlight[key]?.token == ask.token { inFlight[key] = nil }
        ask.outcome = outcome
        let waiters = ask.waiters
        ask.waiters = [:]
        for continuation in waiters.values { continuation.resume(returning: outcome) }
    }

    /// 一个等待者被取消：它那一份按「没人回答」立刻返回；没人等了就取消这次询问。
    private func leave(_ key: String, _ ask: Ask, _ waiterID: UUID) {
        guard let continuation = ask.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: .abandoned)
        if ask.waiters.isEmpty, ask.outcome == nil {
            if inFlight[key]?.token == ask.token { inFlight[key] = nil }
            ask.task?.cancel()
        }
    }
}
