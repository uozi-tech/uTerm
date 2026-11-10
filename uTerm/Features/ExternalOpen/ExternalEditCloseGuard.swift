import AppKit
import SwiftUI

/// 关窗 / 退出前检查「打开」出去的文件还有没有没上传的改动。
///
/// 三个选项：上传后关闭（立刻传，不等轮询的防抖；全传上去才关）/ 直接关闭 / 取消。
@MainActor
enum ExternalEditCloseGuard {
    enum Decision { case proceed, cancel, uploadThenProceed }

    /// 没有待上传改动 → `.proceed`，不弹框。
    static func ask(_ coordinators: [ExternalOpenCoordinator], quitting: Bool) -> Decision {
        let pending = coordinators.flatMap(\.unsyncedSessions)
        guard !pending.isEmpty else { return .proceed }
        let names = pending.map(\.fileName)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "有 \(pending.count) 个文件的改动还没上传到主机")
        alert.informativeText = names.prefix(6).joined(separator: "\n")
            + (names.count > 6 ? "\n…" : "")
        alert.addButton(withTitle: quitting ? String(localized: "上传后退出")
                                            : String(localized: "上传后关闭"))
        alert.addButton(withTitle: quitting ? String(localized: "直接退出")
                                            : String(localized: "直接关闭"))
        alert.addButton(withTitle: String(localized: "取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .uploadThenProceed
        case .alertSecondButtonReturn: return .proceed
        default:                       return .cancel
        }
    }

    /// 全部立刻上传；有没传上去的（失败 / 冲突被暂缓）就提示并返回 false。
    static func flush(_ coordinators: [ExternalOpenCoordinator]) async -> Bool {
        var allSynced = true
        for coordinator in coordinators where !(await coordinator.flushPendingUploads()) {
            allSynced = false
        }
        if !allSynced {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "有文件未能上传")
            alert.informativeText = String(localized: "查看右下角的提示后重试，或选择「直接关闭」放弃这些改动。")
            alert.runModal()
        }
        return allSynced
    }

    /// 非窗口关闭按钮的关窗路径（如 SFTP 标题栏「断开并关闭窗口」）用：问完再执行 `close`。
    static func confirmThenClose(_ coordinators: [ExternalOpenCoordinator], close: @escaping () -> Void) {
        switch ask(coordinators, quitting: false) {
        case .proceed:
            close()
        case .cancel:
            break
        case .uploadThenProceed:
            Task { if await flush(coordinators) { close() } }
        }
    }

    // MARK: - 退出 app

    /// `applicationShouldTerminate` 用。需要上传时返回 `.terminateLater`，传完再回复。
    static func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinators = ExternalOpenCoordinator.allLive
        switch ask(coordinators, quitting: true) {
        case .proceed:
            return .terminateNow
        case .cancel:
            return .terminateCancel
        case .uploadThenProceed:
            Task {
                let ok = await flush(coordinators)
                // 上传失败、退出取消：终端的「退出中」状态要一起复位，否则之后关标签会走退出分支。
                if !ok { TerminalQuitPolicy.shared.quitCancelled() }
                sender.reply(toApplicationShouldTerminate: ok)
            }
            return .terminateLater
        }
    }
}

/// 窗口级挂点：把窗口的 delegate 包一层，在 `windowShouldClose` 里先问
/// `ExternalEditCloseGuard`。覆盖关闭按钮、⌘W、「文件 ▸ 关闭」——它们都走
/// `performClose` → `windowShouldClose`。
///
/// 为什么是包一层而不是换掉：SwiftUI 的窗口 delegate 管着场景生命周期，这里只拦一个
/// 方法，其余消息经 `forwardingTarget` 原样转给它。
struct ExternalEditCloseGuardInstaller: NSViewRepresentable {
    let coordinators: () -> [ExternalOpenCoordinator]

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinators = coordinators
        return view
    }

    func updateNSView(_ nsView: InstallerView, context: Context) {
        nsView.coordinators = coordinators
    }

    final class InstallerView: NSView {
        var coordinators: () -> [ExternalOpenCoordinator] = { [] } {
            didSet { proxy?.coordinators = coordinators }
        }
        private var proxy: WindowCloseProxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // SwiftUI 可能在我们之后重设 delegate；每次挂到窗口都确认一遍。
            let proxy = WindowCloseProxy.installed(on: window)
            proxy.coordinators = coordinators
            self.proxy = proxy
        }
    }
}

/// 关窗前的检查都挂在这一个代理上。窗口的 delegate 是弱引用，由各个 installer 视图持有它。
final class WindowCloseProxy: NSObject, NSWindowDelegate {
    private enum TerminalCheck { case notStarted, probing, approved }

    /// AppKit 在主线程上转发消息，但 `responds(to:)` / `forwardingTarget(for:)` 声明为
    /// nonisolated，读它们要绕过隔离检查。只在 init 写一次。
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    var coordinators: () -> [ExternalOpenCoordinator] = { [] }
    var terminalSessions: () -> [TerminalSession] = { [] }
    /// 问未上传的文件、立刻上传。默认弹 `runModal`，单测里换掉，否则会挂住。
    var askAboutUnsyncedFiles: ([ExternalOpenCoordinator]) -> ExternalEditCloseGuard.Decision = {
        ExternalEditCloseGuard.ask($0, quitting: false)
    }
    var uploadUnsyncedFiles: ([ExternalOpenCoordinator]) async -> Bool = {
        await ExternalEditCloseGuard.flush($0)
    }
    private var terminalCheck = TerminalCheck.notStarted

    init(original: NSWindowDelegate?) {
        self.original = original
    }

    /// 窗口上已有代理就复用，否则包一层。
    static func installed(on window: NSWindow) -> WindowCloseProxy {
        if let existing = window.delegate as? WindowCloseProxy { return existing }
        let proxy = WindowCloseProxy(original: window.delegate)
        window.delegate = proxy
        return proxy
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard terminalsAllowClosing(sender) else { return false }
        let coordinators = coordinators()
        switch askAboutUnsyncedFiles(coordinators) {
        case .cancel:
            return false
        case .uploadThenProceed:
            Task { @MainActor in
                // 传完后再走一遍 performClose：那时已没有待上传改动，直接放行。
                if await uploadUnsyncedFiles(coordinators) {
                    terminalCheck = .approved   // 终端刚问过，别再问一遍。
                    sender.performClose(nil)
                }
            }
            return false
        case .proceed:
            return original?.windowShouldClose?(sender) ?? true
        }
    }

    /// 探测要走网络、确认框是 sheet，都不能卡在这个同步回调里：先拒绝这次关闭，用户同意后重走
    /// `performClose`。放在未上传检查之前，否则重走时那边会再问一遍。
    private func terminalsAllowClosing(_ window: NSWindow) -> Bool {
        switch terminalCheck {
        case .approved:
            terminalCheck = .notStarted
            return true
        case .probing:
            return false
        case .notStarted:
            let sessions = terminalSessions()
            guard !sessions.isEmpty else { return true }
            terminalCheck = .probing
            Task { @MainActor in
                let approved = await TerminalCloseGuard.confirmClosingWindow(window, sessions: sessions)
                terminalCheck = approved ? .approved : .notStarted
                if approved { window.performClose(nil) }
            }
            return false
        }
    }
}
