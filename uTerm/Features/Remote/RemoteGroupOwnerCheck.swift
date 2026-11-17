import Foundation
import LocalAuthentication

/// 设备组里的敏感操作前验证本人（docs/remote-device-group-design.md §19）：移除组员、输入验证码把别的设备加进组、
/// 离开设备组之前，调一次本机验证（iOS 面容 ID / 触控 ID / 密码，Mac 触控 ID / 登录密码）。
///
/// 挡的是「拿到一台解锁的设备、只会点界面」的人（docs/remote-group-trust-research.md 第 2 节），不是密码学上的保证：
/// 签名私钥还在设备里，取得出密钥的人不受它约束。
///
/// 规则：
/// - 通过：放行，记下时间；之后 5 分钟内同一台设备上不再验（一次移除好几台、连着加两台设备只验一次）。
/// - 不可用（设备没设密码、Mac 上没法验证）：放行，记一行日志。没有可验证的东西，不能把人锁在外面。
/// - 取消、失败、生物识别被锁定：不放行，调用方什么都不做。
/// - 测试宿主里默认直接放行（快照和别的用例不能弹系统验证框）；用例里注入假的 `BiometricAuthenticator` 测规则。
///
/// 应用锁刚解锁不算一次：`AppLockModel` 没有记解锁时间。
///
/// 两端共享，由 `RemoteDeviceGroupService` 持有；界面只调服务上带验证的入口，不直接调模型（`RemoteGroupOwnerCheckLintTests`）。
@MainActor
final class RemoteGroupOwnerCheck {
    /// 要验证的操作。只用来写系统验证框上的那句说明。
    enum Action: Equatable {
        /// 移除组员：你点的那台的名字，和一共几台（含连带的）。
        case remove(name: String, count: Int)
        /// 输入验证码，把这台设备加进组。
        case admit(name: String)
        case leave

        /// 系统验证框上的说明（`localizedReason`）：一句动宾短语，macOS 会在前面加上「“uTerm”正在尝试」。
        var reason: String {
            switch self {
            case .remove(let name, let count): RemoteDeviceGroupCopy.ownerCheckRemove(name: name, count: count)
            case .admit(let name): RemoteDeviceGroupCopy.ownerCheckAdmit(name: name)
            case .leave: RemoteDeviceGroupCopy.ownerCheckLeave
            }
        }
    }

    /// 验证通过后多久内不再验。
    static let gracePeriod: TimeInterval = 5 * 60

    /// nil = 不验（测试宿主里的默认）。
    private let authenticator: (any BiometricAuthenticator)?
    private let now: () -> Date
    /// 上一次验证通过的时刻。只在内存：App 重开后要重新验。
    private(set) var lastVerified: Date?
    /// 正在验的那一次：同时来的第二次等它结束再判断（免得连点两下弹两个验证框）。
    private var inFlight: Task<AuthOutcome, Never>?

    init(authenticator: (any BiometricAuthenticator)? = RemoteGroupOwnerCheck.defaultAuthenticator(),
         now: @escaping () -> Date = Date.init) {
        self.authenticator = authenticator
        self.now = now
    }

    /// App 里驱动系统 `LAContext`；测试宿主里为 nil（直接放行）。
    static func defaultAuthenticator() -> (any BiometricAuthenticator)? {
        RemoteLocalState.isIsolated ? nil : SystemBiometricAuthenticator()
    }

    /// 刚验证过（5 分钟内）。时间差为负（钟往回拨了）不算。
    var isFresh: Bool {
        guard let lastVerified else { return false }
        let age = now().timeIntervalSince(lastVerified)
        return age >= 0 && age < Self.gracePeriod
    }

    /// 这个操作能不能做：要验就弹系统验证框，等结果。
    func confirm(_ action: Action) async -> Bool {
        while let pending = inFlight { _ = await pending.value }
        if isFresh { return true }
        guard let authenticator else { return true }
        let reason = action.reason
        // 结果在这个任务里落下（记时间、清 `inFlight`），等着它的几处醒来时看到的已经是新状态；放到 `await` 之后再清，
        // 先醒的那一处会对着一个已经完成、还没清掉的任务原地空转。
        let task = Task { () -> AuthOutcome in
            let outcome = await authenticator.authenticate(policy: .deviceOwnerAuthentication, reason: reason)
            if outcome == .success { lastVerified = now() }
            inFlight = nil
            return outcome
        }
        inFlight = task
        let outcome = await task.value
        switch outcome {
        case .success:
            return true
        case .unavailable:
            AppLogger.notice("设备组：本机无法验证本人（未设密码或不支持），直接放行「\(reason)」", category: RemoteLog.category)
            return true
        case .canceled, .failed, .biometryLockout:
            AppLogger.notice("设备组：验证本人未通过（\(outcome)），不执行「\(reason)」", category: RemoteLog.category)
            return false
        }
    }
}
