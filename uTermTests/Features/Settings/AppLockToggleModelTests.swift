import XCTest
@testable import uTerm

/// 应用锁开关的开启流程（`AppLockToggleModel`，两端设置页共用），验证换成假实现，不弹系统窗。
@MainActor
final class AppLockToggleModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AppLockToggleModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func model(_ outcome: AuthOutcome, calls: Counter = Counter()) -> AppLockToggleModel {
        AppLockToggleModel(defaults: defaults, confirm: {
            calls.count += 1
            return outcome
        })
    }

    @MainActor final class Counter { var count = 0 }

    func testInitialValueFollowsPlatformDefaultWhenUnset() {
        XCTAssertEqual(model(.success).isOn, AppLockPreference.defaultValue)
        defaults.set(true, forKey: AppLockPreference.key)
        XCTAssertTrue(model(.success).isOn)
    }

    func testEnableWritesOnlyAfterSuccessfulConfirm() async {
        let calls = Counter()
        let m = model(.success, calls: calls)
        await m.requestEnable()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(m.isOn)
        XCTAssertEqual(defaults.object(forKey: AppLockPreference.key) as? Bool, true)
        XCTAssertFalse(m.unavailableAlert)
    }

    func testCanceledConfirmLeavesItOffWithoutAlert() async {
        let m = model(.canceled)
        await m.requestEnable()
        XCTAssertFalse(m.isOn)
        XCTAssertEqual(defaults.object(forKey: AppLockPreference.key) as? Bool, false)
        XCTAssertFalse(m.unavailableAlert)
    }

    func testUnavailableShowsAlert() async {
        let m = model(.unavailable)
        await m.requestEnable()
        XCTAssertFalse(m.isOn)
        XCTAssertTrue(m.unavailableAlert)
    }

    func testTurningOffSkipsConfirm() {
        defaults.set(true, forKey: AppLockPreference.key)
        let calls = Counter()
        let m = model(.failed, calls: calls)
        m.set(false)
        XCTAssertFalse(m.isOn)
        XCTAssertEqual(defaults.object(forKey: AppLockPreference.key) as? Bool, false)
        XCTAssertEqual(calls.count, 0)
    }

    /// mac 缺键视作开（`AppLockPreference.defaultValue`）：从没碰过开关的用户直接关，不验证、立刻写 false。
    func testTurningOffFromMissingKeyDefaultSkipsConfirm() {
        XCTAssertNil(defaults.object(forKey: AppLockPreference.key))
        let calls = Counter()
        let m = model(.failed, calls: calls)
        XCTAssertEqual(m.isOn, AppLockPreference.defaultValue)
        #if os(macOS)
        XCTAssertTrue(m.isOn, "mac 缺键默认开")
        #endif
        m.set(false)
        XCTAssertFalse(m.isOn)
        XCTAssertEqual(defaults.object(forKey: AppLockPreference.key) as? Bool, false)
        XCTAssertEqual(calls.count, 0)
    }

    func testUnavailableCopyIsPresent() {
        XCTAssertEqual(AppLockToggleModel.unavailableTitle, "无法开启应用锁")
        XCTAssertFalse(AppLockToggleModel.unavailableMessage.isEmpty)
        #if os(macOS)
        XCTAssertFalse(AppLockToggleModel.unavailableMessage.contains("Face ID"), "mac 没有 Face ID")
        #endif
    }
}
