import Foundation
import Network

/// 这台设备此刻走的网络：「Wi-Fi · 有 IPv6」「蜂窝网络 · 无 IPv6」……网络诊断记进每条结果，换网络后能对上。
nonisolated enum RemoteNetworkLabel {
    static func current() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: label(
                    wifi: path.usesInterfaceType(.wifi), cellular: path.usesInterfaceType(.cellular),
                    wired: path.usesInterfaceType(.wiredEthernet), ipv6: path.supportsIPv6))
            }
            monitor.start(queue: DispatchQueue(label: "com.uozi.uTerm.remote.network-label"))
        }
    }

    static func label(wifi: Bool, cellular: Bool, wired: Bool, ipv6: Bool) -> String {
        let kind = wifi ? "Wi-Fi"
            : cellular ? String(localized: "蜂窝网络")
            : wired ? String(localized: "有线", comment: "网络类型：有线网络")
            : String(localized: "其他", comment: "网络类型：其他")
        let ipv6Label = ipv6 ? String(localized: "有 IPv6") : String(localized: "无 IPv6")
        return "\(kind) · \(ipv6Label)"
    }
}
