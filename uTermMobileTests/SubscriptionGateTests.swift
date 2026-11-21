import StoreKitTest
import XCTest
@testable import uTermMobile

/// 订阅门禁：「开始用」的入口没订阅时弹订阅页，买成功后接着做；体验主机不受限。
@MainActor
final class SubscriptionGateTests: XCTestCase {
    private func makeHost(_ name: String = "web") -> ServerProfile {
        let host = ServerProfile()
        host.name = name
        host.host = "example.com"
        return host
    }

    func testInactiveBlocksConnectAndShowsPaywall() {
        let subscriptions = SubscriptionStore(fixed: .inactive)
        let store = MobileStore()
        store.subscription = subscriptions
        store.requestConnect(makeHost(), kind: .terminal)
        XCTAssertNil(store.connecting)
        XCTAssertNil(store.openTarget)
        XCTAssertNotNil(subscriptions.paywallRequest)
    }

    func testPurchaseRunsTheBlockedAction() {
        let subscriptions = SubscriptionStore(fixed: .inactive)
        let store = MobileStore()
        store.subscription = subscriptions
        let host = makeHost()
        store.requestConnect(host, kind: .sftp)
        XCTAssertNil(store.connecting)
        subscriptions.apply(.active(productID: SubscriptionStore.yearlyID, expires: nil))
        XCTAssertEqual(store.connecting?.kind, .sftp)
        XCTAssertTrue(store.showWorkspace)
    }

    func testDismissingPaywallDropsTheBlockedAction() {
        let subscriptions = SubscriptionStore(fixed: .inactive)
        let store = MobileStore()
        store.subscription = subscriptions
        store.requestConnect(makeHost(), kind: .terminal)
        subscriptions.paywallDismissed()
        subscriptions.apply(.active(productID: SubscriptionStore.monthlyID, expires: nil))
        XCTAssertNil(store.connecting)
    }

    func testActiveAndUnknownAllow() {
        for status: SubscriptionStore.Status in [.active(productID: "x", expires: nil), .unknown] {
            let subscriptions = SubscriptionStore(fixed: status)
            let store = MobileStore()
            store.subscription = subscriptions
            store.requestConnect(makeHost(), kind: .terminal)
            XCTAssertNotNil(store.connecting, "\(status)")
            XCTAssertNil(subscriptions.paywallRequest)
        }
    }

    func testDemoHostIsNotGated() {
        let subscriptions = SubscriptionStore(fixed: .inactive)
        let store = MobileStore()
        store.subscription = subscriptions
        store.openDemo(.terminal)
        XCTAssertEqual(store.demoRequest?.kind, .terminal)
        XCTAssertTrue(store.showWorkspace)
        XCTAssertNil(subscriptions.paywallRequest)
    }

    func testDemoTabHasNoAgent() {
        let term = TermTab(host: DemoHostProfile.shared, transportFactory: .demo)
        XCTAssertTrue(term.isDemo)
        XCTAssertFalse(term.offersAgent)
        XCTAssertTrue(TermTab(host: makeHost()).offersAgent)
    }

    func testQuickCommandRunIsGated() {
        let subscriptions = SubscriptionStore(fixed: .inactive)
        let store = MobileStore()
        store.subscription = subscriptions
        let host = makeHost()
        let command = QuickCommand()
        command.name = "uptime"
        command.command = "uptime"
        command.serverIDs = [host.id]
        store.runCommand(command, hosts: [host])
        XCTAssertTrue(store.parallelSessions.isEmpty)
        XCTAssertNotNil(subscriptions.paywallRequest)
    }
}

/// 真的走 StoreKit（本地配置 `Config/uTerm.storekit`，不连 App Store）：买、试用资格、过期、恢复。
@MainActor
final class SubscriptionStoreKitTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        try await super.setUp()
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/uTerm.storekit")
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        try await super.tearDown()
    }

    func testProductsMatchConfiguredIDs() async throws {
        let products = try await Product.products(for: SubscriptionStore.productIDs)
        XCTAssertEqual(Set(products.map(\.id)), Set(SubscriptionStore.productIDs))
        let yearly = try XCTUnwrap(products.first { $0.id == SubscriptionStore.yearlyID })
        XCTAssertEqual(yearly.subscription?.introductoryOffer?.paymentMode, .freeTrial)
        let eligible = await yearly.subscription?.isEligibleForIntroOffer
        XCTAssertEqual(eligible, true)
    }

    func testNoPurchaseIsInactive() async {
        let store = SubscriptionStore()
        await store.refresh()
        XCTAssertEqual(store.status, .inactive)
    }

    func testPurchaseMakesActive() async throws {
        let store = SubscriptionStore()
        _ = try await session.buyProduct(identifier: SubscriptionStore.monthlyID)
        await store.refresh()
        guard case .active(let id, let expires) = store.status else { return XCTFail("应在订阅中：\(store.status)") }
        XCTAssertEqual(id, SubscriptionStore.monthlyID)
        XCTAssertNotNil(expires)
    }

    func testRefundRevokes() async throws {
        let store = SubscriptionStore()
        let transaction = try await session.buyProduct(identifier: SubscriptionStore.yearlyID)
        try session.refundTransaction(identifier: UInt(transaction.id))
        await store.refresh()
        XCTAssertEqual(store.status, .inactive)
    }
}
