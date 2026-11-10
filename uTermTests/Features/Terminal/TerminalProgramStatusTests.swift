import AppKit
import SwiftTerm
import UDesignKit
import UserNotifications
import XCTest
@testable import uTerm

/// 字节流 → 会话状态 → 通知 / 标签。序列取自 Claude Code 2.1.318、Codex 0.166 的实测。
@MainActor
final class TerminalProgramStatusTests: XCTestCase {

    private var session: TerminalSession!
    private var attentions: [TerminalAttention] = []

    override func setUp() async throws {
        attentions = []
        session = TerminalSession()
        session.attentionSink = { [unowned self] in self.attentions.append($0) }
    }

    override func tearDown() async throws {
        session = nil
    }

    private func osc(_ code: Int, _ payload: String) {
        session.feedOutput(text: "\u{1b}]\(code);\(payload)\u{1b}\\")
    }

    private func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    func testQueryIsAnsweredThroughBackend() async throws {
        let backend = MockBackend()
        await session.connect(using: backend)

        osc(7501, "?")

        try await waitUntil { await backend.writtenData.contains(Data("\u{1b}]7501;?\u{1b}\\".utf8)) }
    }

    func testClaudeCodePermissionFlow() {
        osc(7501, "state=idle:app=claude-code")
        XCTAssertNil(session.programStatus, "空闲不上标签")

        osc(7501, "state=working:app=claude-code")
        XCTAssertEqual(session.programStatus?.state, .working)
        XCTAssertTrue(attentions.isEmpty)

        osc(7501, "state=blocked:app=claude-code:kind=permission:msg=\(base64("approve Bash: ls"))")
        XCTAssertEqual(session.programStatus?.kind, .permission)
        XCTAssertEqual(attentions, [TerminalAttention(title: "Claude Code 等待确认", body: "approve Bash: ls")])

        osc(7501, "state=working:app=claude-code")
        osc(7501, "state=done:app=claude-code")
        XCTAssertEqual(session.programStatus?.state, .done)
        XCTAssertEqual(attentions.last, TerminalAttention(title: "Claude Code 已完成", body: ""))
        XCTAssertEqual(attentions.count, 2)
    }

    /// Codex 启动时没有 prompt 也会 working → idle，不能发通知。
    func testCodexStartupDoesNotNotify() {
        osc(7501, "state=idle:app=codex")
        osc(7501, "state=working:app=codex")
        osc(7501, "state=idle:app=codex")
        XCTAssertTrue(attentions.isEmpty)
        XCTAssertNil(session.programStatus)
    }

    func testProgramClearRemovesStatus() {
        osc(7501, "state=working:app=codex")
        osc(7501, "state=clear")
        XCTAssertNil(session.programStatus)
    }

    /// 用户正看着这个终端：不发通知，结果也不用留标记。
    func testResultWhileLookingIsNeitherNotifiedNorKept() {
        session.applyProgramStatus(.report(id: "", record: ProgramStatusRecord(state: .done)), isLooking: true)
        XCTAssertTrue(attentions.isEmpty)
        XCTAssertNil(session.programStatus)
    }

    func testBlockedWhileLookingStaysOnTabWithoutNotification() {
        session.applyProgramStatus(.report(id: "", record: ProgramStatusRecord(state: .blocked)), isLooking: true)
        XCTAssertTrue(attentions.isEmpty)
        XCTAssertEqual(session.programStatus?.state, .blocked)
    }

    func testAcknowledgeClearsResultFromTab() {
        osc(7501, "state=done:app=codex")
        XCTAssertEqual(session.programStatus?.state, .done)
        session.acknowledgeProgramStatus()
        XCTAssertNil(session.programStatus)
    }

    func testFocusGainAcknowledgesResult() throws {
        osc(7501, "state=done:app=codex")
        XCTAssertTrue(session.ghostty.view.becomeFirstResponder())
        XCTAssertNil(session.programStatus)
    }

