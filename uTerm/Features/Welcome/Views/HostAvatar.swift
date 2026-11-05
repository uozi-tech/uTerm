import SwiftUI
import UDesignKit

/// 主机头像（与 iOS `MHostAvatar` 同构）：分组色色块 + 首字母，右下角圆点是服务器在线状态。
///
/// - 色块 / 字色取**分组色**（字 = 组色、底 = 组色 14%，与 `UDGroupChip` 同一套）；未分组回退中性灰。
/// - 角标从 `HostReachabilityMonitor` 读，绿 = 端口握得上、红 = 握不上、灰 = 还没探到。
///   走跳板机的主机不探，也就不画角标（`reachability == nil`）。
/// - 角标四周是镂空（`HostAvatarShape`），不是描一圈背景色。
struct HostAvatar: View {
    let monogram: String
    let tint: Color?
    let reachability: HostReachabilityEntry?
    var size: CGFloat = 30

    var body: some View {
        let m = HostAvatarMetrics(size: size)
        Text(monogram)
            .font(.system(size: (size * 0.47).rounded(), weight: .semibold, design: .monospaced))
            .foregroundStyle(tint ?? UD.text3)
            .frame(width: size, height: size)
            .background(tint?.opacity(0.14) ?? UD.fillSoft,
                        in: HostAvatarShape(cornerRadius: m.cornerRadius,
                                            cutoutDiameter: reachability == nil ? 0 : m.cutoutDiameter,
                                            cutoutOffset: m.cutoutOffset))
            .overlay(alignment: .bottomTrailing) {
                if let reachability {
                    HostStatusDot(entry: reachability, diameter: m.badge)
                        .offset(x: m.badgeOffset, y: m.badgeOffset)
                }
            }
    }
}

/// 在线状态圆点。单独成一个视图：只有它读 `entry.status`，状态变化只让这一个圆点重求 body。
struct HostStatusDot: View {
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
        case .online: UD.success
        case .offline: UD.danger
        case .unknown: UD.text4
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
