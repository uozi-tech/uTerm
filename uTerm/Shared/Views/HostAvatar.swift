import SwiftUI
import UDesignKit

/// 主机头像（两端共用）：分组色色块 + 首字母，右下角圆点是服务器在线状态。
///
/// - 色块 / 字色取**分组色**（字 = 组色、底 = 组色 14%，与 `UDGroupChip` / `MGroupChip` 同一套）；
///   未分组回退中性灰。
/// - 角标从 `HostReachabilityMonitor` 读，绿 = 端口握得上、红 = 握不上、灰 = 还没探到。
///   走跳板机的主机不探，也就不画角标（`reachability == nil`）。
/// - 角标四周是镂空（`HostAvatarShape`），不是描一圈背景色。
/// - 探测要调用方在可见期间挂 `.watchesReachability(of:)`，头像自己只读不探。
///
/// 两端只在两个比例上有意不同（做成参数、按平台取默认）：默认边长 mac 30 / iOS 38，
/// 首字母字号占边长 mac 0.47 / iOS 0.42。
struct HostAvatar: View {
    #if os(macOS)
    nonisolated static let defaultSize: CGFloat = 30
    nonisolated static let defaultMonogramScale: CGFloat = 0.47
    #else
    nonisolated static let defaultSize: CGFloat = 38
    nonisolated static let defaultMonogramScale: CGFloat = 0.42
    #endif

    let monogram: String
    let tint: Color?
    let reachability: HostReachabilityEntry?
    var size: CGFloat = HostAvatar.defaultSize
    /// 首字母字号 = `size × monogramScale`（取整）。
    var monogramScale: CGFloat = HostAvatar.defaultMonogramScale

    var body: some View {
        let m = HostAvatarMetrics(size: size)
        Text(monogram)
            .font(.system(size: (size * monogramScale).rounded(), weight: .semibold, design: .monospaced))
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
        case .online: String(localized: "在线", comment: "主机在线状态")
        case .offline: String(localized: "离线", comment: "主机在线状态")
        case .unknown: String(localized: "在线状态未知")
        }
    }
}

extension View {
    /// 视图可见期间登记这台主机的在线探测，消失即注销（见 `HostReachabilityMonitor`）。
    /// 跳板机主机 key 为 nil，不探。只是一层 `task(id:)`，不给行视图多加层级。
    func watchesReachability(of host: ServerProfile) -> some View {
        watchesReachability(of: HostEndpointKey(host))
    }

    /// 同上，调用方已经算好了端点（nil = 不探）。
    func watchesReachability(of key: HostEndpointKey?) -> some View {
        task(id: key) {
            guard let key else { return }
            await HostReachabilityMonitor.shared.watch(key)
        }
    }
}
