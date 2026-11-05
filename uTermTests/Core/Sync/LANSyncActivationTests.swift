import XCTest
import SwiftData
@testable import uTerm

/// 移动端（接收端）局域网监听的「是否已启用过」判定：配对码与启用标记都由 `LANSyncCoordinator`
/// 一处读写。只测判定，不调 `start()`——那会真的开 NWListener。
@MainActor
final class LANSyncActivationTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let name = "LANSyncActivationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        self.defaults = defaults
    }

    private func makeCoordinator(role: LANSyncRole) throws -> LANSyncCoordinator {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerProfile.self, configurations: config)
        return LANSyncCoordinator(
            role: role,
            preferences: SharedPreferencesSync(defaults: defaults, store: NoopKeyValueStore()),
            dataStore: LANSyncDataStore(container: container),
            defaults: defaults)
    }

    func testFreshReceiverIsNotActivated() throws {
        let lan = try makeCoordinator(role: .receiver)
        XCTAssertFalse(lan.isReceiverActivated)
        XCTAssertEqual(lan.status, .stopped)
        lan.resumeIfActivated()
        XCTAssertEqual(lan.status, .stopped, "没启用过就不开始监听（不弹本地网络授权）")
    }

    /// 升级前就配过配对码的老用户算已启用；配对码的读写只经协调器。
    func testPairingCodeCountsAsActivated() throws {
        let lan = try makeCoordinator(role: .receiver)
        lan.setPairingCode("12a3456789")
        XCTAssertEqual(lan.pairingCode, "123456")
        XCTAssertEqual(defaults.string(forKey: "lanSync.pairingCode"), "123456")
        XCTAssertTrue(lan.isReceiverActivated)

        let relaunched = try makeCoordinator(role: .receiver)
        XCTAssertEqual(relaunched.pairingCode, "123456")
        XCTAssertTrue(relaunched.isReceiverActivated)

        relaunched.setPairingCode("")
        XCTAssertFalse(relaunched.isReceiverActivated)
    }

    func testActivatedFlagPersists() throws {
        defaults.set(true, forKey: "lanSync.receiverActivated")
        XCTAssertTrue(try makeCoordinator(role: .receiver).isReceiverActivated)
    }

    func testSenderIsNeverReceiverActivated() throws {
        defaults.set(true, forKey: "lanSync.receiverActivated")
        let lan = try makeCoordinator(role: .sender)
        XCTAssertFalse(lan.isReceiverActivated)
    }
}

private final class NoopKeyValueStore: NSUbiquitousKeyValueStore {}
