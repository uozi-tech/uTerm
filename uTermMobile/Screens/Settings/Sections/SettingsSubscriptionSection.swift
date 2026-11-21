import StoreKit
import SwiftUI

/// 设置 › 订阅：当前状态、订阅 / 管理订阅、恢复购买。
struct SettingsSubscriptionSection: View {
    /// App 注入；测试里单独渲染设置页时可能没有，那就不显示这一组。
    @Environment(SubscriptionStore.self) private var subscriptions: SubscriptionStore?

    var body: some View {
        if let subscriptions { SubscriptionSettingsGroup(subscriptions: subscriptions) }
    }
}

private struct SubscriptionSettingsGroup: View {
    let subscriptions: SubscriptionStore
    @State private var managing = false
    @State private var restoring = false

    var body: some View {
        MInsetGroup(header: String(localized: "订阅"), footer: footer) {
            MInsetRow(icon: "spark", label: "uTerm Pro", value: statusText)
            if subscriptions.isSubscribed {
                MInsetRow(icon: "gear", label: String(localized: "管理订阅"), chevron: true,
                          onTap: { managing = true })
            } else {
                MInsetRow(icon: "spark", label: String(localized: "订阅 uTerm Pro"), chevron: true,
                          onTap: { subscriptions.paywallPresented = true })
            }
            MInsetRow(icon: "refresh", label: restoring ? String(localized: "正在恢复…") : String(localized: "恢复购买"),
                      last: true, onTap: restore)
        }
        .manageSubscriptionsSheet(isPresented: $managing)
    }

    private var statusText: String {
        switch subscriptions.status {
        case .unknown: return String(localized: "正在读取…")
        case .inactive: return String(localized: "未订阅")
        case .active(_, let expires?):
            return String(localized: "订阅中，\(expires.formatted(date: .abbreviated, time: .omitted)) 续期")
        case .active: return String(localized: "订阅中")
        }
    }

    private var footer: String {
        String(localized: "订阅后可以使用全部功能；没订阅时可以用「体验主机」先试试。订阅按 App Store 的规则自动续期，可以随时在「管理订阅」里取消。")
    }

    private func restore() {
        guard !restoring else { return }
        restoring = true
        Task {
            await subscriptions.restore()
            restoring = false
        }
    }
}
