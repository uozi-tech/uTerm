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
        static let enabled = DefaultsKey.remoteEnabled
        static let desktopEnabled = DefaultsKey.remoteDesktopEnabled
        static let desktopUnlockEnabled = DefaultsKey.remoteDesktopUnlockEnabled
        static let desktopAudioEnabled = DefaultsKey.remoteDesktopAudioEnabled
        static let localShellEnabled = DefaultsKey.remoteLocalShellEnabled
        static let internetEnabled = DefaultsKey.remoteInternetEnabled
        static let internetDevices = DefaultsKey.remoteInternetDevices
        static let keepAwakeForInternet = DefaultsKey.remoteKeepAwakeForInternet
        static let deviceVouching = DefaultsKey.remoteDeviceVouching
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

    /// 「允许远程解锁」：Mac 锁屏时，配对过的手机能用登录密码解锁并进入帘幕模式（默认关）。在远程桌面之上
    /// 再单独开一次——解锁等于交出这台 Mac 的登录，比看屏幕更重。
    var isDesktopUnlockEnabled: Bool {
        didSet {
            guard isDesktopUnlockEnabled != oldValue else { return }
            defaults.set(isDesktopUnlockEnabled, forKey: Keys.desktopUnlockEnabled)
            onChange?(self)
        }
    }

    /// 「允许传输声音」：看桌面时把 Mac 的系统声音传到手机（默认开）。授权就是屏幕录制那一项（系统里叫
    /// 「录屏与系统录音」），所以不用再授权；手机上的扬声器按钮默认关，打开才传。
    var isDesktopAudioEnabled: Bool {
        didSet {
            guard isDesktopAudioEnabled != oldValue else { return }
            defaults.set(isDesktopAudioEnabled, forKey: Keys.desktopAudioEnabled)
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

    /// 「允许经公网接入」（默认关）：Mac 注册到中继，勾选过的设备不在同一局域网也能连。
    var isInternetEnabled: Bool {
        didSet {
            guard isInternetEnabled != oldValue else { return }
            defaults.set(isInternetEnabled, forKey: Keys.internetEnabled)
            onChange?(self)
        }
    }

    /// 允许经公网接入的设备。不因为配对过就自动有：要在设置里逐台打开。
    var internetDevices: Set<UUID> {
        didSet {
            guard internetDevices != oldValue else { return }
            defaults.set(internetDevices.map(\.uuidString).sorted(), forKey: Keys.internetDevices)
            onChange?(self)
        }
    }

    /// 打开公网接入期间不让 Mac 闲置睡眠（默认关）：睡着就掉线，中继叫不醒它。
    var keepsAwakeForInternet: Bool {
        didSet {
            guard keepsAwakeForInternet != oldValue else { return }
            defaults.set(keepsAwakeForInternet, forKey: Keys.keepAwakeForInternet)
            onChange?(self)
        }
    }

    /// 「允许已配对的设备为它主人的其它设备开通」（默认开）。不让已配对设备多出权力：它本来就能经远程桌面
    /// 打开这里出一张邀请。关掉后担保一律拒绝，已经开通的设备不受影响。
    var isDeviceVouchingEnabled: Bool {
        didSet {
            guard isDeviceVouchingEnabled != oldValue else { return }
            defaults.set(isDeviceVouchingEnabled, forKey: Keys.deviceVouching)
            onChange?(self)
        }
    }

    func allowsInternetAccess(_ id: UUID) -> Bool {
        isEnabled && isInternetEnabled && internetDevices.contains(id)
    }

    init(defaults: UserDefaults = RemoteLocalState.defaults) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        isDesktopEnabled = defaults.object(forKey: Keys.desktopEnabled) as? Bool ?? false
        isDesktopUnlockEnabled = defaults.object(forKey: Keys.desktopUnlockEnabled) as? Bool ?? false
        isDesktopAudioEnabled = defaults.object(forKey: Keys.desktopAudioEnabled) as? Bool ?? true
        isLocalShellEnabled = defaults.object(forKey: Keys.localShellEnabled) as? Bool ?? false
        isInternetEnabled = defaults.object(forKey: Keys.internetEnabled) as? Bool ?? false
        internetDevices = Set((defaults.stringArray(forKey: Keys.internetDevices) ?? []).compactMap(UUID.init(uuidString:)))
        keepsAwakeForInternet = defaults.object(forKey: Keys.keepAwakeForInternet) as? Bool ?? false
        isDeviceVouchingEnabled = defaults.object(forKey: Keys.deviceVouching) as? Bool ?? true
    }

    /// 开关变化时回调（起停 `RemoteHostServer`）。设置后立即回调一次，与持久化状态对齐。
    func observe(_ handler: @escaping @MainActor (RemoteControlSettings) -> Void) {
        onChange = handler
        handler(self)
    }
}
