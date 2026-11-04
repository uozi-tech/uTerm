import XCTest
import UDesignKit
@testable import uTerm

@MainActor
final class SharedPreferencesSyncTests: XCTestCase {
    private static let accent = "accentColor"
    private static let accentModified = "lanSync.preferenceModified.accentColor"

    private var defaults: UserDefaults!
    private var cloud: InMemoryKeyValueStore!

    override func setUp() async throws {
        try await super.setUp()
        let name = "SharedPreferencesSyncTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        self.defaults = defaults
        cloud = InMemoryKeyValueStore()
    }

    private func launch() -> SharedPreferencesSync {
        let sync = SharedPreferencesSync(defaults: defaults, store: cloud)
        sync.start()
        return sync
    }

    private func receiveFromCloud(_ value: String, modifiedAt date: Date) {
        cloud.set(value, forKey: Self.accent)
        cloud.set(date, forKey: Self.accentModified)
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: [Self.accent]])
    }

    func testAppLaunchEntryDoesNotStartInTestHost() {
        let sync = SharedPreferencesSync(defaults: defaults, store: cloud)

        sync.startForAppLaunch()
        defaults.set("red", forKey: Self.accent)

        XCTAssertFalse(sync.isReady)
        XCTAssertNil(cloud.string(forKey: Self.accent))
    }

    func testTestHostDetection() {
        XCTAssertTrue(TestHostEnvironment.isActive)
        XCTAssertFalse(TestHostEnvironment.isActive(environment: [:]))
        XCTAssertTrue(TestHostEnvironment.isActive(environment: ["XCTestConfigurationFilePath": "/x"]))
        XCTAssertTrue(TestHostEnvironment.isActive(environment: ["XCTestBundlePath": "/x"]))
        XCTAssertTrue(TestHostEnvironment.isActive(environment: ["XCTestSessionIdentifier": "x"]))
    }

    func testFirstLaunchWithEmptyCloudKeepsDefaultLocal() {
        _ = launch()

        XCTAssertEqual(defaults.string(forKey: Self.accent), "blue")
        XCTAssertNil(cloud.object(forKey: Self.accent))
        XCTAssertNil(cloud.object(forKey: Self.accentModified))
    }

    /// 上一版种下的默认值：下次启动时 iCloud 还是空的，也不能当成用户的选择推上去。
    func testSeededDefaultFromEarlierLaunchIsNotPublished() {
        defaults.set("blue", forKey: Self.accent)

        _ = launch()

        XCTAssertNil(cloud.object(forKey: Self.accent))
    }

    /// iCloud 里的选择可能是几周前做的，时间戳再旧也要赢过本机刚种的默认值。
    func testCloudValueArrivingAfterSeedWinsEvenWhenOld() {
        let sync = launch()
        withExtendedLifetime(sync) {
            receiveFromCloud("purple", modifiedAt: Date(timeIntervalSinceNow: -30 * 86_400))
        }

        XCTAssertEqual(defaults.string(forKey: Self.accent), "purple")
    }

    func testSeedAtNextLaunchYieldsToExistingCloudValue() {
        defaults.set("blue", forKey: Self.accent)
        cloud.set("purple", forKey: Self.accent)
        cloud.set(Date(timeIntervalSinceNow: -30 * 86_400), forKey: Self.accentModified)

        _ = launch()

        XCTAssertEqual(defaults.string(forKey: Self.accent), "purple")
        XCTAssertEqual(cloud.string(forKey: Self.accent), "purple")
    }

    func testUserChoiceIsPublishedWithTimestamp() {
        let sync = launch()
        let before = Date()

        withExtendedLifetime(sync) { defaults.set("green", forKey: Self.accent) }

        XCTAssertEqual(cloud.string(forKey: Self.accent), "green")
        let stamp = cloud.object(forKey: Self.accentModified) as? Date
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(stamp), before)
    }

    func testPickingDefaultAgainAfterAnotherColorIsPublished() {
        let sync = launch()

        withExtendedLifetime(sync) {
            defaults.set("green", forKey: Self.accent)
            defaults.set("blue", forKey: Self.accent)
        }

        XCTAssertEqual(cloud.string(forKey: Self.accent), "blue")
    }

    /// 同步功能上线前选的颜色没有时间戳，但不等于默认值，确实是用户的选择。
    func testLegacyNonDefaultChoiceWithoutTimestampIsPublished() {
        defaults.set("orange", forKey: Self.accent)

        _ = launch()

        XCTAssertEqual(cloud.string(forKey: Self.accent), "orange")
    }

    func testTimestampedDefaultChoiceIsStillPublished() {
        let chosenAt = Date(timeIntervalSinceNow: -60)
        defaults.set("blue", forKey: Self.accent)
        defaults.set(chosenAt, forKey: Self.accentModified)

        _ = launch()

        XCTAssertEqual(cloud.string(forKey: Self.accent), "blue")
        XCTAssertEqual(cloud.object(forKey: Self.accentModified) as? Date, chosenAt)
    }

    /// 别的设备改了强调色：当前窗口要立刻变，不能等下次启动（用户眼里就是「更新后自己变了」）。
    func testCloudAccentChangeReachesAccentStateWithoutRestart() async {
        let sync = launch()
        let accent = AccentState(defaults: defaults)

        receiveFromCloud("purple", modifiedAt: Date())
        for _ in 0..<200 where accent.selected != .purple {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(accent.selected, .purple)
        XCTAssertEqual(defaults.string(forKey: Self.accent), "purple")
        withExtendedLifetime(sync) {}
    }

    func testOlderCloudValueDoesNotOverrideUserChoice() {
        let sync = launch()
        withExtendedLifetime(sync) {
            defaults.set("green", forKey: Self.accent)
            receiveFromCloud("purple", modifiedAt: Date(timeIntervalSinceNow: -3_600))
        }

        XCTAssertEqual(defaults.string(forKey: Self.accent), "green")
    }
}

private final class InMemoryKeyValueStore: NSUbiquitousKeyValueStore {
    private var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: String?, forKey key: String) { values[key] = value }
    override func synchronize() -> Bool { true }
}
