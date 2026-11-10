import Foundation
import Observation

/// 「应用锁」开关的开启流程（两端设置页共用：mac 设置 · 安全、iOS 设置根页）。
///
/// 开启前先验证一次（确认设备可用 + 取得用户授权），成功才真正写入，避免一拨开关就把
/// 下次启动锁死却无从解锁；验证不可用时弹提示。关闭直接生效。
@MainActor @Observable
final class AppLockToggleModel {
    /// 偏好里的当前值（`AppLockPreference.key`）。验证进行中保持旧值。
    private(set) var isOn: Bool
    /// 设备没有可用的验证方式（没录 Face ID / 触控 ID、也没设锁屏密码），视图据此弹提示。
    var unavailableAlert = false

    /// 「无法开启」提示的标题与说明（两端视图挂 `.alert` 用）。说明按平台给出系统里该去哪设。
    nonisolated static let unavailableTitle = "无法开启应用锁"
    #if os(macOS)
    nonisolated static let unavailableMessage = "先在「系统设置」里录入触控 ID 或设置登录密码，再开启应用锁。"
    #else
    nonisolated static let unavailableMessage = "先在「设置」App 里启用面容 ID / 触控 ID 或设置锁屏密码，再开启应用锁。"
    #endif

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let confirm: @MainActor () async -> AuthOutcome

    init(defaults: UserDefaults = .standard,
         confirm: @escaping @MainActor () async -> AuthOutcome = { await AppLockModel.confirmEnable() }) {
        self.defaults = defaults
        self.confirm = confirm
        self.isOn = AppLockPreference.isEnabled(in: defaults)
    }

    /// 开关的 setter：关直接写，开先验证。
    func set(_ wantOn: Bool) {
        guard wantOn else { write(false); return }
        Task { await requestEnable() }
    }

    func requestEnable() async {
        let outcome = await confirm()
        if case .success = outcome {
            write(true)
        } else {
            write(false)
            if case .unavailable = outcome { unavailableAlert = true }
        }
    }

    private func write(_ value: Bool) {
        defaults.set(value, forKey: AppLockPreference.key)
        isOn = value
    }
}
