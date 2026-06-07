import LocalAuthentication

/// 机器当前能用哪种验证方式（只区分「有生物识别」与「只能密码」）。
enum BiometryAvailability {
    case biometrics    // 已录入 Touch ID，可强制指纹
    case passwordOnly  // 无硬件 / 未录入 → 只能走登录密码
}

/// 一次验证的结果（把 `LAError` 收敛成业务语义）。
enum AuthOutcome {
    case success         // 验证通过
    case failed          // 指纹不匹配 / 其它错误
    case canceled        // 用户取消 / 系统取消
    case biometryLockout // 生物识别连错被系统锁定 → 需退回密码
    case unavailable     // 该策略当前不可用（未录入 / 未设密码等）
}

/// 把 `LAContext` 藏在协议后面，`AppLockModel` 才能脱离系统弹窗单测。
protocol BiometricAuthenticator {
    /// 是否已录入生物识别（调 `canEvaluatePolicy`）。
    func availability() -> BiometryAvailability
    /// 触发系统验证弹窗，返回收敛后的结果。
    func authenticate(policy: LAPolicy, reason: String) async -> AuthOutcome
}

/// 真实实现：直接驱动系统 `LAContext`。每次验证用全新实例（LAContext 一次性用）。
struct SystemBiometricAuthenticator: BiometricAuthenticator {
    func availability() -> BiometryAvailability {
        let ctx = LAContext()
        // 只关心能否用生物识别；失败原因（error）无需读取——enum 故意只分两档。
        let canBiometrics = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return canBiometrics ? .biometrics : .passwordOnly
    }

    func authenticate(policy: LAPolicy, reason: String) async -> AuthOutcome {
        let ctx = LAContext()
        do {
            // evaluatePolicy 的 async 版要么返回 true、要么抛错，不会返回 false。
            _ = try await ctx.evaluatePolicy(policy, localizedReason: reason)
            return .success
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .canceled
            case .biometryLockout:
                return .biometryLockout
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                return .unavailable
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}
