import Foundation
@preconcurrency import Network

/// 网络路径变化：TCP 自己发现链路死了要几十秒，这里让连接在网络一变时就去确认。
///
/// 只比较可用网卡的名字：切 Wi-Fi 网络但网卡不变时不会触发，那种情况靠心跳兜底。
/// 系统切网时路径会抖几次，稳定 0.4 秒后才报告；第一次回报只是初始状态，不算变化。
@MainActor
final class RemoteNetworkWatcher {
    nonisolated static let settleDelay: Duration = .milliseconds(400)

    private let monitor = NWPathMonitor()
    private let onChange: @MainActor (_ isSatisfied: Bool) -> Void
    private var reported: String?
    private var settling: Task<Void, Never>?

    init(onChange: @escaping @MainActor (_ isSatisfied: Bool) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let signature = satisfied ? path.availableInterfaces.map(\.name).joined(separator: ",") : "unsatisfied"
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pathChanged(signature: signature, isSatisfied: satisfied) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.uozi.uTerm.remote.path"))
    }

    deinit {
        monitor.cancel()
    }

    private func pathChanged(signature: String, isSatisfied: Bool) {
        guard let previous = reported else {
            reported = signature
            return
        }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, previous != signature else { return }
            self.reported = signature
            self.onChange(isSatisfied)
        }
    }
}
