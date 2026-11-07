import Foundation
import Observation
import UserNotifications

/// 中继有没有新版本：正在跑的版本来自 hello（注册成功或「测试连接」时记下），最新版本来自 OSS 的
/// `latest.json`，一天最多问一次。发现新版本时设置页显示「更新」，并按版本只发一次通知。
@MainActor
@Observable
final class RemoteRelayUpdateMonitor {
    nonisolated static let notificationKey = "relayUpdate"
    nonisolated static let notificationID = "relay-update"
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    /// 设置窗的入口由 App 层注入（`openWindow` 只能在 Scene 环境里拿到）。
    static var openSettings: (() -> Void)?

    private(set) var runningVersion: String?
    private(set) var latestVersion: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetchLatest: @Sendable () async throws -> String
    @ObservationIgnored private let notify: @MainActor (String, String) -> Void
    @ObservationIgnored private var fetching: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         fetchLatest: @escaping @Sendable () async throws -> String = { try await RemoteRelayRelease.fetchLatestVersion() },
         notify: @escaping @MainActor (String, String) -> Void = RemoteRelayUpdateMonitor.postNotification) {
        self.defaults = defaults
        self.fetchLatest = fetchLatest
        self.notify = notify
        latestVersion = defaults.string(forKey: DefaultsKey.remoteRelayLatestVersion)
    }

    /// 测试与测试宿主用：不联网、不发通知。
    static func inert() -> RemoteRelayUpdateMonitor {
        RemoteRelayUpdateMonitor(defaults: UserDefaults(suiteName: "uterm.relay-updates.inert") ?? .standard,
                                 fetchLatest: { throw CancellationError() },
                                 notify: { _, _ in })
    }

    var updateAvailable: Bool {
        RemoteRelayVersion.isUpdate(latest: latestVersion, running: runningVersion)
    }

    /// 认证通过时调用。没报版本就当不知道，不提醒。
    func noteRunning(_ version: String?) {
        runningVersion = version
        refreshIfStale()
        notifyIfNeeded()
    }

    /// 换了 / 移除了中继：正在跑的版本作废。
    func reset() {
        runningVersion = nil
    }

    func refreshIfStale(now: Date = Date()) {
        let checked = defaults.object(forKey: DefaultsKey.remoteRelayLatestCheckedAt) as? Date
        guard checked.map({ now.timeIntervalSince($0) >= Self.refreshInterval }) ?? true else { return }
        Task { await refresh(now: now) }
    }

    /// 立刻问一次 OSS。失败就沿用缓存，下次再试。
    func refresh(now: Date = Date()) async {
        if let fetching { return await fetching.value }
        let task = Task { [fetchLatest] in
            guard let version = try? await fetchLatest() else { return }
            self.latestVersion = version
            self.defaults.set(version, forKey: DefaultsKey.remoteRelayLatestVersion)
            self.defaults.set(now, forKey: DefaultsKey.remoteRelayLatestCheckedAt)
            self.notifyIfNeeded()
        }
        fetching = task
        await task.value
        fetching = nil
    }

    private func notifyIfNeeded() {
        guard updateAvailable, let latestVersion, let runningVersion,
              defaults.string(forKey: DefaultsKey.remoteRelayNotifiedVersion) != latestVersion else { return }
        defaults.set(latestVersion, forKey: DefaultsKey.remoteRelayNotifiedVersion)
        notify(runningVersion, latestVersion)
    }

    static func postNotification(running: String, latest: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "中继有新版本 \(latest)")
        content.body = String(localized: "你的中继服务器还在用 \(running)。到 设置 › 远程控制 可以一键更新。")
        content.userInfo = [notificationKey: latest]
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }

    /// 点了通知：打开 设置 › 远程控制。
    static func handleNotificationClick() {
        UserDefaults.standard.set(SettingsSection.remote.rawValue, forKey: SettingsTabSelection.key)
        openSettings?()
    }
}
