import Synchronization
import XCTest
@testable import uTerm

/// 主机密钥 / 连接方式的询问不会把连接挂住：等回答的连接任务被取消（关标签、端口转发超时）时立刻返回，
/// 几个标签同时在问时排队而不是新的顶掉旧的（被顶掉的那一问以前按「拒绝」结束，连接就停在「要用户处理」）。
/// 等不到就算挂住：返回 nil。到点就回来，不管 `task` 还挂不挂着（`Task.value` 不响应取消，放进任务组会把组一起挂住）。
private func finished<T: Sendable>(_ task: Task<T, Never>, within seconds: Double = 2) async -> T? {
    let slot = Mutex<CheckedContinuation<T?, Never>?>(nil)
    @Sendable func deliver(_ value: T?) {
        slot.withLock { continuation in
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
    return await withCheckedContinuation { continuation in
        slot.withLock { $0 = continuation }
        Task { deliver(await task.value) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            deliver(nil)
        }
    }
}

@MainActor
final class HostKeyChallengeRelayTests: XCTestCase {

    private func challenge(_ host: String = "192.0.2.40", fingerprint: String = "SHA256:aaa",
                           kind: HostKeyChallenge.Kind = .unknown) -> HostKeyChallenge {
        HostKeyChallenge(host: host, port: 22, kind: kind, newFingerprint: fingerprint, oldFingerprint: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待超时")
    }

    // MARK: - relay

    func testCancellingTheWaitingTaskReturnsAtOnceAndWithdrawsTheSheet() async {
        let relay = HostKeyChallengeRelay()
        let approver = relay.makeApprover()
        let asked = challenge()
        let task = Task { await approver(asked) }
        await waitUntil { relay.pendingChallenge != nil }

        task.cancel()
        let result = await finished(task)
        XCTAssertEqual(result, false, "取消后应立刻按「没人回答」返回")
        XCTAssertNil(relay.pendingChallenge, "没人等了，弹层要撤掉")
        XCTAssertTrue(HostKeyAbandonment.take(asked.id), "被取消算没人回答，不算用户拒绝")
    }

    func testTaskCancelledBeforeAskingNeverShowsASheet() async {
        let relay = HostKeyChallengeRelay()
        let approver = relay.makeApprover()
        let asked = challenge()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await approver(asked)
        }
        let result = await finished(task)
        XCTAssertEqual(result, false)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(relay.pendingChallenge, "先到的取消不能让问题之后又冒出来")
        _ = HostKeyAbandonment.take(asked.id)
    }

    func testASecondAskQueuesBehindTheFirstInsteadOfDisplacingIt() async {
        let relay = HostKeyChallengeRelay()
        let approver = relay.makeApprover()
        let first = challenge("192.0.2.41")
        let second = challenge("192.0.2.42")
        let a = Task { await approver(first) }
        await waitUntil { relay.pendingChallenge?.id == first.id }
        let b = Task { await approver(second) }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(relay.pendingChallenge?.id, first.id, "后来的不能顶掉还在问的")

        relay.resolve(true)
        let firstResult = await finished(a)
        XCTAssertEqual(firstResult, true)
        await waitUntil { relay.pendingChallenge?.id == second.id }
        relay.resolve(false)
        let secondResult = await finished(b)
        XCTAssertEqual(secondResult, false)
        XCTAssertNil(relay.pendingChallenge)
    }

    func testAsksForTheSameThingShareOneAnswer() async {
        let relay = HostKeyChallengeRelay()
        let approver = relay.makeApprover()
        let a = Task { await approver(self.challenge(kind: .weakAlgorithms)) }
        let b = Task { await approver(self.challenge(kind: .weakAlgorithms)) }
        await waitUntil { relay.pendingChallenge != nil }
        try? await Task.sleep(for: .milliseconds(100))

        relay.resolve(true)
        let results = [await finished(a), await finished(b)]
        XCTAssertEqual(results, [true, true])
        XCTAssertNil(relay.pendingChallenge, "合并成一问，答一次就没了")
    }

    func testCancellingOneOfTwoMergedWaitersKeepsTheAskForTheOther() async {
        let relay = HostKeyChallengeRelay()
        let approver = relay.makeApprover()
        let a = Task { await approver(self.challenge()) }
        let b = Task { await approver(self.challenge()) }
        await waitUntil { relay.pendingChallenge != nil }
        try? await Task.sleep(for: .milliseconds(100))

        a.cancel()
        let cancelled = await finished(a)
        XCTAssertEqual(cancelled, false)
        XCTAssertNotNil(relay.pendingChallenge, "还有人在等，弹层不能撤")
        relay.resolve(true)
        let kept = await finished(b)
        XCTAssertEqual(kept, true)
    }

    // MARK: - 合并器

    func testCoalescedWaitersReturnWhenCancelledAndTheAskIsWithdrawn() async {
        let relay = HostKeyChallengeRelay()
        let coalescer = HostKeyApprovalCoalescer()
        let approver = relay.makeApprover()
        let asked = challenge(kind: .weakAlgorithms)
        let a = Task { await coalescer.approve(asked, approver: approver) }
        let b = Task { await coalescer.approve(asked, approver: approver) }
        await waitUntil { relay.pendingChallenge != nil }

        a.cancel()
        let first = await finished(a)
        XCTAssertEqual(first, false, "被取消的等待者不能等别人那一问")
        XCTAssertNotNil(relay.pendingChallenge, "另一个还在等")

        b.cancel()
        let second = await finished(b)
        XCTAssertEqual(second, false)
        await waitUntil { relay.pendingChallenge == nil }
    }

    func testCoalescedWaiterStillGetsTheAnswerAfterAnotherLeaves() async {
        let relay = HostKeyChallengeRelay()
        let coalescer = HostKeyApprovalCoalescer()
        let approver = relay.makeApprover()
        let asked = challenge()
        let a = Task { await coalescer.approve(asked, approver: approver) }
        await waitUntil { relay.pendingChallenge != nil }
        let b = Task { await coalescer.approve(asked, approver: approver) }
        try? await Task.sleep(for: .milliseconds(100))

        a.cancel()
        _ = await finished(a)
        relay.resolve(true)
        let kept = await finished(b)
        XCTAssertEqual(kept, true)
    }

    /// 问的那个持有者关掉了（标签关了：连接任务被取消、relay 被 abandon）：合并在上面的人重新问，而不是跟着失败。
    func testAbandonedAskIsAskedAgainForTheRemainingWaiter() async {
        let closing = HostKeyChallengeRelay()
        let staying = HostKeyChallengeRelay()
        let coalescer = HostKeyApprovalCoalescer()
        let asked = challenge()
        let a = Task { await coalescer.approve(asked, approver: closing.makeApprover()) }
        await waitUntil { closing.pendingChallenge != nil }
        let b = Task { await coalescer.approve(asked, approver: staying.makeApprover()) }
        try? await Task.sleep(for: .milliseconds(100))

        a.cancel()
        let left = await finished(a)
        XCTAssertEqual(left, false)
        XCTAssertNotNil(closing.pendingChallenge, "还有人在等这一问")
        closing.abandon()
        await waitUntil { staying.pendingChallenge != nil }
        staying.resolve(true)
        let kept = await finished(b)
        XCTAssertEqual(kept, true)
    }
}
