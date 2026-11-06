import XCTest
@testable import uTerm

/// iOS 应用锁开关的开启流程（`AppLockToggleModel`），验证换成假实现，不弹系统窗。
@MainActor
final class AppLockToggleModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppLockToggleModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
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
}
