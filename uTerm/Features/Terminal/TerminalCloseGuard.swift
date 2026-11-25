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

    /// 一个标签页里有好几个终端（Code 标签页里跑着的会话）：逐个探测，有前台程序在跑才问一次，确认后 `close`。
    /// 只有一个时同 `requestClose(_:tabName:)`；一个都没有时直接关。
    static func requestClose(
        _ sessions: [TerminalSession],
        tabName: String? = nil,
        window: NSWindow? = NSApp.keyWindow,
        close: @escaping @MainActor () -> Void
    ) {
        guard sessions.count > 1 else {
            requestClose(sessions.first, tabName: tabName, window: window, close: close)
            return
        }
        Task {
            var activities: [TerminalActivity] = []
            for session in sessions { activities.append(await session.foregroundActivity()) }
            if let prompt = TerminalClosePrompt.forTab(activities, tabName: tabName),
               await !confirm(prompt, action: String(localized: "关闭标签页"), in: window) { return }
            close()
        }
    }

    /// Code 标签页里「结束会话」（终端顶上「⋯」、侧栏那一行的右键菜单与悬停的 ×）：同关终端标签页，前台还有程序在跑才问，
    /// 确认按钮是「结束会话」，确认后 `CodeTabModel.endSession`。已结束、留着画面的（程序已经退出）不问。
    /// `session` 从会话的终端取出它的 `TerminalSession`（两种宿主的终端类型不同）。`confirm` 只给测试换掉弹框。
    /// 返回探测那一趟（测试等它），不用问时为 nil。
    @discardableResult
    static func requestEndSession(
        _ runID: UUID,
        in code: CodeTabModel,
        session: (any CodeTabTerminal) -> TerminalSession?,
        window: NSWindow? = NSApp.keyWindow,
        confirm: (@MainActor (TerminalClosePrompt) async -> Bool)? = nil
    ) -> Task<Void, Never>? {
        guard let run = code.runs.first(where: { $0.id == runID }) else { return nil }
        guard !run.isEnded, let target = session(run.terminal) else {
            code.endSession(runID)
            return nil
        }
        let ask = confirm ?? { prompt in
            await Self.confirm(prompt, action: AgentHistoryText.endSession, in: window)
        }
        return Task {
            await probe.probe(ObjectIdentifier(target), activity: target.foregroundActivity) { prompt in
                if let prompt, await !ask(prompt.endingSession) { return }
                code.endSession(runID)
            }
        }
    }

    /// ⌘W 落在 Code 标签页上（`CodeTabModel.closeShortcut`）：右边显示着它里面的会话就结束那个会话（同「结束会话」，
    /// 见 `requestEndSession`），返回 true。不是 Code 标签页、或者该关标签页时返回 false，调用方照旧关标签页 / 窗口。
    @discardableResult
    static func endDisplayedSession(
        of code: CodeTabModel?,
        window: NSWindow? = NSApp.keyWindow,
        session: (any CodeTabTerminal) -> TerminalSession?
    ) -> Bool {
        guard let code, case .endSession(let runID) = code.closeShortcut else { return false }
        requestEndSession(runID, in: code, session: session, window: window)
        return true
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

extension TerminalClosePrompt {
    /// 关一个装着好几个终端的标签页（Code 标签页）时的确认。nil = 都停在提示符上，不用问。
    /// 只有一个在跑时和普通标签页说的一样；好几个时说个数。
    static func forTab(_ activities: [TerminalActivity], tabName: String?) -> TerminalClosePrompt? {
        let busy = activities.filter { $0 != .idle }
        guard busy.count > 1 else { return busy.first?.closePrompt(tabName: tabName) }
        return TerminalClosePrompt(
            title: String(localized: "这个标签页里有 \(busy.count) 个会话可能还在运行",
                          comment: "关 Code 标签页前的确认：里面有几个终端还有程序在跑"),
            message: String(localized: "关闭标签页会结束这些会话，里面的程序可能被中断。",
                            comment: "关 Code 标签页前的确认"))
    }

    /// 结束 Code 标签页里一个会话前的确认：标题同关终端标签页（说在跑的是哪个程序），正文说的是结束会话。
    var endingSession: TerminalClosePrompt {
        TerminalClosePrompt(title: title,
                            message: String(localized: "结束会话会关闭这个终端，里面的程序可能被中断。",
                                            comment: "Code 标签页里结束一个会话前的确认"))
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
