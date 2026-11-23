import ActivityKit
import SwiftUI
import UIKit
import UserNotifications

/// 终端状态上灵动岛和锁屏（实时活动），以及 App 在后台时的提醒。全 App 一个，由根视图持有并注入。
///
/// - 有标签页里的程序在报告状态（OSC 7501：运行中、等待确认、完成、出错）时才有实时活动，都没了就结束。
///   只开着普通 shell 不打扰。设置 › 终端里可以关掉。
/// - 没有推送，只靠 App 自己更新。ActivityKit 只允许在前台**发起**，所以条件一满足就在前台建好
///  （App 在前台时灵动岛本来就不显示，提前建没有副作用），进后台以后只更新、不新建。
/// - 进后台后 App 还能跑一小段（`MobileBackgroundGrace` 等），这段时间内容照常实时更新；快被挂起前推一次「已暂停」，
///   每次更新还带 `staleDate` 兜底（扩展把过期的内容按已暂停画）。「后台保持」（`TerminalKeepAlive`）期间一直实时。
/// - App 在后台、还在跑的时候，标签页变成等待确认 / 完成 / 出错，发一条本地通知，点开回到那个标签页。
@MainActor
@Observable
final class TerminalActivityCenter {
    let keepAlive = TerminalKeepAlive()
    /// 深链接或通知要打开的标签页。由 `TerminalActivityLinkHandler` 消费后清掉。
    var pendingOpen: TerminalOpenRequest?

    @ObservationIgnored private weak var workspace: MobileWorkspace?
    @ObservationIgnored private var activity: Activity<TerminalActivityAttributes>?
    /// 最后一次推出去的内容。
    @ObservationIgnored private var pushed: TerminalActivityAttributes.ContentState?
    /// 用户把实时活动划掉了：这一轮不再建，等它自然该结束（没有值得看的了）以后再说。
    @ObservationIgnored private var dismissedByUser = false
    @ObservationIgnored private var sinceBook = TerminalActivitySinceBook()
    @ObservationIgnored private var transitions = TerminalActivityTransitions()
    @ObservationIgnored private var entries: [TerminalActivityEntry] = []

    @ObservationIgnored private var inBackground = UIApplication.shared.applicationState == .background
    /// 快被挂起了，内容定格为「已暂停」。
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var pauseTimer: Task<Void, Never>?
    /// 进后台时自己要的一小段运行时间：保证来得及推「已暂停」。
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let notificationRouter = TerminalNotificationRouter()
    /// 系统给的后台时间还剩多少。App 里读 `UIApplication.shared.backgroundTimeRemaining`；
    /// 测试会话里系统不倒计时（一直读到「无限」），用例换成自己的数才走得到「快被挂起」那一段。
    @ObservationIgnored private let backgroundTimeRemaining: @MainActor () -> TimeInterval

    /// 提前多久推「已暂停」（系统给的后台时间用完前）。
    nonisolated static let pauseLead: TimeInterval = 5

    init(backgroundTimeRemaining: @escaping @MainActor () -> TimeInterval = {
        UIApplication.shared.backgroundTimeRemaining
    }) {
        self.backgroundTimeRemaining = backgroundTimeRemaining
    }

