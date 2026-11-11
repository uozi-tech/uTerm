import UIKit

/// App 进后台后向系统多要的那一小段运行时间（约 30 秒，系统说了算）。
///
/// 没有它，App 一进后台几秒内就被挂起，SSH 连接随后被对端或 NAT 掐掉。切出去看一眼别的 App、回个消息再回来，
/// 这段时间连接不断、输出照收；会话留在主机上的终端也靠它把检查点发出去（`CheckpointingTerminalBackend`）。
/// 时间到了系统照常挂起 App，之后的事由重连（`PersistentSSHConnection`）或断开提示上的「重新连接」接手。
@MainActor
final class MobileBackgroundGrace {
    static let shared = MobileBackgroundGrace()

    private var task: UIBackgroundTaskIdentifier = .invalid

    /// 有连着的终端的会话进后台时调。已经要过就不再要。
    func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "terminal-sessions") { [weak self] in
            // 系统要收回了：必须马上还，否则 App 会被直接结束。
            MainActor.assumeIsolated { self?.end() }
        }
    }

    /// 回到前台，或者系统到点收回。
    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    /// 此刻是不是正占着这段时间（测试用）。
    var isActive: Bool { task != .invalid }
}
