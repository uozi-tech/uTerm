import Foundation
import LocalAuthentication
import Observation

/// 启动应用锁的状态机。持锁定态、按机器能力选验证策略、指纹锁定时退回登录密码、
/// 用一次性 guard 保证多窗口只触发一次启动验证。
///
/// 验证策略（兑现「有指纹必须指纹」）：
///  - 已录指纹 → `.deviceOwnerAuthenticationWithBiometrics`（系统弹窗不出「输入密码」，强制指纹）；
///  - 无 / 未录指纹 → `.deviceOwnerAuthentication`（macOS 登录密码）；
///  - 指纹连错被锁（`.biometryLockout`）→ 退回 `.deviceOwnerAuthentication` 让用户用密码自救。
@MainActor
@Observable
final class AppLockModel {

    enum LockState: Equatable {
        case unlocked
        case authenticating
        case locked
        case failed(String)
    }

    private(set) var state: LockState

    private let authenticator: BiometricAuthenticator
    private let reason: String
    private var didStartInitialAuth = false

    init(authenticator: BiometricAuthenticator,
         requireAuthAtLaunch: Bool,
         reason: String = "解锁 uTerm") {
        self.authenticator = authenticator
        self.reason = reason
        self.state = requireAuthAtLaunch ? .locked : .unlocked
    }

    var isUnlocked: Bool { state == .unlocked }

    /// 各 Scene 的 `AppLockGate` 在 `.task` 里调用；didStart guard 保证全 App 只跑一次首验，
    /// 且 `state == .locked` 判断让重试期间（已 .authenticating）的重复调用安全空转。
    func startInitialAuthIfNeeded() async {
        guard !didStartInitialAuth else { return }
        didStartInitialAuth = true
        guard state == .locked else { return }
        await authenticate()
    }

    /// iOS：从后台回前台时重新上锁（macOS 仅冷启动，用不到）。把状态拨回 `.locked`
    /// 并重置首验 guard，让下一次 `startInitialAuthIfNeeded()` 能再触发一次系统验证。
    func relock() {
        state = .locked
        didStartInitialAuth = false
    }

    /// 触发一次验证（锁屏「解锁」按钮也调它重试）。
    func authenticate() async {
        state = .authenticating
        switch authenticator.availability() {
        case .biometrics:
            let outcome = await authenticator.authenticate(
                policy: .deviceOwnerAuthenticationWithBiometrics, reason: reason)
            switch outcome {
            case .success:
                state = .unlocked
            case .biometryLockout:
                await authenticateWithPassword()   // 指纹被锁 → 退回登录密码
            case .canceled:
                state = .failed("验证已取消")
            case .failed, .unavailable:
                state = .failed("验证失败，请重试")
            }
        case .passwordOnly:
            await authenticateWithPassword()
        }
    }

    private func authenticateWithPassword() async {
        let outcome = await authenticator.authenticate(
            policy: .deviceOwnerAuthentication, reason: reason)
        switch outcome {
        case .success:
            state = .unlocked
        case .canceled:
            state = .failed("验证已取消")
        case .failed, .biometryLockout, .unavailable:
            state = .failed("验证失败，请重试")
        }
    }
}