    func start(workspace: MobileWorkspace) {
        guard !started else { return }
        started = true
        self.workspace = workspace
        keepAlive.status = { [weak self] in self?.keepAliveStatus ?? (false, "") }
        keepAlive.onChange = { [weak self] in self?.keepAliveChanged() }
        notificationRouter.onOpen = { [weak self] url in self?.open(url) }
        UNUserNotificationCenter.current().delegate = notificationRouter

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willEnterForeground() }
            },
            // 设置里的开关。
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            },
        ]

        // 上次运行留下的（App 被系统结束时来不及收）：标签页早就不在了，先收掉再开始。
        Task {
            for leftover in Activity<TerminalActivityAttributes>.activities {
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
            refresh()
        }
    }

    /// `uterm://terminal/<id>`（灵动岛、锁屏）。不是终端链接返回 false。
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let tabID = TerminalActivityAttributes.tabID(from: url) else { return false }
        pendingOpen = TerminalOpenRequest(tabID: tabID)
        return true
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.mobileLiveActivity) as? Bool ?? true
    }

    // MARK: 观察工作区

    /// 读一遍各标签页的状态，并登记观察：读到的任何一项变了就再来一遍（合并成一次）。
    private func observe() {
        guard let workspace else { return }
        entries = withObservationTracking {
            Self.entries(in: workspace)
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    static func entries(in workspace: MobileWorkspace) -> [TerminalActivityEntry] {
        workspace.tabs.compactMap { tab in
            guard let terminal = tab.terminal, let status = terminal.programStatus else { return nil }
            return TerminalActivityEntry(tabID: terminal.id, title: tab.title, host: tab.hostName, status: status)
        }
    }

    private func scheduleRefresh() {
        guard started, !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            // 标题、状态常常一串一串地变（一条命令跑完标题和状态各变一次）：并成一次推。
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        observe()
        let now = Date()
        sinceBook.update(entries, now: now)
        // 提醒不归设置里那个开关管：它关的是灵动岛和锁屏。
        let fresh = transitions.update(entries, notify: inBackground && !paused, now: now)
        for entry in fresh { Self.postNotification(for: entry) }

        guard Self.isEnabled else { return end() }
        let content = TerminalActivityContent.make(entries: entries, since: sinceBook.since, phase: phase, now: now)
        apply(content)
    }

    private var phase: TerminalActivityPhase {
        if paused { return .paused }
        if let until = keepAlive.until { return .keeping(until: until) }
        return .live
    }

    // MARK: 实时活动

    private func apply(_ content: TerminalActivityAttributes.ContentState?) {
        if let activity, activity.activityState == .dismissed || activity.activityState == .ended {
            // 用户在锁屏上划掉了。
            self.activity = nil
            pushed = nil
            dismissedByUser = activity.activityState == .dismissed
        }
        guard let content else {
            // 在后台算不出内容（连接断了，状态跟着没了）：别把实时活动收掉，定格成已暂停。回到前台再按实际收。
            if inBackground, let pushed, activity != nil {
                push(TerminalActivityContent.paused(pushed))
            } else {
                end()
                dismissedByUser = false
            }
            return
        }
        if activity == nil {
            // 只能在前台发起；用户划掉的这一轮不再发起。
            guard !inBackground, !dismissedByUser, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                activity = try Activity.request(attributes: TerminalActivityAttributes(),
                                                content: ActivityContent(state: content, staleDate: staleDate),
                                                pushType: nil)
                pushed = content
                Self.log("started (\(content.rows.count) rows)")
            } catch {
                activity = nil
                Self.log("request failed: \(error)")
            }
            return
        }
        push(content)
    }

    private func push(_ content: TerminalActivityAttributes.ContentState, completion: (@MainActor () -> Void)? = nil) {
        guard let activity else { completion?(); return }
        guard content != pushed || completion != nil else { return }
        pushed = content
        let update = ActivityContent(state: content, staleDate: content.paused ? nil : staleDate)
        Self.log("update: paused=\(content.paused) top=\(content.rows.first?.tone.rawValue ?? "-") "
                 + "keep=\(content.keepUntil != nil) stale=\(update.staleDate.map { Int($0.timeIntervalSinceNow) } ?? -1)s")
        let handle = UncheckedSendable(activity)
        Task {
            await Self.send(update, to: handle)
            completion?()
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        pushed = nil
        let handle = UncheckedSendable(activity)
        Task { await Self.end(handle) }
    }

    // `Activity` 不是 Sendable：从主线程交出去要包一层，在 nonisolated 的地方调它的异步方法。之后主线程不再碰这一次的句柄。
    private nonisolated static func send(_ content: ActivityContent<TerminalActivityAttributes.ContentState>,
                                         to handle: UncheckedSendable<Activity<TerminalActivityAttributes>>) async {
        await handle.value.update(content)
    }

    private nonisolated static func end(_ handle: UncheckedSendable<Activity<TerminalActivityAttributes>>) async {
        await handle.value.end(nil, dismissalPolicy: .immediate)
    }

    /// 内容什么时候算过期：在前台不会过期；后台保持期间到保持结束；普通后台到系统给的时间用完。
    /// 过期了扩展按已暂停画（App 没来得及推「已暂停」时的兜底）。
    private var staleDate: Date? {
        guard inBackground else { return nil }
        if let until = keepAlive.until { return until.addingTimeInterval(30) }
        let remaining = backgroundTimeRemaining()
        return Date().addingTimeInterval(remaining < Self.unboundedBackgroundTime ? remaining
                                         : Self.unboundedRecheck * 2)
    }

    // MARK: 前后台

    private func didEnterBackground() {
        inBackground = true
        Self.log("entered background (activity \(activity == nil ? "none" : "live"), keep \(keepAlive.isActive))")
        guard activity != nil else { return }
        // 自己要一小段时间：保证来得及推「已暂停」（只开着远控标签时没人要后台时间，几秒就被挂起）。
        beginBackgroundTask()
        // 等这一轮通知都处理完（终端控制器在同一个通知里要后台时间），再看系统给了多少。
        Task { [weak self] in
            await Task.yield()
            self?.schedulePause()
        }
    }

    private func schedulePause() {
        guard inBackground, !paused else { return }
        refresh()   // 带上 staleDate
        guard !keepAlive.isActive else { return }   // 保持结束时再暂停
        pauseTimer?.cancel()
        pauseTimer = Task { [weak self] in
            // 系统给的后台时间：正常是有限的（进后台时自己要过，约 30 秒），到点前推「已暂停」。
            // 读到「无限」（测试会话、刚切出去还没算好）时不急着暂停：内容照常实时，staleDate 每次只往后推一小段，
            // 隔几秒再看；万一就这样被挂起了，过期由扩展按已暂停画。
            while let self, !Task.isCancelled {
                let remaining = self.backgroundTimeRemaining()
                if remaining < Self.unboundedBackgroundTime {
                    Self.log("background time \(Int(remaining)) s; pausing in \(Int(max(0, remaining - Self.pauseLead))) s")
                    try? await Task.sleep(for: .seconds(max(0, remaining - Self.pauseLead)))
                    guard !Task.isCancelled else { return }
                    self.pauseNow()
                    return
                }
                self.refresh()
                try? await Task.sleep(for: .seconds(Self.unboundedRecheck))
            }
        }
    }

    /// 比这还长的后台时间按「无限」算（系统没有在倒计时）。
    nonisolated static let unboundedBackgroundTime: TimeInterval = 600
    /// 「无限」时隔多久再看一次，staleDate 也只往后推这么多再加几秒。
    nonisolated static let unboundedRecheck: TimeInterval = 5
    nonisolated static let logCategory = "live-activity"

    /// 日志（分类 `live-activity`）。Debug 构建同时写 stderr：真机上 `devicectl … --console` 只看得到 stderr。
    private static func log(_ message: String) {
        AppLogger.notice(message, category: logCategory)
        #if DEBUG
        FileHandle.standardError.write(Data("[live-activity] \(message)\n".utf8))
        #endif
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "live-activity-pause") { [weak self] in
            // 系统到点收回：必须马上还，否则 App 会被直接结束。「已暂停」照推，来不及送到就靠 staleDate。
            MainActor.assumeIsolated {
                self?.pauseNow()
                self?.finishBackgroundTask()
            }
        }
    }

    /// 马上要被挂起了：推最后一次（已暂停），推完把时间还给系统。
    private func pauseNow() {
        pauseTimer?.cancel()
        pauseTimer = nil
        guard inBackground, !keepAlive.isActive, !paused else { return finishBackgroundTask() }
        paused = true
        Self.log("paused (about to be suspended)")
        guard let pushed else { return finishBackgroundTask() }
        push(TerminalActivityContent.paused(pushed)) { [weak self] in self?.finishBackgroundTask() }
    }

    private func finishBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func willEnterForeground() {
        inBackground = false
        Self.log("entering foreground")
        paused = false
        pauseTimer?.cancel()
        pauseTimer = nil
        finishBackgroundTask()
        refresh()
    }

    // MARK: 后台保持

    private var keepAliveStatus: (busy: Bool, subtitle: String) {
        let busy = entries.contains { $0.status.state == .working || $0.status.state == .blocked }
        if let top = pushed?.rows.first {
            return (busy, "\(top.program) · \(top.status) — \(top.title)")
        }
        let count = workspace?.terminalTabs.filter { $0.controller.state == .connected }.count ?? 0
        return (busy, String(localized: "\(count) 个终端保持连接"))
    }

    private func keepAliveChanged() {
        refresh()
        // 保持结束时已经在后台：按普通后台处理（还剩多少时间就等多久，然后暂停）。
        if inBackground, !keepAlive.isActive {
            if activity != nil { beginBackgroundTask() }
            schedulePause()
        }
    }

    // MARK: 通知

    private static func postNotification(for entry: TerminalActivityEntry) {
        let status = entry.status
        let content = UNMutableNotificationContent()
        content.title = "\(status.appName) · \(status.statusLabel)"
        content.subtitle = entry.title
        content.body = status.message ?? entry.host
        content.sound = .default
        content.userInfo = [TerminalNotificationRouter.urlKey: TerminalActivityAttributes.link(tab: entry.tabID).absoluteString]
        content.threadIdentifier = "terminal"
        log("notify: \(content.title)")
        // 同一个标签页共用一个标识：新通知替换旧的，通知中心里不会堆一串。
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "terminal-\(entry.tabID.uuidString)", content: content, trigger: nil))
    }
}

