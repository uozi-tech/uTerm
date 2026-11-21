import StoreKitTest
import SwiftUI
import XCTest
@testable import uTermMobile

/// 订阅页截图（App Store Connect 里每个订阅商品要附一张给审核员看）。用本地 StoreKit 配置
/// `Config/uTerm.storekit` 加载商品，画面和真机一致（价格档位是配置里的）。
/// 按需跑：`TEST_RUNNER_UTERM_STYLE_SHOTS_DIR=<目录> xcodebuild test … -only-testing:uTermMobileTests/SubscriptionPaywallShotTests`。
@MainActor
final class SubscriptionPaywallShotTests: XCTestCase {
    func testShootPaywall() async throws {
        guard let dir = ProcessInfo.processInfo.environment["UTERM_STYLE_SHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("未设置 UTERM_STYLE_SHOTS_DIR")
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/uTerm.storekit")
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        _ = try await Product.products(for: SubscriptionStore.productIDs)

        let subscriptions = SubscriptionStore(fixed: .inactive)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let root = SubscriptionPaywall()
                .environment(subscriptions)
                .environment(\.mAccent, M.accent)
            let (window, host) = MobileProbeWindow.make(placement: .visibleOnScreen, rootView: root)
            window.overrideUserInterfaceStyle = style
            host.view.backgroundColor = style == .dark ? .black : .white
            // 商品是异步加载的：等系统订阅页把价格画出来。
            try await Task.sleep(for: .seconds(4))
            host.view.layoutIfNeeded()
            CATransaction.flush()
            let png = UIGraphicsImageRenderer(bounds: host.view.bounds).pngData { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let out = URL(fileURLWithPath: dir).appendingPathComponent(
                "subscription-paywall-\(style == .dark ? "dark" : "light").png")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: out)
            MobileProbeWindow.close(window)
        }
        session.clearTransactions()
    }
}
