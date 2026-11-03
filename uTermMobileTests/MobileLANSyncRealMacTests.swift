import AgentKit
import SwiftData
import XCTest
@testable import uTermMobile

/// 真 Mac → 本机的局域网同步：在测试进程里起一个接收端（内存容器，用完即弃），等 Mac 上的
/// uTerm 点「发送同步」，由用例自己确认，然后核对收到的数据。
///
/// 默认跳过——要人在 Mac 那一侧点发送，只在手动验证时跑：
///
///     TEST_RUNNER_UTERM_LAN_PAIRING_CODE=<Mac 设置 › 高级里的 6 位码> xcodebuild test \
///       -only-testing:uTermMobileTests/MobileLANSyncRealMacTests …
///
/// 跑之前先关掉宿主 app 自己的局域网接收（`lanSync.receiverActivated` / `lanSync.pairingCode`），
/// 否则两个接收端同名广播，Mac 那边会看到两台设备。凭据正文会经 `LANSyncSecretStore` 写进本机
/// 钥匙串，验证完应重置模拟器钥匙串。
@MainActor
final class MobileLANSyncRealMacTests: XCTestCase {

    func testReceiveFullSyncFromRealMac() async throws {
        guard let code = ProcessInfo.processInfo.environment["UTERM_LAN_PAIRING_CODE"] else {
            throw XCTSkip("未配置 UTERM_LAN_PAIRING_CODE，跳过真 Mac 同步用例")
        }
        let container = try MobileFixtures.emptyContainer()
        let suite = "lan-real-mac-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let receiver = LANSyncCoordinator(
            role: .receiver, preferences: SharedPreferencesSync(defaults: defaults),
            dataStore: LANSyncDataStore(container: container), defaults: defaults)
        defer {
            receiver.stop()
            defaults.removePersistentDomain(forName: suite)
        }
        receiver.setPairingCode(code)
        receiver.start()
        let hosting = await waitUntil(timeout: 20) { receiver.status == .hosting }
        XCTAssertTrue(hosting, "接收端没起来：\(receiver.status)")
        print("[lan-real] listening")

        let offered = await waitUntil(timeout: 240) { receiver.pendingOffer != nil }
        let offer = try XCTUnwrap(receiver.pendingOffer, "4 分钟内没收到 Mac 的同步请求：\(receiver.status)")
        XCTAssertTrue(offered)
        print("[lan-real] offer from \(offer.deviceName): records=\(offer.recordCount) "
              + "prefs=\(offer.preferenceCount) secrets=\(offer.secretCount) chunks=\(offer.chunkCount)")

        receiver.confirmPendingSync()
        let done = await waitUntil(timeout: 120) { receiver.lastSyncedAt != nil || isError(receiver.status) }
        XCTAssertTrue(done && receiver.lastSyncedAt != nil, "同步没有完成：\(receiver.status)")
        XCTAssertEqual(receiver.status, .hosting)

        let check = ModelContext(container)
        let counts: [(String, Int)] = [
            ("ServerProfile", try check.fetchCount(FetchDescriptor<ServerProfile>())),
            ("ServerGroup", try check.fetchCount(FetchDescriptor<ServerGroup>())),
            ("KnownHost", try check.fetchCount(FetchDescriptor<KnownHost>())),
            ("SSHKey", try check.fetchCount(FetchDescriptor<SSHKey>())),
            ("AIProvider", try check.fetchCount(FetchDescriptor<AIProvider>())),
            ("ForwardingRule", try check.fetchCount(FetchDescriptor<ForwardingRule>())),
            ("QuickCommand", try check.fetchCount(FetchDescriptor<QuickCommand>())),
            ("QuickCommandRun", try check.fetchCount(FetchDescriptor<QuickCommandRun>())),
            ("ChatSession", try check.fetchCount(FetchDescriptor<ChatSession>())),
            ("ChatMessageRecord", try check.fetchCount(FetchDescriptor<ChatMessageRecord>())),
        ]
        let total = counts.reduce(0) { $0 + $1.1 }
        print("[lan-real] received " + counts.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
              + " total=\(total)")
        print("[lan-real] offered=\(offer.recordCount) stored=\(total)")
        // Mac 那边若有同主键的重复记录，这里会合成一份，所以落库条数可以少于声明条数，但不会多。
        XCTAssertLessThanOrEqual(total, offer.recordCount)
        XCTAssertGreaterThan(total, 0)
    }

    private func isError(_ status: LANSyncCoordinator.Status) -> Bool {
        if case .error = status { return true }
        return false
    }

    private func waitUntil(timeout seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }
}
