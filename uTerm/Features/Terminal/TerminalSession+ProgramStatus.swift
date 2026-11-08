import AppKit
import SwiftTerm
import SwiftUI
import UDesignKit

extension TerminalSession {

    /// 注册程序状态与桌面通知的 OSC 处理器（`init` 里调）。状态的规则两端共用（`ProgramStatusTracker`），
    /// 这里只管 Mac 的部分：用户有没有在看、系统通知。
    func installProgramStatusHandlers() {
        let terminal = terminalView.getTerminal()
        ProgramStatusOSC.install(on: terminal, onMessage: { [weak self] message in
            // 回放是重启前的事：不回答、不发通知。检查点里也没有状态，标签等程序下次上报。
            // 远控镜像：那台 Mac 自己回答查询、经远控协议把状态推过来，这里再答一遍就成了程序收到的多余输入。
            guard let self, !self.isReplayingHeldOutput, !(self.backend is RemoteTerminalBackend) else { return }
            self.applyProgramStatus(message, isLooking: self.isUserLooking)
        }, onPrompt: { [weak self] in
            self?.programDidEnd()
        })
        // 下面两个编号 SwiftTerm 内置了处理，注册后要自己转回去。
        terminal.registerOscHandler(code: 9) { [weak self] data in
            MainActor.assumeIsolated {
                guard let self, !self.terminalView.getTerminal().oscProgressReport(data) else { return }
                self.postProgramNotification(TerminalAttention.osc9(data))
            }
        }
        terminal.registerOscHandler(code: 777) { [weak self] data in
            MainActor.assumeIsolated {
                self?.postProgramNotification(TerminalAttention.osc777(data))
            }
        }
    }

    /// 用户此刻正看着这条会话：app 在前台、窗口是 key、键盘焦点在这个终端上。
    /// `hasFocus` 在视图不在窗口里时也可能为真（切走的标签），所以要单独看 `window`。
    var isUserLooking: Bool {
        if let userLookingOverride { return userLookingOverride() }
        return NSApp.isActive && terminalView.window != nil && terminalView.hasFocus
    }

    func applyProgramStatus(_ message: ProgramStatusMessage, isLooking: Bool) {
        if case .report = message { checkTrueColorIfNeeded() }
        switch programStatusTracker.receive(message, isLooking: isLooking) {
        case .none: break
        case .reply: send(source: terminalView, data: ProgramStatusTracker.queryReply[...])
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
