import AppKit
import SwiftTerm
import SwiftUI
import UDesignKit

extension TerminalSession {

    /// 注册程序状态与桌面通知的 OSC 处理器（`init` 里调）。输出只在 MainActor 上喂给 SwiftTerm，
    /// 所以回调同步到达主线程。
    func installProgramStatusHandlers() {
        let terminal = terminalView.getTerminal()
        terminal.registerOscHandler(code: 7501) { [weak self] data in
            MainActor.assumeIsolated {
                // 回放是重启前的事：不回答、不发通知。检查点里也没有状态，标签等程序下次上报。
                guard let self, !self.isReplayingHeldOutput, let message = ProgramStatusMessage.parse(data) else { return }
                self.applyProgramStatus(message, isLooking: self.isUserLooking)
            }
        }
        // 下面三个编号 SwiftTerm 内置了处理，注册后要自己转回去。
        terminal.registerOscHandler(code: 133) { [weak self] data in
            MainActor.assumeIsolated {
                guard let self else { return }
                let terminal = self.terminalView.getTerminal()
                terminal.oscSemanticPrompt(data)
                if data.first == UInt8(ascii: "A"), !terminal.isCurrentBufferAlternate {
                    self.programDidEnd()
                }
            }
        }
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
    private var isUserLooking: Bool {
        if let ghostty { return NSApp.isActive && ghostty.isFocusedInWindow }
        return NSApp.isActive && terminalView.window != nil && terminalView.hasFocus
    }

    func applyProgramStatus(_ message: ProgramStatusMessage, isLooking: Bool) {
        switch message {
        case .query:
            // 不写 states / kinds：规格规定缺省即全部支持。
            let reply = "\u{1b}]7501;?\u{1b}\\"
            sendHostBytes(Data(reply.utf8))
            return
        case .clear(let id):
            programStatusBoard.clear(id: id)
        case .report(let id, let record):
            checkTrueColorIfNeeded()
            let needsAttention = programStatusBoard.apply(id: id, record: record)
            if isLooking {
                programStatusBoard.acknowledgeResults()
            } else if needsAttention {
                attentionSink?(record.attention)
            }
        }
        publishProgramStatus()
    }

    /// 用户回到这条会话：结果算看过了，通知中心里的旧通知也收掉。
    func acknowledgeProgramStatus() {
        programStatusBoard.acknowledgeResults()
        publishProgramStatus()
        TerminalAttentionCenter.shared.withdraw(from: self)
    }

    /// 连接没了，上面跑的程序也不再有状态可言；标签改由连接状态说话。
    func resetProgramStatus() {
        programStatusBoard.clear(id: nil)
        publishProgramStatus()
    }

    private func programDidEnd() {
        programStatusBoard.programEnded()
        publishProgramStatus()
    }

    private func postProgramNotification(_ attention: TerminalAttention?) {
        guard let attention, !isUserLooking, !isReplayingHeldOutput else { return }
        attentionSink?(attention)
    }

    /// `idle` 不在标签上显示：没有需要告诉用户的事。
    private func publishProgramStatus() {
        let summary = programStatusBoard.summary
        let next = summary?.state == .idle ? nil : summary
        guard next != programStatus else { return }
        programStatus = next
    }
}

// MARK: - 文案与标签外观

extension ProgramStatusRecord {
    /// 程序名。规格里 `app` 是稳定标识符，这两个常见的换成用户认识的名字。
    private var appName: String {
        switch app {
        case "claude-code": "Claude Code"
        case "codex": "Codex"
        case let app?: app
        case nil: title ?? String(localized: "终端程序")
        }
    }

    var statusLabel: String {
        switch state {
        case .blocked:
            switch kind {
            case .permission: String(localized: "等待确认")
            case .question: String(localized: "等待回答")
            case .auth: String(localized: "需要登录")
            case nil: String(localized: "等待处理")
            }
        case .working: String(localized: "运行中")
        case .done: String(localized: "已完成")
        case .error: String(localized: "出错了")
        case .idle: String(localized: "空闲")
        }
    }

    var attention: TerminalAttention {
        TerminalAttention(title: "\(appName) \(statusLabel)", body: message ?? "")
    }

    var tabHelp: String {
        let headline = "\(appName) · \(statusLabel)"
        return message.map { "\(headline)\n\($0)" } ?? headline
    }

    @MainActor var tabDot: SwiftUI.Color {
        switch state {
        case .blocked: UD.warning
        case .working: UD.accent
        case .done: UD.success
        case .error: UD.danger
        case .idle: UD.text4
        }
    }
}
