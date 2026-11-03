import XCTest
import LocalAuthentication
@testable import uTerm

/// 可编排的假验证器：指定 availability 与按调用顺序弹出的 outcome，记录每次用的 policy。
@MainActor
final class FakeBiometricAuthenticator: BiometricAuthenticator {
    var availabilityToReturn: BiometryAvailability = .biometrics
    var outcomes: [AuthOutcome] = []
    private(set) var recordedPolicies: [LAPolicy] = []
    private(set) var callCount = 0

    func availability() -> BiometryAvailability { availabilityToReturn }

    func authenticate(policy: LAPolicy, reason: String) async -> AuthOutcome {
        callCount += 1
        recordedPolicies.append(policy)
        return outcomes.isEmpty ? .failed : outcomes.removeFirst()
    }
}

@MainActor
final class AppLockModelTests: XCTestCase {

    private func makeModel(
        availability: BiometryAvailability = .biometrics,
        outcomes: [AuthOutcome] = [],
        requireAuth: Bool = true
    ) -> (AppLockModel, FakeBiometricAuthenticator) {
        let fake = FakeBiometricAuthenticator()
        fake.availabilityToReturn = availability
        fake.outcomes = outcomes
        let model = AppLockModel(authenticator: fake, requireAuthAtLaunch: requireAuth)
        return (model, fake)
    }

    private func assertFailed(_ model: AppLockModel, file: StaticString = #filePath, line: UInt = #line) {
        if case .failed = model.state {} else {
            XCTFail("expected .failed, got \(model.state)", file: file, line: line)
        }
    }

    func testLockedInitiallyWhenEnabled() {
        let (model, _) = makeModel(requireAuth: true)
        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.isUnlocked)
    }

    func testUnlockedInitiallyWhenDisabled() {
        let (model, _) = makeModel(requireAuth: false)
        XCTAssertEqual(model.state, .unlocked)
        XCTAssertTrue(model.isUnlocked)
    }

    func testBiometricsSuccessUsesBiometricsOnlyPolicy() async {
        let (model, fake) = makeModel(availability: .biometrics, outcomes: [.success])
        await model.authenticate()
        XCTAssertEqual(model.state, .unlocked)
        XCTAssertEqual(fake.recordedPolicies, [.deviceOwnerAuthenticationWithBiometrics])
    }

    func testBiometricsFailureStaysLocked() async {
        let (model, fake) = makeModel(availability: .biometrics, outcomes: [.failed])
        await model.authenticate()
        assertFailed(model)
        XCTAssertFalse(model.isUnlocked)
        XCTAssertEqual(fake.recordedPolicies, [.deviceOwnerAuthenticationWithBiometrics])
    }

    func testUnavailableOutcomeStaysLocked() async {
        let (model, fake) = makeModel(availability: .biometrics, outcomes: [.unavailable])
        await model.authenticate()
        assertFailed(model)
        XCTAssertFalse(model.isUnlocked)
        XCTAssertEqual(fake.recordedPolicies, [.deviceOwnerAuthenticationWithBiometrics])
    }

    func testBiometryLockoutFallsBackToPassword() async {
        let (model, fake) = makeModel(availability: .biometrics, outcomes: [.biometryLockout, .success])
        await model.authenticate()
        XCTAssertEqual(model.state, .unlocked)
        XCTAssertEqual(fake.recordedPolicies,
                       [.deviceOwnerAuthenticationWithBiometrics, .deviceOwnerAuthentication])
    }

    func testNoBiometricsUsesPasswordPolicy() async {
        let (model, fake) = makeModel(availability: .passwordOnly, outcomes: [.success])
        await model.authenticate()
        XCTAssertEqual(model.state, .unlocked)
        XCTAssertEqual(fake.recordedPolicies, [.deviceOwnerAuthentication])
    }

    func testCancelStaysLockedThenCanRetry() async {
        let (model, fake) = makeModel(availability: .biometrics, outcomes: [.canceled, .success])
        await model.authenticate()
        assertFailed(model)
        await model.authenticate()
        XCTAssertEqual(model.state, .unlocked)
        XCTAssertEqual(fake.callCount, 2)
    }

    func testStartInitialAuthOnlyRunsOnce() async {
        let (model, fake) = makeModel(availability: .biometrics, outcomes: [.success])
        await model.startInitialAuthIfNeeded()
        await model.startInitialAuthIfNeeded()
        XCTAssertEqual(model.state, .unlocked)
        XCTAssertEqual(fake.callCount, 1)
    }

    func testStartInitialAuthSkipsWhenDisabled() async {
        let (model, fake) = makeModel(requireAuth: false)
        await model.startInitialAuthIfNeeded()
        XCTAssertEqual(fake.callCount, 0)
        XCTAssertTrue(model.isUnlocked)
    }

    /// iOS 从后台回前台：relock() 把状态拨回 .locked 并重置首验 guard，可再次触发验证。
    func testRelockReArmsInitialAuth() async {
        let (model, fake) = makeModel(availability: .biometrics, outcomes: [.success, .success])
        await model.startInitialAuthIfNeeded()
        XCTAssertEqual(model.state, .unlocked)
        XCTAssertEqual(fake.callCount, 1)

        model.relock()
        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.isUnlocked)

        await model.startInitialAuthIfNeeded()
        XCTAssertEqual(model.state, .unlocked)
        XCTAssertEqual(fake.callCount, 2)
    }

    // MARK: - relock 与在途验证交错（iOS 退后台时系统会取消正在弹的验证）

    /// relock 之后才落地的验证结果一律作废：晚到的 `.success` 不能解锁，
    /// 晚到的 `.canceled` 也不能把状态写成 `.failed`（否则回前台的自动验证只认 `.locked`，不再弹）。
    func testOutcomeArrivingAfterRelockIsIgnored() async {
        for late in [AuthOutcome.success, .canceled] {
            let gate = GatedBiometricAuthenticator()
            let model = AppLockModel(authenticator: gate, requireAuthAtLaunch: true)
            let auth = Task { await model.authenticate() }
            await gate.waitUntilAsked()
            XCTAssertEqual(model.state, .authenticating)

            model.relock()
            gate.release(late)
            await auth.value

            XCTAssertEqual(model.state, .locked, "relock 后晚到的 \(late) 改了状态")
            // 回前台的首验仍能触发。
            gate.nextOutcome = .success
            await model.startInitialAuthIfNeeded()
            XCTAssertEqual(model.state, .unlocked)
        }
    }
}

/// 验证请求挂起，直到测试手动放行；用来编排「验证还在弹、App 已经退到后台」。
@MainActor
final class GatedBiometricAuthenticator: BiometricAuthenticator {
    private var pending: CheckedContinuation<AuthOutcome, Never>?
    private var askedWaiters: [CheckedContinuation<Void, Never>] = []
    /// 放行之后的请求直接返回这个结果。
    var nextOutcome: AuthOutcome?

    func availability() -> BiometryAvailability { .biometrics }

    func authenticate(policy: LAPolicy, reason: String) async -> AuthOutcome {
        if let nextOutcome { return nextOutcome }
        return await withCheckedContinuation { cont in
            pending = cont
            askedWaiters.forEach { $0.resume() }
            askedWaiters.removeAll()
        }
    }

    func waitUntilAsked() async {
        guard pending == nil else { return }
        await withCheckedContinuation { askedWaiters.append($0) }
    }

    func release(_ outcome: AuthOutcome) {
        pending?.resume(returning: outcome)
        pending = nil
    }
}
