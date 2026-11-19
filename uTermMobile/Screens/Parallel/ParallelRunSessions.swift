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
    /// iOS 26 的 `ContinuedProcessingLease`（类型擦除，免得整个类挂可用性标注）。
    private var leaseStorage: AnyObject?
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
        if #available(iOS 26.0, *), lease.isRunning {
            let (total, done) = Self.units(running)
            // 单调不减：重新运行 / 新开一批会让「完成量」回落，回落不报（系统按「没进展」算会收回任务）。
            reported = min(total, max(reported, done))
            let first = running[0]
            let title = running.count == 1 ? first.title : "\(first.title) 等 \(running.count) 个"
            lease.report(total: total, completed: reported, title: title, subtitle: first.progressText)
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
        if #available(iOS 26.0, *) { lease.finish() }
        endLegacyTask()
    }

    // MARK: iOS 26：系统后台继续处理

    @available(iOS 26.0, *)
    private var lease: ContinuedProcessingLease {
        if let lease = leaseStorage as? ContinuedProcessingLease { return lease }
        let lease = ContinuedProcessingLease(identifierPrefix: Self.identifierPrefix)
        lease.onStart = { [weak self] in
            guard let self else { return }
            if !self.tick() { self.finish() }
        }
        // 系统收回（用户在灵动岛上点了停止、或资源紧张）：运行本身跟着 App 挂起。
        lease.onExpire = {}
        leaseStorage = lease
        return lease
    }

    @available(iOS 26.0, *)
    private func submitContinuedTask(title: String) {
        // 已经有一个在跑 / 在排队：沿用，标题由 tick 更新。现在跑不了：退到后台时走 beginBackgroundTask。
        lease.submit(title: title, subtitle: "准备中…")
    }

    // MARK: 兜底：beginBackgroundTask

    private var continuedRunning: Bool {
        if #available(iOS 26.0, *) { return lease.isRunning }
        return false
    }

    private func didEnterBackground() {
        guard !continuedRunning, legacyTask == .invalid, sessions().contains(where: \.isRunning) else { return }
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
