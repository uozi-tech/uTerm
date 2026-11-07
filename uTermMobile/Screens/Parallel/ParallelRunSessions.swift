import BackgroundTasks
import SwiftUI
import UIKit
import UserNotifications

/// 一次并行执行。由 `MobileStore` 持有（而不是全屏页的 `@State`）：关掉全屏页运行照常继续，
/// 之后从标签栏上方的「正在运行」条回到这一次，看到的是同一个控制器、同一份进度。
@MainActor
@Observable
final class ParallelRunSession: Identifiable {
    let id = UUID()
    let request: ParallelRunRequest
    /// 全屏页第一次出现时造好交回来（造控制器要用页面里的 `@Query` 主机与 provider）。
    var controller: ParallelRunController?
    /// 完成通知已经发过（App 不在前台时跑完才发，一次运行只发一次）。
    var notified = false

    init(request: ParallelRunRequest) {
        self.request = request
    }

    /// 还在跑：控制器还没造好也算（全屏页马上会造）。
    var isRunning: Bool { controller.map { !$0.allDone } ?? true }

    var title: String { controller?.commandName ?? request.name }

    /// 一句话进度：「完成 3/12 · 1 失败」。
    var progressText: String {
        guard let c = controller else { return "准备中…" }
        var s = "完成 \(c.doneCount)/\(c.total)"
        if c.failedCount > 0 { s += " · \(c.failedCount) 失败" }
        return s
    }
}

/// 切到别的 App 后让并行执行继续跑。
///
/// - iOS 26 起：用户点「运行」时（必须在前台、由用户操作触发）提交一个
///   `BGContinuedProcessingTask`。系统在锁屏 / 灵动岛显示进度，App 退到后台也继续跑，
///   直到所有运行落定再交还。这类任务**必须持续汇报进度**，看起来卡住会被系统提前收回，
///   所以每秒按各台进展推一次进度（单调不减）。
/// - 更早的系统 / 提交失败：退到后台时 `beginBackgroundTask`，系统给的时间（约 30 秒）用完就挂起。
/// - 跑完时 App 不在前台：发一条本地通知（静默授权，不弹授权框）。
@MainActor
final class ParallelBackgroundKeeper {
    /// Info.plist 的 `BGTaskSchedulerPermittedIdentifiers` 里登记的是 `com.uozi.uTerm.parallel.*`；
    /// 每次提交用一个新后缀（同一标识只能注册一次，重复注册系统会杀掉 App）。
    nonisolated static let identifierPrefix = "com.uozi.uTerm.parallel."

    private let sessions: () -> [ParallelRunSession]
    /// iOS 26 的 `BGContinuedProcessingTask`（类型擦除，免得整个类挂可用性标注）。
    private var continued: AnyObject?
    /// 已提交、系统还没开始跑的标识（提交与启动之间不要重复提交）。
    private var pendingIdentifier: String?
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    private var ticker: Task<Void, Never>?
    private var reported: Int64 = 0
    private var observers: [NSObjectProtocol] = []

