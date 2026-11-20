import BackgroundTasks
import Foundation

/// iOS 26 的「后台继续处理」（`BGContinuedProcessingTask`）的一次租用：提交、等系统交来任务、汇报进度、交还。
/// 并行执行（`ParallelBackgroundKeeper`）与终端后台保持（`TerminalKeepAlive`）共用。
///
/// 规矩（系统定的）：
/// - 只能在前台、由用户操作触发时提交；
/// - 必须持续汇报进度，看起来卡住的会先被收回；
/// - 用户可以在灵动岛 / 锁屏上点停止，系统资源紧张时也会收回（`onExpire`）；
/// - 用户在 App 切换器里划掉 App，任务直接没了，不会有回调。
@available(iOS 26.0, *)
@MainActor
final class ContinuedProcessingLease {
    /// Info.plist 的 `BGTaskSchedulerPermittedIdentifiers` 里登记的通配前缀（如 `<bundle id>.parallel.`）。
    /// 每次提交用一个新后缀：同一个标识只能注册一次，重复注册系统会杀掉 App。
    private let identifierPrefix: String
    private var task: BGContinuedProcessingTask?
    /// 已提交、系统还没开始跑的标识（提交与启动之间不要重复提交）。
    private var pendingIdentifier: String?

    /// 系统开始跑（交来了任务对象）。
    var onStart: () -> Void = {}
    /// 系统收回了（用户点了停止、或资源紧张）。之后租用回到空闲，可以再提交。
    var onExpire: () -> Void = {}

    init(identifierPrefix: String) {
        self.identifierPrefix = identifierPrefix
    }

    /// 系统已经交来任务、正在跑。
    var isRunning: Bool { task != nil }
    /// 正在跑或已提交在等。
    var isHeld: Bool { task != nil || pendingIdentifier != nil }

    /// 提交一个现在就跑的任务（`strategy = .fail`：现在跑不了就不排队）。已经有了就沿用。
    /// 返回 false：Info.plist 没登记这个前缀，或者系统现在不让跑。
    @discardableResult
    func submit(title: String, subtitle: String) -> Bool {
        guard !isHeld else { return true }
        let identifier = identifierPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil,
            launchHandler: ContinuedProcessingHandlers.launchHandler { [weak self] (task: BGTask) in
                guard let task = task as? BGContinuedProcessingTask else { return }
                self?.adopt(task, identifier: identifier)
            })
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            pendingIdentifier = identifier
            return true
        } catch {
            return false
        }
    }

    /// 汇报进度与标题。系统还没交来任务时什么也不做。
    func report(total: Int64, completed: Int64, title: String, subtitle: String) {
        guard let task else { return }
        task.progress.totalUnitCount = max(total, 1)
        task.progress.completedUnitCount = min(max(completed, 0), task.progress.totalUnitCount)
        task.updateTitle(title, subtitle: subtitle)
    }

    /// 做完了：进度记满、交还。没在跑就只撤掉排队的。
    func finish() {
        pendingIdentifier = nil
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
        }
        task = nil
    }

    private func adopt(_ task: BGContinuedProcessingTask, identifier: String) {
        guard identifier == pendingIdentifier else {
            task.setTaskCompleted(success: true)   // 过期的提交（早就不需要了）
            return
        }
        pendingIdentifier = nil
        self.task = task
        task.expirationHandler = ContinuedProcessingHandlers.expirationHandler { [weak self] in self?.expire() }
        onStart()
    }

    private func expire() {
        task?.setTaskCompleted(success: false)
        task = nil
        onExpire()
    }
}

/// 交给系统的回调。系统在自己的队列上调它们，所以必须在 nonisolated 的地方建（见下）。
/// 不挂可用性标注：测试在任何系统上都能直接核。
nonisolated enum ContinuedProcessingHandlers {
    /// 系统的启动回调：`using: nil` 时系统在自己的后台队列上调它。必须在 nonisolated 的地方建——在 `@MainActor` 的方法里
    /// 直接写闭包，Swift 会把它推断成主线程隔离、进入时检查执行者，系统一启动任务就崩（同远程桌面声音的播放回调，ebd13a48）。
    /// 任务对象只在主线程上用：包一层带回主线程再交给 `adopt`。
    nonisolated static func launchHandler<Handle>(_ adopt: @escaping @MainActor @Sendable (Handle) -> Void)
        -> (Handle) -> Void {
        { task in
            let handed = UncheckedSendable(task)
            Task { @MainActor in adopt(handed.value) }
        }
    }

    /// 过期回调同理：系统在自己的队列上调。
    nonisolated static func expirationHandler(_ body: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        { Task { @MainActor in body() } }
    }
}

/// 把系统交来的非 Sendable 对象带过线程边界（之后只在主线程上用）。
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
