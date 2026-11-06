import Foundation
import LocalAuthentication
import Observation

/// 「启动时要求验证身份」偏好（两端共用同一个 UserDefaults 键）。
///
/// **键名不能改**：已安装用户的开关值就存在这个键下。两端默认值有意相反——macOS 缺键视作
/// 开（沿用最初的默认），iOS 缺键视作关（由设置里验证一次后开启，见 `AppLockModel.confirmEnable`）。
nonisolated enum AppLockPreference {
    static let key = DefaultsKey.requireAuthAtLaunch

    #if os(macOS)
    static let defaultValue = true
    #else
    static let defaultValue = false
    #endif

    /// 启动时读当前值。用 `object(forKey:) as? Bool` 而非 `bool(forKey:)`：后者缺键时返回
    /// false，会把 mac 的「默认开」误读成「关」。
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? defaultValue
    }
}

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

        /// 锁屏上的状态文案（两端锁屏共用）。
        var message: String {
            switch self {
            case .unlocked:        ""
            case .authenticating:  "正在验证身份…"
            case .locked:          "uTerm 已锁定"
            case .failed(let msg): msg
            }
        }
    }

    private(set) var state: LockState

    private let authenticator: BiometricAuthenticator
    private let reason: String
    private var didStartInitialAuth = false
    /// 验证代次：`relock()` 与每次 `authenticate()` 都递增，晚到的验证结果对不上就丢弃。
    /// 否则退到后台时系统取消验证的 `.canceled` 会在 relock 之后落地、把状态写成 `.failed`，
    /// 回前台的自动验证（只认 `.locked`）就不再弹；更糟的是一次晚到的 `.success` 会直接解锁。
    private var authGeneration = 0

    init(authenticator: BiometricAuthenticator,
         requireAuthAtLaunch: Bool,
         reason: String = "解锁 uTerm") {
        self.authenticator = authenticator
        self.reason = reason
        self.state = requireAuthAtLaunch ? .locked : .unlocked
    }

    var isUnlocked: Bool { state == .unlocked }

    /// 打开应用锁前先验证一次：既确认设备可用（有生物识别或已设密码），也取得用户授权——
    /// 避免开关一拨就把下次启动锁死却无从解锁。有生物识别就强制走生物识别，否则用设备密码。
    /// 目前只有 iOS 的设置开关调用；macOS 开关直接生效（行为未改）。
    static func confirmEnable(
        authenticator: BiometricAuthenticator = SystemBiometricAuthenticator(),
        reason: String = "开启 uTerm 应用锁"
    ) async -> AuthOutcome {
        let policy: LAPolicy
        if case .biometrics = authenticator.availability() {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else {
            policy = .deviceOwnerAuthentication
        }
        return await authenticator.authenticate(policy: policy, reason: reason)
    }

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
        authGeneration &+= 1
        state = .locked
        didStartInitialAuth = false
    }

    /// 触发一次验证（锁屏「解锁」按钮也调它重试）。
    func authenticate() async {
        authGeneration &+= 1
        let generation = authGeneration
        state = .authenticating
        switch authenticator.availability() {
        case .biometrics:
            let outcome = await authenticator.authenticate(
                policy: .deviceOwnerAuthenticationWithBiometrics, reason: reason)
            guard generation == authGeneration else { return }
            switch outcome {
            case .success:
                state = .unlocked
            case .biometryLockout:
                await authenticateWithPassword(generation: generation)   // 指纹被锁 → 退回登录密码
            case .canceled:
                state = .failed("验证已取消")
            case .failed, .unavailable:
                state = .failed("验证失败，请重试")
            }
        case .passwordOnly:
            await authenticateWithPassword(generation: generation)
        }
    }

    private func authenticateWithPassword(generation: Int) async {
        let outcome = await authenticator.authenticate(
            policy: .deviceOwnerAuthentication, reason: reason)
        guard generation == authGeneration else { return }
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
