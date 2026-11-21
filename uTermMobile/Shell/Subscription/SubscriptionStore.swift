import Foundation
import Observation
import StoreKit

/// iOS 版的订阅（uTerm Pro，月付 / 年付，年付带免费试用）。StoreKit 2：本机读权益、监听交易更新。
///
/// 规则：全部功能都在订阅里，门开在「开始用」的那一下（连主机、开文件、远控 Mac、跑快捷命令，见
/// `MobileStore` 里的 `admits`）。没订阅也能看主机列表（iCloud 同步来的）、改设置、用体验主机。
/// 权益还没读出来（冷启动那几毫秒）时不拦，免得刚打开就误弹订阅页。
///
/// Mac 官网版是 Developer ID 分发，用不了 App Store 订阅，所以这套只在 iOS。
@MainActor
@Observable
final class SubscriptionStore {
    enum Status: Equatable {
        /// 还没读出来。
        case unknown
        case active(productID: String, expires: Date?)
        case inactive
    }

    /// 商品 ID 跟着 bundle id 走（外部贡献者换了前缀也能用自己的 App Store Connect 记录测）。
    nonisolated static var productPrefix: String { (Bundle.main.bundleIdentifier ?? "com.uozi.uTerm") + ".pro" }
    nonisolated static var yearlyID: String { productPrefix + ".yearly" }
    nonisolated static var monthlyID: String { productPrefix + ".monthly" }
    nonisolated static var productIDs: [String] { [yearlyID, monthlyID] }

    private(set) var status: Status = .unknown
    /// 订阅页是否在显示（根视图据此弹 sheet）。
    var paywallPresented = false
    /// 门禁拦下一个操作时换一个新值：根视图稍等片刻再弹订阅页。拦下的操作常常来自正在收起的
    /// 命令面板 / 面板，同一帧里再弹一层会被 SwiftUI 丢掉。
    private(set) var paywallRequest: UUID?

    /// 订阅页因为哪个操作弹出来：买成功就接着做，关掉没买就丢掉。
    @ObservationIgnored private var pendingAction: (() -> Void)?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var resolvedWaiters: [CheckedContinuation<Void, Never>] = []
    /// 固定状态（测试宿主、调试开关）：不碰 StoreKit。
    @ObservationIgnored private let fixed: Status?

    init(fixed: Status? = nil) {
        self.fixed = fixed
        if let fixed { status = fixed }
    }

    /// App 用的那一份：测试宿主里视为已订阅（现有用例不受门禁影响）；Debug 构建认启动参数
    /// `-UTermSubscriptionOverride active|inactive`。
    static func live() -> SubscriptionStore {
        if TestHostEnvironment.isActive { return SubscriptionStore(fixed: .active(productID: "test-host", expires: nil)) }
        #if DEBUG
        switch UserDefaults.standard.string(forKey: DefaultsKey.subscriptionOverride)?.lowercased() {
        case "active": return SubscriptionStore(fixed: .active(productID: "debug", expires: nil))
        case "inactive": return SubscriptionStore(fixed: .inactive)
        default: break
        }
        #endif
        return SubscriptionStore()
    }

    /// 能不能直接用（订阅中，或者还没读出来）。
    var isEntitled: Bool { status != .inactive }

    var isSubscribed: Bool { if case .active = status { return true } else { return false } }

    /// 启动时调一次：读当前权益，之后跟着交易更新（续订、退款、别的设备买的）走。
    func start() {
        guard fixed == nil, updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    /// 重新读一遍权益（回前台、买完、恢复购买之后）。过期不会产生交易，所以回前台要读。
    func refresh() async {
        guard fixed == nil else { return }
        var best: (id: String, expires: Date?)?
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expires = transaction.expirationDate, expires < Date() { continue }
            if best == nil || (transaction.expirationDate ?? .distantFuture) > (best?.expires ?? .distantPast) {
                best = (transaction.productID, transaction.expirationDate)
            }
        }
        apply(best.map { .active(productID: $0.id, expires: $0.expires) } ?? .inactive)
    }

    /// 测试用：直接给一个状态（等同读到了这样的权益）。
    func apply(_ newStatus: Status) {
        status = newStatus
        let waiters = resolvedWaiters
        resolvedWaiters = []
        waiters.forEach { $0.resume() }
        if isSubscribed, let action = pendingAction {
            pendingAction = nil
            paywallPresented = false
            action()
        }
    }

    /// 等到权益读出来（启动时恢复上次的标签要先知道能不能连）。
    func waitUntilResolved() async {
        guard status == .unknown else { return }
        await withCheckedContinuation { resolvedWaiters.append($0) }
    }

    /// 门禁：订阅中（或还没读出来）就直接做；否则弹订阅页，买成功后接着做。返回是否已经放行。
    @discardableResult
    func require(_ action: @escaping () -> Void) -> Bool {
        if isEntitled {
            action()
            return true
        }
        pendingAction = action
        paywallRequest = UUID()
        return false
    }

    /// 订阅页关掉了：没买就不再接着做刚才的操作。
    func paywallDismissed() {
        pendingAction = nil
        paywallRequest = nil
    }

    /// 订阅页里的购买完成。
    func handlePurchase(_ result: Product.PurchaseResult) async {
        if case .success(let verification) = result, case .verified(let transaction) = verification {
            await transaction.finish()
        }
        await refresh()
    }

    /// 恢复购买：向 App Store 同步一遍再读。
    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}
