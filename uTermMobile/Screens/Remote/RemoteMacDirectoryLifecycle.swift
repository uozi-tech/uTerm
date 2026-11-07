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
        guard backgroundTask == .invalid, directory.hasConnectedClients else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Remote terminals") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    private func willEnterForeground() {
        endBackgroundTask()
        directory?.returnedToForeground()
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
