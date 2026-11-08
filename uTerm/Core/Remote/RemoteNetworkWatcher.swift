import Foundation
@preconcurrency import Network

/// 网络变化后的样子。
nonisolated struct RemoteNetworkSnapshot: Equatable, Sendable {
    var isSatisfied: Bool
    /// 可用网卡名（en0、pdp_ip0……），按系统给的顺序。
    var interfaces: [String]
    /// 有 Wi-Fi 或有线：局域网里的 Mac 才可能连得上。
    var hasLocalNetwork: Bool
    /// 日志用：「Wi-Fi」「蜂窝网络」……
    var label: String

    static func from(_ path: NWPath) -> RemoteNetworkSnapshot {
        let satisfied = path.status == .satisfied
        return RemoteNetworkSnapshot(
            isSatisfied: satisfied, interfaces: satisfied ? path.availableInterfaces.map(\.name) : [],
            hasLocalNetwork: satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)),
            label: satisfied ? (RemoteNetworkLabel.interface(of: path) ?? "?") : String(localized: "无网络"))
    }
}

/// 网络路径变化：TCP 自己发现链路死了要几十秒，这里让连接在网络一变时就去确认。
///
/// 只比较可用网卡的名字：切 Wi-Fi 网络但网卡不变时不会触发，那种情况靠心跳兜底。
/// 系统切网时路径会抖几次，稳定 0.4 秒后才报告；第一次回报只是初始状态，不算变化。
@MainActor
final class RemoteNetworkWatcher {
    nonisolated static let settleDelay: Duration = .milliseconds(400)

    private let monitor = NWPathMonitor()
    private let onChange: @MainActor (RemoteNetworkSnapshot) -> Void
    private var reported: String?
    private var settling: Task<Void, Never>?
    /// 最近一次（稳定后）的网络。
    private(set) var current: RemoteNetworkSnapshot?

    init(onChange: @escaping @MainActor (RemoteNetworkSnapshot) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = RemoteNetworkSnapshot.from(path)
            let signature = snapshot.isSatisfied ? snapshot.interfaces.joined(separator: ",") : "unsatisfied"
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pathChanged(signature: signature, snapshot: snapshot) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.uozi.uTerm.remote.path"))
    }

    deinit {
        monitor.cancel()
    }

    private func pathChanged(signature: String, snapshot: RemoteNetworkSnapshot) {
        guard let previous = reported else {
            reported = signature
            current = snapshot
            return
        }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, previous != signature else { return }
            self.reported = signature
            self.current = snapshot
            AppLogger.notice("网络变化：\(previous) → \(signature)（\(snapshot.label)）", category: RemoteLog.category)
            self.onChange(snapshot)
        }
    }
}
