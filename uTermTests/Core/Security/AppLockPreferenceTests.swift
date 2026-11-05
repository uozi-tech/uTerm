import XCTest
import LocalAuthentication
@testable import uTerm

@MainActor
final class AppLockPreferenceTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppLockPreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testKeyIsTheShippedOne() {
        // 已安装用户的开关值存在这个键下，改名 = 所有人的设置丢失。
        XCTAssertEqual(AppLockPreference.key, "requireAuthAtLaunch")
    }

    func testMissingKeyFallsBackToPlatformDefault() {
        XCTAssertTrue(AppLockPreference.defaultValue, "macOS 缺键视作开")
        XCTAssertEqual(AppLockPreference.isEnabled(in: defaults), AppLockPreference.defaultValue)
    }

    func testExplicitValueWins() {
        defaults.set(false, forKey: AppLockPreference.key)
        XCTAssertFalse(AppLockPreference.isEnabled(in: defaults))
        defaults.set(true, forKey: AppLockPreference.key)
        XCTAssertTrue(AppLockPreference.isEnabled(in: defaults))
    }

    func testLockStateMessages() {
        XCTAssertEqual(AppLockModel.LockState.unlocked.message, "")
        XCTAssertEqual(AppLockModel.LockState.authenticating.message, "正在验证身份…")
        XCTAssertEqual(AppLockModel.LockState.locked.message, "uTerm 已锁定")
        XCTAssertEqual(AppLockModel.LockState.failed("验证已取消").message, "验证已取消")
    }

    func testConfirmEnableUsesBiometricsWhenEnrolled() async {
        let fake = FakeBiometricAuthenticator()
        fake.availabilityToReturn = .biometrics
        fake.outcomes = [.success]
        let outcome = await AppLockModel.confirmEnable(authenticator: fake)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(fake.recordedPolicies, [.deviceOwnerAuthenticationWithBiometrics])
    }

    func testConfirmEnableFallsBackToPasscodeWithoutBiometrics() async {
        let fake = FakeBiometricAuthenticator()
        fake.availabilityToReturn = .passwordOnly
        fake.outcomes = [.unavailable]
        let outcome = await AppLockModel.confirmEnable(authenticator: fake)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(fake.recordedPolicies, [.deviceOwnerAuthentication])
    }
}
