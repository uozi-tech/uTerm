import AppKit

/// 「在终端中打开」的路由：把主机作为**新标签**送进已有的终端窗口，而不是每台主机
/// 各开一个窗口。
///
/// 终端窗口不再绑定单台服务器——一个窗口的不同标签可以连不同主机。各窗口出现时在这里
/// 登记「开标签」的入口，成为 key 时刷新「最近活跃」；Welcome / SFTP 窗口要打开终端时
/// 先问路由：有活着的终端窗口就把标签送进最近活跃的那一个并带到前台，没有才由调用方
/// `openWindow` 新开（`TerminalWindowID` 只能在 Scene 环境里开，路由自己开不了）。
///
/// CLI 的 `terminal-open` 不走这里：它要等**新窗口**里的会话注册上来再回传，仍旧开新窗口。
@MainActor
final class TerminalWindowRouter {
    static let shared = TerminalWindowRouter()

    private struct Entry {
        weak var window: NSWindow?
        let openTab: @MainActor (UUID) -> Void
    }

    private var entries: [UUID: Entry] = [:]
    /// 按最近成为 key 的先后排列，最后一个最新。
    private var activationOrder: [UUID] = []

    private init() {}

    /// 终端窗口出现时登记。重复登记同一 id 视为更新（窗口对象可能晚于视图出现才拿到）。
    func register(windowID: UUID, window: NSWindow?, openTab: @escaping @MainActor (UUID) -> Void) {
        let previous = entries[windowID]?.window
        entries[windowID] = Entry(window: window ?? previous, openTab: openTab)
        // 新窗口记成最近活跃：它刚被打开，通常马上就会成为 key。
        if !activationOrder.contains(windowID) {
            activationOrder.append(windowID)
        }
    }

    func unregister(windowID: UUID) {
        entries[windowID] = nil
        activationOrder.removeAll { $0 == windowID }
    }

    /// 窗口成为 key 时调用：它就是下一次「在终端中打开」的落点。
    func markActive(windowID: UUID) {
        guard entries[windowID] != nil else { return }
        activationOrder.removeAll { $0 == windowID }
        activationOrder.append(windowID)
    }

    /// 把 `serverID` 作为新标签送进最近活跃的终端窗口并带到前台。
    /// 返回 false = 当前没有终端窗口，调用方应新开一个。
    @discardableResult
    func openInExistingWindow(serverID: UUID) -> Bool {
        guard let id = activationOrder.last, let entry = entries[id] else { return false }
        entry.openTab(serverID)
        if let window = entry.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}
