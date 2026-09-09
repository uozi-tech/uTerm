import Foundation
import Observation

/// 命令行接口（本机 IPC）的门禁开关，持久化在 UserDefaults。
///
/// 两级都默认**关闭**。理由：socket 虽然是 0600、只有本用户能连，但连上就等于拿到
/// 用户**全部已保存主机**的操作能力 —— 所以要用户在设置里明确开一次，而不是装了就通。
@MainActor
@Observable
public final class ControlSettings {
    private enum Keys {
        static let enabled = "control.enabled"
        static let allowMutations = "control.allowMutations"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var onChange: (@MainActor (ControlSettings) -> Void)?

    /// 主开关：关掉时 socket 不监听（并 unlink），`ping` 之外的一切请求都拒。
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            onChange?(self)
        }
    }

    /// 改动开关：`run` / `run-many` / `quick-run` / `trust` / SFTP 写 /
    /// `forward-start|stop` / `terminal-send|open` 的总闸。
    ///
    /// `run` **有意**归在这里：shell 命令无法可靠分类读写，假的只读开关比没有更糟。
    public var allowMutations: Bool {
        didSet {
            guard allowMutations != oldValue else { return }
            defaults.set(allowMutations, forKey: Keys.allowMutations)
            onChange?(self)
        }
    }

    /// 服务端起不来的原因（非持久化）。目前唯一来源是 socket 路径超过
    /// `sun_path` 上限（长用户名 + 沙盒容器路径）。设置页把它显示成红字。
    public var startupError: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        allowMutations = defaults.object(forKey: Keys.allowMutations) as? Bool ?? false
    }

    /// 开关变化时回调（用来起/停 `ControlServer`）。设置后立刻回调一次，
    /// 让服务端与当前持久化状态对齐。
    func observe(_ handler: @escaping @MainActor (ControlSettings) -> Void) {
        onChange = handler
        handler(self)
    }

    public var socketPath: String { ControlProtocol.socketURL.path }
}