    init(sessions: @escaping () -> [ParallelRunSession]) {
        self.sessions = sessions
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endLegacyTask() }
            },
        ]
    }

    /// 用户刚点了「运行」（前台）。
    func runStarted(title: String) {
        if #available(iOS 26.0, *) { submitContinuedTask(title: title) }
        startTicker()
    }

    // MARK: 进度

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.tick() { break }
                // 进度一秒一推就够，不需要准点：给 250 ms 余量，系统可以把这次唤醒和别的定时器并在一起。
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
            }
        }
    }

    /// 推一次进度、发该发的完成通知。返回是否还有在跑的。
    private func tick() -> Bool {
        let all = sessions()
        notifyFinished(all)
        let running = all.filter(\.isRunning)
        guard !running.isEmpty else {
            finish()
            return false
        }
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            let (total, done) = Self.units(running)
            task.progress.totalUnitCount = total
            // 单调不减：重新运行 / 新开一批会让「完成量」回落，回落不报（系统按「没进展」算会收回任务）。
            reported = min(total, max(reported, done))
            task.progress.completedUnitCount = reported
            let first = running[0]
            let title = running.count == 1 ? first.title : "\(first.title) 等 \(running.count) 个"
            task.updateTitle(title, subtitle: first.progressText)
        }
        return true
    }

    /// 进度单位：每台 100 份。落定的台记满；在跑的台按已执行的步数 / 输出行数给一点，最多 80，
    /// 免得一条命令跑好几分钟时进度纹丝不动、被系统当成卡住。
    static func units(_ running: [ParallelRunSession]) -> (total: Int64, done: Int64) {
        var total: Int64 = 0
        var done: Int64 = 0
        for session in running {
            guard let c = session.controller else { total += 100; continue }
            for s in c.states {
                total += 100
                if s.tone != .running {
                    done += 100
                } else {
                    done += Int64(min(80, s.agentSteps.count * 10 + s.lines.count / 10))
                }
            }
        }
        return (max(total, 1), done)
    }

    private func finish() {
        ticker?.cancel()
        ticker = nil
        reported = 0
        pendingIdentifier = nil
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
        }
        continued = nil
        endLegacyTask()
    }

    // MARK: iOS 26：系统后台继续处理

    @available(iOS 26.0, *)
    private func submitContinuedTask(title: String) {
        // 已经有一个在跑 / 在排队：沿用，标题由 tick 更新。
        guard continued == nil, pendingIdentifier == nil else { return }
        let identifier = Self.identifierPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            // 启动回调在系统的后台队列上；任务对象只在主线程上用，包一层带过去。
            let handed = UncheckedSendable(task)
            Task { @MainActor in
                guard let task = handed.value as? BGContinuedProcessingTask else { return }
                self?.adopt(task, identifier: identifier)
            }
        }
        guard registered else { return }   // Info.plist 没登记：退回 beginBackgroundTask
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "准备中…")
        request.strategy = .fail   // 现在跑不了就别排队：排到后面时运行早已结束
        do {
            try BGTaskScheduler.shared.submit(request)
            pendingIdentifier = identifier
        } catch {
            // 系统现在不让跑（负载高等）：退到后台时走 beginBackgroundTask。
        }
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask, identifier: String) {
        guard identifier == pendingIdentifier else {
            task.setTaskCompleted(success: true)   // 过期的提交（运行早结束了）
            return
        }
        pendingIdentifier = nil
        continued = task
        task.expirationHandler = { [weak self] in
            // 系统收回（用户在灵动岛上点了停止、或资源紧张）：交还任务，运行本身跟着 App 挂起。
            Task { @MainActor in
                guard let self else { return }
                if let t = self.continued as? BGContinuedProcessingTask {
                    t.setTaskCompleted(success: false)
                }
                self.continued = nil
            }
        }
        if !tick() { finish() }
    }

    // MARK: 兜底：beginBackgroundTask

    private func didEnterBackground() {
        guard continued == nil, legacyTask == .invalid, sessions().contains(where: \.isRunning) else { return }
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "Parallel run") { [weak self] in
            MainActor.assumeIsolated { self?.endLegacyTask() }
        }
    }

    private func endLegacyTask() {
        guard legacyTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacyTask)
        legacyTask = .invalid
    }

    // MARK: 完成通知

    /// App 不在前台时跑完的运行，各发一条本地通知。
    private func notifyFinished(_ all: [ParallelRunSession]) {
        let inForeground = UIApplication.shared.applicationState == .active
        for session in all where !session.isRunning && !session.notified {
            session.notified = true
            guard !inForeground, let c = session.controller else { continue }
            let content = UNMutableNotificationContent()
            content.title = c.commandName
            content.body = c.failedCount == 0
                ? "\(c.total) 台全部执行成功。"
                : "\(c.total) 台中 \(c.total - c.failedCount) 台成功，\(c.failedCount) 台失败。"
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "parallel-\(session.id)", content: content, trigger: nil))
        }
    }

    /// 静默授权（`.provisional`）：不弹框，通知安静地进通知中心；用户之后可以在那里改成正常提醒。
    static func requestProvisionalNotifications() {
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .provisional])
        }
    }
}

/// 把系统交来的非 Sendable 对象带过线程边界（之后只在主线程上用）。
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
