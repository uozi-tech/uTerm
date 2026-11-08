import AppKit

/// 退出 App 时终端（本机 shell 和 SSH）怎么办。默认都是留着：重启、崩溃、Xcode Stop、Sparkle 更新都不该打断里面跑的东西。
/// 只有用户按 ⌘Q 时才问一声。
@MainActor
final class TerminalQuitPolicy {
    static let shared = TerminalQuitPolicy()
    /// 设置页也读写这个键。
    static let behaviorKey = DefaultsKey.terminalQuitBehavior

    enum Behavior: String, CaseIterable {
        case ask, keep, end
    }

    private(set) var isQuitting = false
    private(set) var endsSessionsOnQuit = false
    /// Sparkle 要重启 App 装更新，这时不弹框。
    var isRelaunchingForUpdate = false

    private init() {}

    private var liveCount: Int {
        HeldTerminalSessions.all.filter { $0.connectionState == .connected }.count
    }

    /// `applicationShouldTerminate` 用。返回 false = 用户取消了退出。
    func confirmQuit() -> Bool {
        switch decide(liveCount: liveCount) {
        case .keep: endsSessionsOnQuit = false
        case .end: endsSessionsOnQuit = true
        case .cancel: return false
        }
        isQuitting = true
        return true
    }

    /// 后面的环节（没上传的文件）取消了退出。
    func quitCancelled() {
        isQuitting = false
        endsSessionsOnQuit = false
    }

    private enum Decision { case keep, end, cancel }

    private func decide(liveCount: Int) -> Decision {
        guard liveCount > 0, !isRelaunchingForUpdate, !isSystemQuit else { return .keep }
        switch UserDefaults.standard.string(forKey: Self.behaviorKey).flatMap(Behavior.init(rawValue:)) ?? .ask {
        case .keep: return .keep
        case .end: return .end
        case .ask: return ask(liveCount: liveCount)
        }
    }

    private func ask(liveCount: Int) -> Decision {
        let alert = NSAlert()
        alert.messageText = String(localized: "还有 \(liveCount) 个终端在运行")
        alert.informativeText = String(localized: "选择保留，终端里的程序会继续运行，下次打开 uTerm 时自动接回。")
        alert.addButton(withTitle: String(localized: "保留并退出"))
        alert.addButton(withTitle: String(localized: "全部结束并退出"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "记住选择，不再询问")
        let decision: Decision
        switch alert.runModal() {
        case .alertFirstButtonReturn: decision = .keep
        case .alertSecondButtonReturn: decision = .end
        default: return .cancel
        }
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set((decision == .end ? Behavior.end : Behavior.keep).rawValue, forKey: Self.behaviorKey)
        }
        return decision
    }

    /// 注销、关机、重启时系统发的退出：系统不等人回答，进程也随之结束。
    private var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.typeCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .contains(AEEventID(reason))
    }

    /// 进程马上结束。存最后一次检查点，要结束的告诉 holder 结束。
    func applicationWillTerminate() {
        isQuitting = true
        for session in HeldTerminalSessions.all {
            session.finishHeldForQuit(endingSession: endsSessionsOnQuit)
        }
    }
}