/// 打开某个终端标签页的请求（深链接、通知）。`tabID` 为 nil 或认不得时只打开工作区。
struct TerminalOpenRequest: Equatable {
    let id = UUID()
    let tabID: UUID?
}

/// 通知中心的 delegate（iOS 上全 App 只有这一个）。点了终端通知就打开那个标签页；
/// 别的通知（并行执行完成等）照旧只是把 App 拉起来。App 在前台时不弹横幅，和没有 delegate 时一样。
final class TerminalNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let urlKey = "uterm.url"
    var onOpen: (URL) -> Void = { _ in }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let text = response.notification.request.content.userInfo[Self.urlKey] as? String
        Task { @MainActor in
            if let text, let url = URL(string: text) { self.onOpen(url) }
        }
        completionHandler()
    }
}

/// 根视图上：接 `uterm://terminal/…` 链接，把请求的标签页切到前台、展开工作区。
struct TerminalActivityLinkHandler: ViewModifier {
    @Environment(TerminalActivityCenter.self) private var center
    @Environment(MobileStore.self) private var store
    @Environment(MobileWorkspace.self) private var workspace

    func body(content: Content) -> some View {
        content
            .onOpenURL { center.open($0) }
            .onChange(of: center.pendingOpen) { _, request in
                guard let request else { return }
                center.pendingOpen = nil
                if let tabID = request.tabID, workspace.tab(tabID) != nil { workspace.activate(tabID) }
                if !workspace.isEmpty { store.showWorkspace = true }
            }
    }
}
