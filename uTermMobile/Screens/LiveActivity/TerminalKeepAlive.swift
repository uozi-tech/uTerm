import Foundation
import SwiftUI
import UserNotifications

/// 「离开后继续运行」：用户在前台点了之后，App 退到后台也继续跑一段时间（iOS 26 的 `BGContinuedProcessingTask`）。
/// 这段时间里 SSH 连接不断、影子终端照常解析，程序状态是实时的：灵动岛跟着变，Agent 卡住等人时能发通知。
///
/// 只保持整个 App，不分标签页：App 活着，所有连接都活着。
/// - 进度按时间算（已过 ÷ 选定时长）：终端没有天然的进度，系统又要求一直有进展，用时间最诚实，进度条就是「还剩多久」。
/// - 本来有程序在跑、现在都停了（完成 / 出错 / 空闲）满 `idleGrace` 就提前结束，不白耗电。一直没有程序在跑就保持到时间。
/// - 用户在灵动岛上点停止、系统收回、时间到、提前结束：之后回到普通后台（约 30 秒后挂起，主机上的会话由保持进程接着跑）。
@MainActor
@Observable
final class TerminalKeepAlive {
    /// Info.plist 的 `BGTaskSchedulerPermittedIdentifiers` 里登记的是 `$(UTERM_BUNDLE_ID).terminal.*`（必须以 bundle id 开头）。
    nonisolated static let identifierPrefix = (Bundle.main.bundleIdentifier ?? "com.uozi.uTerm") + ".terminal."
    /// 菜单里给的几档（分钟）。
    nonisolated static let durations = [15, 30, 60]
    /// 程序都停下之后再等多久结束。
    nonisolated static let idleGrace: TimeInterval = 60

    /// 保持到这个时刻。nil = 没在保持。
    private(set) var until: Date?

    /// 由 `TerminalActivityCenter` 提供：此刻有没有程序在跑或卡住等人，以及给系统进度条用的副标题。
    @ObservationIgnored var status: () -> (busy: Bool, subtitle: String) = { (false, "") }
    /// 开始 / 结束都告诉 `TerminalActivityCenter`（实时活动换底行、后台时该暂停了）。
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var auto = TerminalKeepAliveAutoEnd()
    /// `ContinuedProcessingLease`（类型擦除，免得整个类挂可用性标注）。
    @ObservationIgnored private var leaseStorage: AnyObject?

    /// 这台设备能用（iOS 26 起）。
    var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var isActive: Bool { until != nil }

    /// 系统已经交来任务、正在跑（测试用：提交成功不等于系统已经开始）。
    var isRunningInSystem: Bool {
        if #available(iOS 26.0, *) { return (leaseStorage as? ContinuedProcessingLease)?.isRunning ?? false }
        return false
    }

