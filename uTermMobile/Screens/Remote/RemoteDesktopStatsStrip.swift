import SwiftUI

/// 顶栏上的实时读数。每秒变的读数只在这个视图里读，只有它自己跟着重算：
/// 放在顶栏里读的话，同一条上的「更多」菜单每秒被重建，打开着时一闪一闪。
struct RemoteDesktopLiveStats: View {
    let session: RemoteDesktopSession

    var body: some View {
        RemoteDesktopStatsStrip(items: session.statItems)
    }
}

/// 远程桌面顶栏的读数：一项一格，小标题在上、数值在下，数值按 `RemoteDesktopStat.Level` 变色。
/// 排什么、什么时候变色在共享的 `RemoteDesktopStat.items`，这里只画。
struct RemoteDesktopStatsStrip: View {
    let items: [RemoteDesktopStat]

    var body: some View {
        // 放得下就带补充读数（p95、声音缓冲的目标），放不下只留主数值，再不够就把格子挤紧。
        ViewThatFits(in: .horizontal) {
            row(detailed: true, spacing: 16)
            row(detailed: false, spacing: 16)
            row(detailed: false, spacing: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RemoteDesktopStat.spokenText(items))
    }

    private func row(detailed: Bool, spacing: CGFloat) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(M.sans(9.5))
                        .foregroundStyle(.white.opacity(0.5))
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(item.value)
                            .font(M.mono(12, weight: .medium))
                            .foregroundStyle(Self.color(item.level))
                        Text(item.unit)
                            .font(M.mono(9.5))
                            .foregroundStyle(.white.opacity(0.5))
                        if detailed, let detail = item.detail {
                            Text(detail)
                                .font(M.mono(9.5))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.leading, 3)
                        }
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
    }

    static func color(_ level: RemoteDesktopStat.Level) -> Color {
        switch level {
        case .normal: return .white.opacity(0.92)
        case .warning: return M.warning
        case .poor: return M.danger
        }
    }
}
