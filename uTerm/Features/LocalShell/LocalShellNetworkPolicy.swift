import AppKit

/// 本机终端里的局域网连接（比如手动 `ssh 192.168.x.x`）要不要活过 uTerm 重启。
///
/// 本地网络权限按责任进程放行，默认是 App：App 一死，已建立的局域网连接就断流，重开也恢复不了。让 holder 自己当责任进程
/// 就不受影响，但 shell 访问文稿等目录的授权也改记到 holder 名下，要重新给一遍。这是用户的取舍，所以问他。
/// 责任进程在起 shell 时就定了，改了之后只影响新开的终端。
enum LocalShellNetworkPolicy {
    /// 设置页也读写这个键。没有值 = 还没问过。
    static let key = "localShellKeepsLANConnections"

    static func keepsLANConnections(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    /// 没问过才问，答案记下来。
    @MainActor
    static func askIfNeeded(in defaults: UserDefaults = .standard, ask: @MainActor () -> Bool = presentQuestion) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(ask(), forKey: key)
    }

    @MainActor
    private static func presentQuestion() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "uTerm 重启时，要保住本机终端里的局域网连接吗？")
        alert.informativeText = String(localized: "比如在本机终端里 ssh 到局域网的机器。不保住时这些连接会在 uTerm 重启时断开，终端和其他程序不受影响。保住的话，系统会就访问文稿、局域网等再问你一次授权，记在「uTerm 终端」名下。之后可以在设置 › 终端里改。")
        alert.addButton(withTitle: String(localized: "不保住"))
        alert.addButton(withTitle: String(localized: "保住"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}
