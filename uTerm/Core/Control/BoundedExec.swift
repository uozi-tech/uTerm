import Foundation

/// 一次有界执行的归类结果：跑出结果 / 抛错（连接 / 认证失败，带原因）/ 超时。
///
/// `failed` 里带的是**已包装的** `BoundedExecFailure`：原始错误对象不保证 `Sendable`，
/// 而结果要跨隔离域返回，所以在闸门里就把它连同可读文案一起装箱。
nonisolated enum BoundedOutcome<Success: Sendable>: Sendable {
    case completed(Success)
    case failed(BoundedExecFailure)
    /// 超时。**被执行的操作可能还在远端跑**（见 `BoundedExec`）。
    case timedOut

    /// 成功值；失败与超时都是 nil。
    var value: Success? {
        if case .completed(let value) = self { return value }
        return nil
    }

    var timedOut: Bool {
        if case .timedOut = self { return true }
        return false
    }

    /// 失败原因的可读文案（`FriendlyError.describe`）；成功与超时为 nil。
    var errorText: String? {
        if case .failed(let failure) = self { return failure.text }
        return nil
    }
}

/// 把任意错误装箱成 `Sendable`。箱子只读（构造后不再改），故 `@unchecked` 是安全的 ——
/// 这么做是因为 `any Error` 不是 `Sendable`，而 `BoundedOutcome` 要跨隔离域返回。
nonisolated struct BoundedExecFailure: Error, @unchecked Sendable {
    let underlying: any Error
    /// 面向用户的中文描述（构造时算好，避免在别的隔离域再碰原始错误）。
    let text: String

    init(_ error: any Error) {
        underlying = error
        text = FriendlyError.describe(error)
    }
}

/// 「不可取消的远端调用 + 超时」的通用外壳。
///
/// 存在的理由：Citadel 的 exec **不可取消**。任何 `withTaskGroup { await exec() }` 的
/// 写法都会被 `tail -f` 这类命令挂死整个任务组 —— 结构化并发在这里帮不上忙。
/// 唯一可行的形态是「非结构化 Task + 一次性闸门」：超时先返回、把还在跑的 Task 放手，
/// 结果晚到时由闸门丢弃。**超时返回后命令可能还在远端跑**，调用方与技能文档都要写明。
///
/// 三处共用：`QuickCommandRunner`（快捷命令并行执行）、`ParallelRunModel`（并行执行窗口）、
/// `ControlHandler+Run`（CLI 的 `run` / `run-many` / `quick-run`）。
nonisolated enum BoundedExec {

    /// 跑 `body`，超过 `timeout` 即**放弃等待**并返回 `.timedOut`；晚到的结果被闸门丢弃
    /// （既不崩也不泄漏 —— 那个 Task 自己跑完就结束了）。
    static func run<Success: Sendable>(
        timeout: Duration,
        _ body: @escaping @Sendable () async throws -> Success
    ) async -> BoundedOutcome<Success> {
        let gate = OneShotGate<Success>()
        _ = Task<Void, Never> {
            do { await gate.deliver(.completed(try await body())) }
            catch { await gate.deliver(.failed(BoundedExecFailure(error))) }
        }
        let timer = Task<Void, Never> {
            try? await Task.sleep(for: timeout)
            await gate.deliver(.timedOut)
        }
        let outcome = await gate.wait()
        // body 赢则停掉定时器；body 输（超时）则任其后台跑完，**不** await。
        timer.cancel()
        return outcome
    }

    /// 一次性闸门：body 与超时谁先到谁定结果，另一个被忽略。
    private actor OneShotGate<Success: Sendable> {
        private var delivered = false
        private var stored: BoundedOutcome<Success>?
        private var waiter: CheckedContinuation<BoundedOutcome<Success>, Never>?

        func deliver(_ value: BoundedOutcome<Success>) {
            guard !delivered else { return }
            delivered = true
            if let waiter {
                waiter.resume(returning: value)
                self.waiter = nil
            } else {
                stored = value
            }
        }

        func wait() async -> BoundedOutcome<Success> {
            if let stored { return stored }
            return await withCheckedContinuation { waiter = $0 }
        }
    }
}
