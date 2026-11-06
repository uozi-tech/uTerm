import Foundation

/// host-key 审批的 UI 桥接：把 SSH 层异步的 host-key 挑战转成一个驱动 sheet 的
/// `pendingChallenge`，并在用户裁决后 resume 挂起的连接任务。
///
/// 由 `PaneModel` 与 `FileBrowserModel` 共用 —— 两者此前各自实现了一份完全相同的
/// `pendingChallenge` / `CheckedContinuation` / `resolve` / `approver` 逻辑。
///
/// 续延正确性：每条路径上 continuation 都恰好被 resume 一次 ——
/// 用户裁决（`resolve`）、被新挑战顶替（stale overwrite）、`self` 已释放、
/// 持有者 `dispose`（调用 `resolve(false)`）。读取并置空后再 resume，
/// 双重 resume 结构上不可能。
@MainActor
@Observable
final class HostKeyChallengeRelay {
    /// 待用户裁决的主机密钥挑战（驱动视图层的 sheet）。
    var pendingChallenge: HostKeyChallenge?
    private var challengeDecision: CheckedContinuation<Bool, Never>?

    /// host-key sheet 的裁决出口。读取并置空后再 resume —— 双重 resume 结构上不可能。
    func resolve(_ trusted: Bool) {
        guard let cont = challengeDecision else { return }
        challengeDecision = nil
        pendingChallenge = nil
        cont.resume(returning: trusted)
    }

    /// 持有者被关掉（标签 / 窗口 dispose）：挂着的挑战按「拒绝」结束，但记成「没人回答」而不是用户拒绝——
    /// 别的标签合并在这次询问上时（`HostKeyApprovalCoalescer`）要重新问，不能跟着失败。
    func abandon() {
        if let challenge = pendingChallenge { HostKeyAbandonment.mark(challenge.id) }
        resolve(false)
    }

    /// 构造交给 SSH 层的 host-key 审批闭包。`@Sendable`：跨隔离域传给连接任务。
    func makeApprover() -> @Sendable (HostKeyChallenge) async -> Bool {
        { [weak self] challenge in
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    guard let self else { cont.resume(returning: false); return }
                    if let stale = self.challengeDecision {
                        stale.resume(returning: false)
                    }
                    self.challengeDecision = cont
                    self.pendingChallenge = challenge
                }
            }
        }
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
