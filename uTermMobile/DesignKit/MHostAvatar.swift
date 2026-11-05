import SwiftUI
import UDesignKit

/// 主机头像（与 macOS `HostAvatar` 同构）：分组色色块 + 首字母，右下角圆点是服务器在线状态。
///
/// - 色块 / 字色取**分组色**（字 = 组色、底 = 组色 14%，与 `MGroupChip` 同一套）；未分组回退中性灰。
/// - 角标从 `HostReachabilityMonitor` 读，绿 = 端口握得上、红 = 握不上、灰 = 还没探到。
///   走跳板机的主机不探，也就不画角标（`reachability == nil`）。
/// - 探测要调用方在可见期间挂 `.mWatchesReachability(of:)`，头像自己只读不探。
struct MHostAvatar: View {
    let monogram: String
    let tint: Color?
    let reachability: HostReachabilityEntry?
    var size: CGFloat = 38

    var body: some View {
        let m = HostAvatarMetrics(size: size)
        Text(monogram)
            .font(M.mono((size * 0.42).rounded(), weight: .semibold))
            .foregroundStyle(tint ?? M.text3)
            .frame(width: size, height: size)
            .background(tint?.opacity(0.14) ?? UD.fillSoft,
                        in: HostAvatarShape(cornerRadius: m.cornerRadius,
                                            cutoutDiameter: reachability == nil ? 0 : m.cutoutDiameter,
                                            cutoutOffset: m.cutoutOffset))
            .overlay(alignment: .bottomTrailing) {
                if let reachability {
                    MHostStatusDot(entry: reachability, diameter: m.badge)
                        .offset(x: m.badgeOffset, y: m.badgeOffset)
                }
            }
    }
}

/// 在线状态圆点。单独成一个视图：只有它读 `entry.status`，状态变化只让这一个圆点重求 body。
struct MHostStatusDot: View {
    let entry: HostReachabilityEntry
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .accessibilityLabel(Text(label))
    }

    private var color: Color {
        switch entry.status {
        case .online: M.success
        case .offline: M.danger
        case .unknown: M.text4
        }
    }

    private var label: String {
        switch entry.status {
        case .online: "在线"
        case .offline: "离线"
        case .unknown: "在线状态未知"
        }
    }
}

extension View {
    /// 视图可见期间登记这台主机的在线探测，消失即注销（见 `HostReachabilityMonitor`）。
    func mWatchesReachability(of host: ServerProfile) -> some View {
        task(id: HostEndpointKey(host)) {
            guard let key = HostEndpointKey(host) else { return }
            await HostReachabilityMonitor.shared.watch(key)
        }
    }
}
