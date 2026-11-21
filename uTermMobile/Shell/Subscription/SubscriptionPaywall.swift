import StoreKit
import SwiftUI

/// 订阅页。价格、试用、自动续期说明、恢复购买、条款与隐私政策链接都用系统的 `SubscriptionStoreView`
/// 画（满足审核指南 3.1.2 对订阅页的要求），这里只给上面那块介绍。
struct SubscriptionPaywall: View {
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    /// Apple 的标准 EULA（App Store Connect 里没有填自定义条款时就是它）。
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://github.com/uozi-tech/uTerm/blob/main/PRIVACY.md")!

    var body: some View {
        SubscriptionStoreView(productIDs: SubscriptionStore.productIDs) {
            SubscriptionPaywallHeader()
        }
        .subscriptionStoreControlStyle(.prominentPicker)
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .cancellation)
        .storeButton(.visible, for: .redeemCode)
        .subscriptionStorePolicyDestination(url: Self.termsURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: Self.privacyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, result in
            if case .success(let purchase) = result { await subscriptions.handlePurchase(purchase) }
        }
        .tint(M.accent)
        .onChange(of: subscriptions.isSubscribed) { _, subscribed in
            if subscribed { dismiss() }
        }
    }
}

/// 订阅页顶部：一句话说清楚订阅包含什么。
struct SubscriptionPaywallHeader: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(M.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(spacing: 6) {
                Text("uTerm Pro").font(M.sans(26, weight: .bold)).foregroundStyle(M.text)
                Text("订阅后可以使用 uTerm 的全部功能。")
                    .font(M.sans(15)).foregroundStyle(M.text2)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 10) {
                feature("terminal", "SSH 终端与 SFTP 文件，断网、切后台也不掉线")
                feature("display", "远程控制你的 Mac：终端、屏幕与文件")
                feature("sparkles", "终端里的 AI 助手，用你自己的模型服务")
                feature("bolt", "快捷命令一键发到多台主机并行执行")
                feature("icloud", "主机、密钥和设置经 iCloud 在设备间同步")
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func feature(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(M.accent).frame(width: 22)
            Text(text).font(M.sans(14.5)).foregroundStyle(M.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// 根视图挂一次：门禁拦下操作时在最上层弹订阅页。
    func mobileSubscriptionPaywall(_ subscriptions: SubscriptionStore) -> some View {
        modifier(SubscriptionPaywallPresenter(subscriptions: subscriptions))
    }
}

private struct SubscriptionPaywallPresenter: ViewModifier {
    @Bindable var subscriptions: SubscriptionStore
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $subscriptions.paywallPresented, onDismiss: subscriptions.paywallDismissed) {
                SubscriptionPaywall().environment(subscriptions)
            }
            .task(id: subscriptions.paywallRequest) {
                guard subscriptions.paywallRequest != nil else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, !subscriptions.isEntitled else { return }
                subscriptions.paywallPresented = true
            }
            // 订阅可能在 App 不在前台时到期 / 续上（到期不产生交易），回前台读一遍。
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await subscriptions.refresh() } }
            }
    }
}
