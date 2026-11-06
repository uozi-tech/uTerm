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
        static let enabled = PreferenceKey.remoteEnabled
        static let desktopEnabled = PreferenceKey.remoteDesktopEnabled
        static let localShellEnabled = PreferenceKey.remoteLocalShellEnabled
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

    /// 「允许远程桌面」：在远控总开关之上再单独开一次（默认关）。看屏幕、动鼠标键盘比接管终端
    /// 交出去的更多，不能因为开了终端远控就顺带打开。
    var isDesktopEnabled: Bool {
        didSet {
            guard isDesktopEnabled != oldValue else { return }
            defaults.set(isDesktopEnabled, forKey: Keys.desktopEnabled)
            onChange?(self)
        }
    }

    /// 「允许手机打开本机终端」：手机能在这台 Mac 上开一个登录 shell（默认关）。那是这个用户账户的全部
    /// 权限，比接管已经开着的终端更大，也单独开一次。
    var isLocalShellEnabled: Bool {
        didSet {
            guard isLocalShellEnabled != oldValue else { return }
            defaults.set(isLocalShellEnabled, forKey: Keys.localShellEnabled)
            onChange?(self)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        isDesktopEnabled = defaults.object(forKey: Keys.desktopEnabled) as? Bool ?? false
        isLocalShellEnabled = defaults.object(forKey: Keys.localShellEnabled) as? Bool ?? false
    }

    /// 开关变化时回调（起停 `RemoteHostServer`）。设置后立即回调一次，与持久化状态对齐。
    func observe(_ handler: @escaping @MainActor (RemoteControlSettings) -> Void) {
        onChange = handler
        handler(self)
    }
}
