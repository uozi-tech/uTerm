import AppKit
import SwiftUI

extension TerminalSession {
    /// 关标签前问：前台还有没有程序在跑。没连上就没有程序可中断。
    func foregroundActivity() async -> TerminalActivity {
        await TerminalCloseProbe.foregroundActivity(connected: connectionState == .connected, backend: backend) {
            shadow.isOnAlternateScreen
        }
    }
}

/// 用户关终端标签时的二次确认：前台还有程序在跑才问。
@MainActor
enum TerminalCloseGuard {
    /// 探测要走一趟网络，连按 ⌘W 不重复发起；确认 sheet 开着时也不叠第二个。
    private static let probe = TerminalCloseProbe()

    /// `session` 为 nil（空组没有会话）时直接关。`tabName` 是标签上显示的名字，写进确认框。`close` 里要重新定位标签：探测和确认都要时间。
    /// `window` 取发起关闭时的 key window：探测期间用户可能切走，弹框要落在原来的窗口上。
    static func requestClose(
        _ session: TerminalSession?,
        tabName: String? = nil,
        window: NSWindow? = NSApp.keyWindow,
        close: @escaping @MainActor () -> Void
    ) {
        guard let session else {
            close()
            return
        }
        Task {
            await probe.probe(ObjectIdentifier(session), tabName: tabName, activity: session.foregroundActivity) { prompt in
                if let prompt, await !confirm(prompt, action: String(localized: "关闭标签页"), in: window) { return }
                close()
            }
        }
    }

    /// 关窗前问一遍窗口里的所有终端。逐个探测：一条连接上最多 6 个 shell，同时再各开一个 exec
    /// 通道会撞上 sshd 默认的 `MaxSessions 10`，开不了的就成了「判断不了」。
    static func confirmClosingWindow(_ window: NSWindow, sessions: [TerminalSession]) async -> Bool {
        var activities: [TerminalActivity] = []
        for session in sessions { activities.append(await session.foregroundActivity()) }
        guard let prompt = TerminalClosePrompt.forWindow(activities) else { return true }
        return await confirm(prompt, action: String(localized: "关闭窗口"), in: window)
    }

    private static func confirm(_ prompt: TerminalClosePrompt, action: String, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "取消"))
        guard let window, window.isVisible else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

/// 把窗口里的终端交给 `WindowCloseProxy`：红灯、⌘W 关最后一个标签、「文件 ▸ 关闭」都走 `performClose`，
/// 在那里统一确认。
struct TerminalWindowCloseGuardInstaller: NSViewRepresentable {
    let sessions: () -> [TerminalSession]

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.sessions = sessions
        return view
    }

    func updateNSView(_ nsView: InstallerView, context: Context) {
        nsView.sessions = sessions
    }

    final class InstallerView: NSView {
        var sessions: () -> [TerminalSession] = { [] } {
            didSet { proxy?.terminalSessions = sessions }
        }
        private var proxy: WindowCloseProxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let proxy = WindowCloseProxy.installed(on: window)
            proxy.terminalSessions = sessions
            self.proxy = proxy
        }
    }
}
