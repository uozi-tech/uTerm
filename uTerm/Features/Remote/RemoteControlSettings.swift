import Foundation
import Observation

/// 「允许手机远程控制终端」开关，持久化在 UserDefaults。
///
/// 默认**关闭**：打开后，同一局域网里配对过的设备能接入这台 Mac 上已打开的终端，等于交出
/// 这些 shell，所以要用户在设置里明确开一次。关着时连 Bonjour 都不广播。
@MainActor
@Observable
final class RemoteControlSettings {
    enum Keys {
        static let enabled = "remote.enabled"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var onChange: (@MainActor (RemoteControlSettings) -> Void)?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            onChange?(self)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
    }

    /// 开关变化时回调（起停 `RemoteHostServer`）。设置后立即回调一次，与持久化状态对齐。
    func observe(_ handler: @escaping @MainActor (RemoteControlSettings) -> Void) {
        onChange = handler
        handler(self)
    }
}