    /// 用户点了「离开后继续运行」（前台）。返回 false：系统现在不让跑。
    @discardableResult
    func start(minutes: Int, now: Date = Date()) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        Self.requestAlerts()
        let wasActive = isActive
        guard lease.submit(title: Self.title, subtitle: status().subtitle) else { return false }
        // 已经在保持时再选一档：从现在起重新算。
        startedAt = now
        until = now.addingTimeInterval(TimeInterval(minutes * 60))
        auto = TerminalKeepAliveAutoEnd()
        if !wasActive { startTicker() }
        tick(now: now)
        onChange()
        return true
    }

    /// 用户点了「停止后台保持」。
    func stop() {
        guard isActive else { return }
        if #available(iOS 26.0, *) { lease.finish() }
        ended()
    }

    // MARK: -

    private static var title: String { String(localized: "uTerm 终端后台保持") }

    @available(iOS 26.0, *)
    private var lease: ContinuedProcessingLease {
        if let lease = leaseStorage as? ContinuedProcessingLease { return lease }
        let lease = ContinuedProcessingLease(identifierPrefix: Self.identifierPrefix)
        lease.onStart = { [weak self] in
            AppLogger.notice("keep-alive: system started the task", category: TerminalActivityCenter.logCategory)
            #if DEBUG
            FileHandle.standardError.write(Data("[live-activity] keep-alive: system started the task\n".utf8))
            #endif
            self?.tick(now: Date())
        }
        // 用户在灵动岛上点了停止、或者系统收回。
        lease.onExpire = { [weak self] in self?.ended() }
        leaseStorage = lease
        return lease
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                // 进度一秒一推就够，不需要准点：给余量，系统可以把这次唤醒和别的定时器并在一起。
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
                guard let self, self.isActive else { return }
                self.tick(now: Date())
            }
        }
    }

    private func tick(now: Date) {
        guard let until, let startedAt else { return }
        let current = status()
        if now >= until || auto.shouldEnd(busy: current.busy, now: now) {
            if #available(iOS 26.0, *) { lease.finish() }
            ended()
            return
        }
        if #available(iOS 26.0, *) {
            let total = Int64(until.timeIntervalSince(startedAt))
            let elapsed = Int64(now.timeIntervalSince(startedAt))
            lease.report(total: total, completed: elapsed, title: Self.title, subtitle: current.subtitle)
        }
    }

    private func ended() {
        AppLogger.notice("keep-alive: ended", category: TerminalActivityCenter.logCategory)
        #if DEBUG
        FileHandle.standardError.write(Data("[live-activity] keep-alive: ended\n".utf8))
        #endif
        ticker?.cancel()
        ticker = nil
        until = nil
        startedAt = nil
        onChange()
    }

    /// 保持期间要靠通知叫人回来：这里请求正常的提醒（之前并行执行要过的是静默授权，通知不会弹出来）。
    /// 是用户点了菜单才问，系统弹框有上下文。
    private static func requestAlerts() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            AppLogger.notice("keep-alive: alerts authorized=\(granted)", category: TerminalActivityCenter.logCategory)
            #if DEBUG
            FileHandle.standardError.write(Data("[live-activity] keep-alive: alerts authorized=\(granted)\n".utf8))
            #endif
        }
    }
}

/// 「本来有程序在跑、现在都停了满一段时间」的判定。纯值，测试直接调。
nonisolated struct TerminalKeepAliveAutoEnd: Equatable, Sendable {
    private var sawBusy = false
    private var idleSince: Date?

    mutating func shouldEnd(busy: Bool, now: Date, grace: TimeInterval = TerminalKeepAlive.idleGrace) -> Bool {
        if busy {
            sawBusy = true
            idleSince = nil
            return false
        }
        guard sawBusy else { return false }
        let since = idleSince ?? now
        idleSince = since
        return now.timeIntervalSince(since) >= grace
    }
}

/// 终端标签页长按菜单里的一项：「离开后继续运行」▸ 15 分钟 / 30 分钟 / 1 小时；保持中换成「停止后台保持」。
struct TerminalKeepAliveMenu: View {
    let keepAlive: TerminalKeepAlive

    var body: some View {
        if let until = keepAlive.until {
            Button { keepAlive.stop() } label: {
                Label {
                    Text("停止后台保持（到 \(until.formatted(date: .omitted, time: .shortened))）")
                } icon: {
                    Image(systemName: "stop.circle")
                }
            }
        } else {
            // 子菜单也走 `MMenu`（`MMenuTintLintTests` 拦直接写的系统菜单）。
            MMenu {
                ForEach(TerminalKeepAlive.durations, id: \.self) { minutes in
                    Button(Self.label(minutes: minutes)) { keepAlive.start(minutes: minutes) }
                }
            } label: {
                Label("离开后继续运行", systemImage: "hourglass")
            }
        }
    }

    private static func label(minutes: Int) -> String {
        minutes % 60 == 0 ? String(localized: "\(minutes / 60) 小时") : String(localized: "\(minutes) 分钟")
    }
}