    /// 从别的 app 切回来：焦点一直在这个终端上，只有窗口重新成为 key。
    func testWindowBecomingKeyAcknowledgesResult() throws {
        // Ghostty 的视图在「窗口成为 key」时会核对窗口真的是 key；测试宿主不一定在前台，用一个自称 key 的窗口。
        final class KeyWindow: NSWindow {
            override var isKeyWindow: Bool { true }
        }
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(session.ghostty.view)
        XCTAssertTrue(window.makeFirstResponder(session.ghostty.view))

        session.applyProgramStatus(.report(id: "", record: ProgramStatusRecord(state: .done)), isLooking: false)
        XCTAssertEqual(session.programStatus?.state, .done)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertNil(session.programStatus)
    }

    /// 程序被 kill -9 时来不及报告：新提示符说明它已经不在了。
    func testNewPromptDropsStaleRunningStatus() {
        osc(7501, "state=working:app=claude-code")
        osc(133, "A")
        XCTAssertNil(session.programStatus)
    }

    func testNewPromptKeepsUnseenResult() {
        osc(7501, "state=done:app=claude-code")
        osc(133, "A")
        XCTAssertEqual(session.programStatus?.state, .done)
    }

    /// 接管 OSC 133 后，SwiftTerm 内置的语义提示符处理不能断。
    func testSemanticPromptStillReachesSwiftTerm() {
        osc(133, "A")
        let terminal = session.terminalView.getTerminal()
        XCTAssertNotNil(terminal.activeSemanticPromptOrigin)
    }

    func testDisconnectClearsStatus() {
        osc(7501, "state=blocked:app=codex")
        session.markFailed("断了")
        XCTAssertNil(session.programStatus)
    }

    // MARK: OSC 9 / 777

    func testOSC9PlainTextNotifies() {
        osc(9, "build finished")
        XCTAssertEqual(attentions, [TerminalAttention(title: "终端通知", body: "build finished")])
    }

    /// 接管 OSC 9 后，`9;4` 仍是进度条，不是通知。
    func testOSC9ProgressIsNotANotification() {
        osc(9, "4;1;50")
        XCTAssertTrue(attentions.isEmpty)
    }

    func testOSC9ConEmuCommandIsNotANotification() {
        osc(9, "9;/home/me")
        XCTAssertTrue(attentions.isEmpty)
    }

    func testOSC777Notifies() {
        osc(777, "notify;标题;正文;带分号")
        XCTAssertEqual(attentions, [TerminalAttention(title: "标题", body: "正文;带分号")])
    }

    func testOSC777IgnoresOtherCommands() {
        osc(777, "preexec;x;y")
        XCTAssertTrue(attentions.isEmpty)
    }

    func testNotificationTextDropsControlCharacters() {
        XCTAssertEqual(TerminalAttention.notification(title: "", body: "a\u{7f}b"),
                       TerminalAttention(title: "终端通知", body: "ab"))
    }

    func testBlankNotificationIsIgnored() {
        XCTAssertNil(TerminalAttention.notification(title: "", body: "   "))
    }

    // MARK: 限频

    func testRateLimiterIsPerSession() {
        var limiter = TerminalAttentionRateLimiter()
        let first = UUID()
        let second = UUID()
        let start = Date()
        XCTAssertTrue(limiter.allows(first, at: start))
        XCTAssertFalse(limiter.allows(first, at: start.addingTimeInterval(1)))
        XCTAssertTrue(limiter.allows(second, at: start.addingTimeInterval(1)))
        XCTAssertTrue(limiter.allows(first, at: start.addingTimeInterval(2)))
    }

    // MARK: 标签与回跳

    func testTabShowsProgramStatus() {
        let pane = PaneModel(serverProfileID: UUID(), tabTitle: "web-1")
        let tab = TerminalTab(payload: pane)
        XCTAssertEqual(TerminalArea.descriptor(for: tab, profiles: [:]).icon, .none)

        pane.session.feedOutput(text: "\u{1b}]7501;state=blocked:app=claude-code:kind=question\u{1b}\\")

        let descriptor = TerminalArea.descriptor(for: tab, profiles: [:])
        XCTAssertEqual(descriptor.icon, .none, "程序状态也只由圆点表达")
        XCTAssertEqual(descriptor.leadingDot, UD.warning)
        XCTAssertEqual(descriptor.help?.hasPrefix("Claude Code · 等待回答"), true)
    }

