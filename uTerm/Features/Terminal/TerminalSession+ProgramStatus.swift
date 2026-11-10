import AppKit
import SwiftUI
import UDesignKit

extension TerminalSession {

    /// 接上影子终端的事件（`init` 里调）。程序状态、查询、历史、远控镜像的规则两端共用（`TerminalEventRouter`），
    /// 这里只接 Mac 的出口：用户有没有在看、系统通知、标题、响铃、命令跟踪标记。
    func installShadowEventHandler() {
        events.isMirror = { [weak self] in self?.backend?.mirrorsRemoteGrid ?? false }
        events.isLooking = { [weak self] in self?.isUserLooking ?? false }
        events.sendToProgram = { [weak self] in self?.sendHostBytes($0) }
        events.onAttention = { [weak self] in self?.attentionSink?($0.attention) }
        events.onReport = { [weak self] in self?.checkTrueColorIfNeeded() }
        events.onStatusChanged = { [weak self] in self?.publishProgramStatus() }
        events.onEvent = { [weak self] in self?.handleShadowEvent($0) }
        events.install(on: shadow)
    }

    /// 程序写剪贴板（OSC 52）：以影子终端为准——标签藏着、surface 没建或放掉了时照样生效（surface 那边配置成 deny，
    /// 不会写两遍）。读剪贴板一律不答；历史字节里的不写（影子那边就不调）。
    func installShadowClipboardHandler() {
        shadow.setClipboardWriteHandler { [weak self] text in
            TerminalMainHop.run { self?.programWroteClipboard(text) }
        }
    }

    private func programWroteClipboard(_ text: String) {
        let pasteboard = ghostty.view.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func handleShadowEvent(_ event: ShadowTerminal.Event) {
        switch event {
        case .unknownOSC(let payload, let cursor):
            handleUnknownOSC(payload, cursor: cursor)
        case .notification(let title, let body):
            postProgramNotification(TerminalAttention.notification(title: title, body: body))
        case .titleChanged(let title):
            receiveShellTitle(title)
        case .bell:
            // 标签藏着也响（和迁移前一样：每条会话都在解析）；surface 那边的 bell 回调不接，免得响两次。
            NSSound.beep()
        case .programStatus, .programStatusQuery, .promptStarted:
            break
        }
    }

    /// 用户此刻正看着这条会话：app 在前台、窗口是 key、键盘焦点在这个终端上。
    var isUserLooking: Bool {
        if let userLookingOverride { return userLookingOverride() }
        return NSApp.isActive && ghostty.isFocusedInWindow
    }

    func applyProgramStatus(_ message: ProgramStatusMessage, isLooking: Bool) {
        events.apply(message, isLooking: isLooking)
    }

    /// 用户回到这条会话：结果算看过了，通知中心里的旧通知也收掉。
    func acknowledgeProgramStatus() {
        events.acknowledgeResults()
        TerminalAttentionCenter.shared.withdraw(from: self)
        // 远控镜像的状态是那台 Mac 推来的，看过与否记在连接上。
        if let remote = backend as? RemoteTerminalBackend {
            remote.client.acknowledgeProgramStatus(for: remote.sessionID)
        }
    }

    /// 连接没了，上面跑的程序也不再有状态可言；标签改由连接状态说话。
    func resetProgramStatus() {
        events.reset()
    }

    private func postProgramNotification(_ attention: TerminalAttention?) {
        guard let attention, !isUserLooking else { return }
        attentionSink?(attention)
    }

    func publishProgramStatus() {
        let tracker = events.tracker
        let report = tracker.board.summary
        if report != programReport { programReport = report }
        let next = tracker.display
        if next != programStatus { programStatus = next }
    }
}

// MARK: - Mac 的通知与标签颜色（文案在共享的 `ProgramStatusTracker.swift`）

extension ProgramStatusRecord {
    var attention: TerminalAttention {
        TerminalAttention(title: "\(appName) \(statusLabel)", body: message ?? "")
    }

    @MainActor var tabDot: SwiftUI.Color {
        switch tone {
        case .needsAttention: UD.warning
        case .working: UD.accent
        case .done: UD.success
        case .failed: UD.danger
        case .idle: UD.text4
        }
    }
}
