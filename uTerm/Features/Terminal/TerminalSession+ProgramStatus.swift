import AppKit
import SwiftUI
import UDesignKit

extension TerminalSession {

    /// 接上影子终端的事件（`init` 里调）：程序状态、新提示符、桌面通知、标题、命令跟踪标记。状态的规则两端共用
    /// （`ProgramStatusTracker`），这里只管 Mac 的部分：用户有没有在看、系统通知。
    ///
    /// 事件在喂字节的那条线程上、解析到那个序列时同步发出。在主线程上喂（测试、接回时的回放）就当场处理；
    /// 否则排到主线程，先后顺序不变。
    func installShadowEventHandler() {
        shadow.setEventHandler { [weak self] event in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handleShadowEvent(event) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleShadowEvent(event) } }
            }
        }
    }

    private func handleShadowEvent(_ event: ShadowTerminal.Event) {
        // 回放是重启前的事：不回答、不发通知、不认标记。检查点里也没有状态，标签等程序下次上报。
        //（回放期间影子终端的事件本来就关着，这里再挡一次排在主线程队列里晚到的。）
        guard !isReplayingHeldOutput else { return }
        switch event {
        case .programStatus(let message):
            // 远控镜像：那台 Mac 自己解析状态、经远控协议推过来，这里不再解析一遍。
            guard !(backend is RemoteTerminalBackend) else { return }
            applyProgramStatus(message, isLooking: isUserLooking)
        case .programStatusQuery:
            // 远控镜像：那台 Mac 自己回答查询，这里再答一遍就成了程序收到的多余输入。
            // 应答用 uTerm 自己那条最短的（`ProgramStatusTracker.queryReply`，缺省即全部支持），不用引擎拟的那条。
            guard !(backend is RemoteTerminalBackend) else { return }
            applyProgramStatus(.query, isLooking: isUserLooking)
        case .promptStarted:
            programDidEnd()
        case .unknownOSC(let payload, let cursor):
            handleUnknownOSC(payload, cursor: cursor)
        case .notification(let title, let body):
            postProgramNotification(TerminalAttention.notification(title: title, body: body))
        case .titleChanged(let title):
            receiveShellTitle(title)
        case .bell:
            // 标签藏着也响（和迁移前一样：每条会话都在解析）；surface 那边的 bell 回调不接，免得响两次。
            NSSound.beep()
        }
    }

    /// 用户此刻正看着这条会话：app 在前台、窗口是 key、键盘焦点在这个终端上。
    var isUserLooking: Bool {
        if let userLookingOverride { return userLookingOverride() }
        return NSApp.isActive && ghostty.isFocusedInWindow
    }

    func applyProgramStatus(_ message: ProgramStatusMessage, isLooking: Bool) {
        if case .report = message { checkTrueColorIfNeeded() }
        switch programStatusTracker.receive(message, isLooking: isLooking) {
        case .none: break
        case .reply: sendHostBytes(Data(ProgramStatusTracker.queryReply))
        case .attention(let record): attentionSink?(record.attention)
        }
        publishProgramStatus()
    }

    /// 用户回到这条会话：结果算看过了，通知中心里的旧通知也收掉。
    func acknowledgeProgramStatus() {
        programStatusTracker.acknowledgeResults()
        publishProgramStatus()
        TerminalAttentionCenter.shared.withdraw(from: self)
        // 远控镜像的状态是那台 Mac 推来的，看过与否记在连接上。
        if let remote = backend as? RemoteTerminalBackend {
            remote.client.acknowledgeProgramStatus(for: remote.sessionID)
        }
    }

    /// 连接没了，上面跑的程序也不再有状态可言；标签改由连接状态说话。
    func resetProgramStatus() {
        programStatusTracker.reset()
        publishProgramStatus()
    }

    private func programDidEnd() {
        programStatusTracker.promptStarted()
        publishProgramStatus()
    }

    private func postProgramNotification(_ attention: TerminalAttention?) {
        guard let attention, !isUserLooking, !isReplayingHeldOutput else { return }
        attentionSink?(attention)
    }

    private func publishProgramStatus() {
        let report = programStatusTracker.board.summary
        if report != programReport { programReport = report }
        let next = programStatusTracker.display
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
