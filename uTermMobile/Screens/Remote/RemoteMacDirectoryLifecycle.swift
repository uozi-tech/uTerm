import BackgroundTasks
import UIKit

/// iOS 上 Mac 目录的前后台处理：切到别的 App 回个消息时申请一段后台时间，短暂离开连接不断，回来也不用
/// 重发快照。到期后 iOS 挂起 App，连接随之断开，回前台再重连。
@MainActor
final class RemoteMacDirectoryLifecycle {
    private weak var directory: RemoteMacDirectory?
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(directory: RemoteMacDirectory) {
        self.directory = directory
        Self.registerRenewalTask(for: directory)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willEnterForeground() }
            },
        ]
    }

    private func didEnterBackground() {
        guard let directory else { return }
        directory.enteredBackground()
        Self.scheduleRenewal()
        guard backgroundTask == .invalid, directory.hasConnectedClients else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Remote terminals") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    private func willEnterForeground() {
        endBackgroundTask()
        directory?.returnedToForeground()
    }

    // MARK: 后台续成员证书

    /// 平时 App 查 Mac 在线状态时就顺手续了（`RemoteMacDirectory.startCertificateRenewals`）；这是给长期不打开
    /// App 的人的补充：系统挑空闲时机拉起 App 跑一下，不保证执行。
    static let renewalTaskID = "com.uozi.uTerm.relay.renewCertificates"
    private static var renewalRegistered = false
    private static weak var renewalTarget: RemoteMacDirectory?

    /// 必须在启动结束前登记（App 的 init 里建目录时就会走到）。只登记一次，测试里多建的目录只换目标。
    private static func registerRenewalTask(for directory: RemoteMacDirectory) {
        renewalTarget = directory
        guard !renewalRegistered, !TestHostEnvironment.isActive else { return }
        renewalRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: renewalTaskID, using: .main) { task in
            let handed = UncheckedSendable(task)
            MainActor.assumeIsolated { runRenewal(handed.value) }
        }
    }

    private static func runRenewal(_ task: BGTask) {
        scheduleRenewal()
        let work = Task { @MainActor in
            await renewalTarget?.renewDueCertificates()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// 退到后台时排下一次：最早一天后。
    private static func scheduleRenewal() {
        guard renewalRegistered, renewalTarget?.holdsRelayCertificates == true else { return }
        let request = BGAppRefreshTaskRequest(identifier: renewalTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 86_400)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension RemoteMacDirectory {
    /// iOS App 用的目录：带前后台处理。
    static func mobile(relayStore: RemoteRelayConfigStore?) -> RemoteMacDirectory {
        let directory = RemoteMacDirectory(relayStore: relayStore,
                                           startsInForeground: UIApplication.shared.applicationState != .background)
        directory.lifecycle = RemoteMacDirectoryLifecycle(directory: directory)
        return directory
    }
}