    func testRegistryRevealsSessionThroughItsWindow() {
        let registry = TerminalSessionRegistry()
        let windowID = UUID()
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "web-1",
                                               windowID: windowID, windowKind: TerminalWindowKind.terminal,
                                               title: "web-1"),
                          session: session)
        XCTAssertEqual(registry.sessionID(of: session), sessionID)
        XCTAssertFalse(registry.requestReveal(sessionID: sessionID), "窗口还没登记入口")

        var revealed: UUID?
        registry.setRevealer(forWindow: windowID) { revealed = $0; return true }

        XCTAssertTrue(registry.requestReveal(sessionID: sessionID))
        XCTAssertEqual(revealed, sessionID)
        XCTAssertFalse(registry.requestReveal(sessionID: UUID()))

        registry.forgetWindow(windowID)
        XCTAssertFalse(registry.requestReveal(sessionID: sessionID))
    }

    // MARK: 通知中心

    func testRequestCarriesSessionAndTabTitle() {
        let id = UUID()
        let attention = TerminalAttention(title: "Claude Code", body: "approve Bash")

        let request = TerminalAttentionCenter.makeRequest(attention, sessionID: id, subtitle: "web-1")

        XCTAssertEqual(request.content.title, "Claude Code")
        XCTAssertEqual(request.content.subtitle, "web-1")
        XCTAssertEqual(request.content.body, "approve Bash")
        // 同一会话共用 identifier：新通知替换旧的。
        XCTAssertEqual(request.identifier,
                       TerminalAttentionCenter.makeRequest(attention, sessionID: id, subtitle: "").identifier)
    }

    /// 通知上的名字跟标签一致：程序设了标题就用它，不用打开时定下的 `zsh 2`。
    func testSubtitleFollowsShellTitleLikeTheTab() {
        let registry = TerminalSessionRegistry()
        let center = TerminalAttentionCenter()
        center.start(registry: registry)
        registry.register(TerminalSessionEntry(id: UUID(), serverID: UUID(), serverName: "本机",
                                               windowID: UUID(), windowKind: TerminalWindowKind.terminal,
                                               title: "zsh 2"),
                          session: session)
        XCTAssertEqual(center.subtitle(for: session), "zsh 2")

        let long = "alice@web-1: /var/www/releases/2026/current/public/assets"
        session.feedOutput(text: "\u{1b}]0;\(long)\u{07}")
        XCTAssertEqual(center.subtitle(for: session), long, "标签才截短，通知放全文")

        session.receiveShellTitle("第一行\n伪造的第二行")
        XCTAssertEqual(center.subtitle(for: session), "第一行伪造的第二行")

        session.feedOutput(text: "\u{1b}]0;   \u{07}")
        XCTAssertEqual(center.subtitle(for: session), "zsh 2", "程序清掉标题后回到原名")
    }

    func testClickingNotificationRevealsItsSession() {
        let registry = TerminalSessionRegistry()
        let center = TerminalAttentionCenter()
        center.start(registry: registry)
        let windowID = UUID()
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "web-1",
                                               windowID: windowID, windowKind: TerminalWindowKind.terminal,
                                               title: "web-1"),
                          session: session)
        var revealed: [UUID] = []
        registry.setRevealer(forWindow: windowID) { revealed.append($0); return true }
        let request = TerminalAttentionCenter.makeRequest(TerminalAttention(title: "t", body: "b"),
                                                          sessionID: sessionID,
                                                          subtitle: "")

        center.handleNotificationClick(userInfo: request.content.userInfo)
        center.handleNotificationClick(userInfo: [:])

        XCTAssertEqual(revealed, [sessionID])
    }

    func testWorkspaceRevealActivatesTab() {
        let workspace = WorkspaceModel()
        let first = PaneModel(serverProfileID: UUID())
        let second = PaneModel(serverProfileID: UUID())
        let firstTab = TerminalTab(payload: first)
        let secondTab = TerminalTab(payload: second)
        workspace.terminalGroups.openTab({ firstTab }, in: nil)
        workspace.terminalGroups.openTab({ secondTab }, in: nil)
        XCTAssertEqual(workspace.terminalGroups.activeTab?.payload.id, second.id)

        XCTAssertTrue(workspace.revealTerminal(paneID: first.id))
        XCTAssertEqual(workspace.terminalGroups.activeTab?.payload.id, first.id)
        XCTAssertFalse(workspace.revealTerminal(paneID: UUID()))
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待超时")
    }
}
