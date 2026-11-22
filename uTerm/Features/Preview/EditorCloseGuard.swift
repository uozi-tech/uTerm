import AppKit
import SwiftUI

/// 关窗 / 退出前处理编辑器里改了还没存的远程文件（预览区与终端区的文件标签）。
///
/// 自动保存开着：不问，立刻全存（不等那一秒）；存不上的（远端被别处改过、连接断了）才问「回去处理 / 直接关闭」。
/// 关着：问「保存后关闭 / 直接关闭 / 取消」，选保存同上。和 `ExternalEditCloseGuard`（「打开」出去的文件）是两件事。
@MainActor
enum EditorCloseGuard {
    /// 没有改了没存的 → true，不弹框。返回 false = 不关（用户取消，或要回去处理存不上的）。
    static func resolve(_ models: [FilePreviewModel], quitting: Bool,
                        ask: @MainActor (_ unsaved: [FileBuffer], _ quitting: Bool) -> Choice = askToSave,
                        askAfterFailure: @MainActor (_ left: [FileBuffer], _ quitting: Bool) -> Bool = askToDiscard) async -> Bool {
        let unsaved = models.flatMap(\.unsavedBuffers)
        guard !unsaved.isEmpty else { return true }
        if !models.contains(where: { $0.isAutosaveEnabled() }) {
            switch ask(unsaved, quitting) {
            case .cancel: return false
            case .discard: return true
            case .save: break
            }
        }
        var left: [FileBuffer] = []
        for model in models { left += await model.saveAllUnsaved() }
        guard !left.isEmpty else { return true }
        return askAfterFailure(left, quitting)
    }

    enum Choice { case save, discard, cancel }

    static func askToSave(_ unsaved: [FileBuffer], quitting: Bool) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "有 \(unsaved.count) 个文件的改动还没保存")
        alert.informativeText = names(unsaved)
        alert.addButton(withTitle: quitting ? String(localized: "保存后退出") : String(localized: "保存后关闭"))
        alert.addButton(withTitle: quitting ? String(localized: "直接退出") : String(localized: "直接关闭"))
        alert.addButton(withTitle: String(localized: "取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// 存不上的那些：true = 放弃这些改动照样关。
    static func askToDiscard(_ left: [FileBuffer], quitting: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "有 \(left.count) 个文件的改动没能保存到主机")
        alert.informativeText = names(left) + "\n\n"
            + String(localized: "可能是文件在你打开后被别处改过，或者连接断了。回去在编辑器里按 ⌘S 处理，或者放弃这些改动。")
        alert.addButton(withTitle: String(localized: "回去处理"))
        alert.addButton(withTitle: quitting ? String(localized: "放弃改动并退出") : String(localized: "放弃改动并关闭"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func names(_ buffers: [FileBuffer]) -> String {
        let names = buffers.map(\.displayName)
        return names.prefix(6).joined(separator: "\n") + (names.count > 6 ? "\n…" : "")
    }

    // MARK: 退出 App

    /// `applicationShouldTerminate` 里排在终端确认之后、「打开」出去的文件之前。没有要存的就原样交给 `next`。
    static func shouldTerminate(_ sender: NSApplication,
                                next: @escaping @MainActor (NSApplication) -> NSApplication.TerminateReply)
        -> NSApplication.TerminateReply {
        let models = FilePreviewModel.allLive
        guard models.contains(where: { !$0.unsavedBuffers.isEmpty }) else { return next(sender) }
        Task { @MainActor in
            guard await resolve(models, quitting: true) else {
                TerminalQuitPolicy.shared.quitCancelled()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            switch next(sender) {
            case .terminateNow: sender.reply(toApplicationShouldTerminate: true)
            case .terminateCancel:
                TerminalQuitPolicy.shared.quitCancelled()
                sender.reply(toApplicationShouldTerminate: false)
            case .terminateLater: break   // `next` 自己回复
            @unknown default: sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

/// 把窗口里的编辑器交给 `WindowCloseProxy`：红灯、⌘W 关最后一个标签、「文件 ▸ 关闭」都走 `performClose`。
struct EditorWindowCloseGuardInstaller: NSViewRepresentable {
    let models: () -> [FilePreviewModel]

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.models = models
        return view
    }

    func updateNSView(_ nsView: InstallerView, context: Context) {
        nsView.models = models
    }

    final class InstallerView: NSView {
        var models: () -> [FilePreviewModel] = { [] } {
            didSet { proxy?.editors = models }
        }
        private var proxy: WindowCloseProxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let proxy = WindowCloseProxy.installed(on: window)
            proxy.editors = models
            self.proxy = proxy
        }
    }
}
