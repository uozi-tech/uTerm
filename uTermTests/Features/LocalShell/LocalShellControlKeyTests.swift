import AppKit
import Carbon.HIToolbox
import XCTest
@testable import uTerm

/// 本机终端里 ⌃S / ⌃X 到没到程序。全链路都是真的：内嵌 XPC 服务起的登录 shell（在 `uterm-holder` 里，真 PTY）、
/// 挂在窗口里的 Ghostty surface、真 `NSEvent` 走窗口的分发顺序。「程序」是一段 perl：进 raw 模式，
/// 把收到的字节按键打成 `KEY<十六进制>` 一行。
@MainActor
final class LocalShellControlKeyTests: XCTestCase {

    private struct Pane {
        let session: TerminalSession
        let backend: LocalShellBackend
        let window: NSWindow
    }

    private static let namespace = "control-key-test"
    private let sessionID = UUID()
    private var client: LocalShellAgentClient!
    private var panes: [Pane] = []

    override func setUp() async throws {
        client = LocalShellAgentClient()
    }

    override func tearDown() async throws {
        for pane in panes {
            pane.session.dispose()
            await pane.backend.detach()
            pane.window.orderOut(nil)
        }
        panes = []
        await HolderProbe.terminate(sessionID, client: client, namespace: Self.namespace)
        client?.invalidate()
    }

    private func open() async -> Pane {
        let backend = LocalShellBackend(client: client, namespace: Self.namespace, sessionID: sessionID,
                                        columns: 100, rows: 30, writeImageToPasteboard: { _ in })
        let session = TerminalSession()
        session.attentionSink = { _ in }
        let view = session.ghostty.view
        view.performMenuKeyEquivalent = { _ in false }

        let rect = NSRect(x: 0, y: 0, width: 900, height: 560)
        let container = GhosttyContainerView(surface: view)
        container.isActive = true
        let window = ProbeWindow.make(contentRect: rect, contentView: container, placement: .transparentOnScreen)
        container.frame = window.contentView?.bounds ?? rect
        container.layoutSubtreeIfNeeded()
        let live = await waitUntil(10) { session.ghostty.isLive && session.ghostty.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪")
        await session.connect(using: backend)
        window.makeFirstResponder(view)
        let pane = Pane(session: session, backend: backend, window: window)
        panes.append(pane)
        return pane
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func screen(_ pane: Pane) -> String { pane.session.shadow.viewportText() }

    private func waitForShell(_ pane: Pane) async {
        pane.session.sendHostBytes(Data("echo SHELL_$((40+2))\n".utf8))
        let ready = await waitUntil(20) { self.screen(pane).contains("SHELL_42") }
        XCTAssertTrue(ready, "shell 没起来：\(screen(pane).suffix(400))")
    }

    /// raw 模式，先发 `setup`（键盘协议），再把收到的字节按键打出来；收到 `q` 退出并复位。
    private func startKeyEcho(in pane: Pane, setup: String) async {
        let script = #"perl -e '$|=1; system("stty raw -echo"); print ""# + setup + #"AGENT_"."READY\r\n"; $b=""; "#
            + #"while (sysread(STDIN,$c,1)) { $o=ord($c); last if $o==0x71; $b.=sprintf("%02X",$o); "#
            + #"if ($o==0x75 || $o==0x7E || ($o<0x20 && $o!=0x1B)) { print "K"."EY<$b>\r\n"; $b="" } } "#
            + #"print "\e[<u\e[>4m"; system("stty sane")'"#
        pane.session.sendHostBytes(Data((script + "\n").utf8))
        let ready = await waitUntil(10) { self.screen(pane).contains("AGENT_READY") }
        XCTAssertTrue(ready, "程序没起来：\(screen(pane).suffix(400))")
        // 键盘协议那几串要等 surface 解析到（影子先到）。
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func pressControl(_ letter: Character, _ keyCode: Int, in pane: Pane) {
        let control = String(UnicodeScalar(UInt8(letter.asciiValue! & 0x1F)))
        RealEvents.press(window: pane.window, characters: control, ignoring: String(letter), keyCode: keyCode,
                         modifiers: .control)
    }

    private func hex(_ text: String) -> String { text.utf8.map { String(format: "%02X", $0) }.joined() }

    /// 程序没开任何键盘协议（raw 模式）：⌃X、⌃S 是 0x18、0x13，一个不少。
    func testRawModeProgramReceivesControlXAndControlS() async {
        let pane = await open()
        await waitForShell(pane)
        await startKeyEcho(in: pane, setup: "")
        pressControl("x", kVK_ANSI_X, in: pane)
        pressControl("s", kVK_ANSI_S, in: pane)
        pressControl("a", kVK_ANSI_A, in: pane)
        let got = await waitUntil(5) { self.screen(pane).contains("KEY<01>") }
        print("[control-key] local raw screen: \(screen(pane).suffix(300))")
        XCTAssertTrue(got, String(screen(pane).suffix(400)))
        XCTAssertTrue(screen(pane).contains("KEY<18>"), "⌃X 没到程序")
        XCTAssertTrue(screen(pane).contains("KEY<13>"), "⌃S 没到程序")
    }

    /// 程序开了 Claude Code 2.1 的那一套（`CSI > 5 u` + modifyOtherKeys 2）：⌃X、⌃S 是 `CSI 120;5u`、`CSI 115;5u`。
    func testClaudeKeyboardSetupProgramReceivesControlXAndControlS() async {
        let pane = await open()
        await waitForShell(pane)
        await startKeyEcho(in: pane, setup: #"\e[<u\e[>5u\e[>4;2m"#)
        XCTAssertEqual(pane.session.shadow.kittyKeyboardFlags, 5)
        pressControl("x", kVK_ANSI_X, in: pane)
        pressControl("s", kVK_ANSI_S, in: pane)
        pressControl("a", kVK_ANSI_A, in: pane)
        let got = await waitUntil(5) { self.screen(pane).contains("KEY<\(self.hex("\u{1b}[97;5u"))>") }
        print("[control-key] local claude-setup screen: \(screen(pane).suffix(300))")
        XCTAssertTrue(got, String(screen(pane).suffix(400)))
        XCTAssertTrue(screen(pane).contains("KEY<\(hex("\u{1b}[120;5u"))>"), "⌃X 没到程序")
        XCTAssertTrue(screen(pane).contains("KEY<\(hex("\u{1b}[115;5u"))>"), "⌃S 没到程序")
    }

    // MARK: 真 Claude Code（默认跳过）

    private func flags(_ modifiers: NSEvent.ModifierFlags, in pane: Pane) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: pane.window.windowNumber,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                         keyCode: UInt16(kVK_Control))!
    }

    /// 像真键盘那样按一次 ⌃ + 字母：⌃ 按下（flagsChanged）→ 字母按下、抬起 → ⌃ 抬起。
    private func holdControlAndPress(_ letter: Character, _ keyCode: Int, in pane: Pane) async {
        pane.window.sendEvent(flags(.control, in: pane))
        try? await Task.sleep(for: .milliseconds(40))
        pressControl(letter, keyCode, in: pane)
        try? await Task.sleep(for: .milliseconds(40))
        pane.window.sendEvent(flags([], in: pane))
    }

    /// 指针移到终端中间（之后不再动）。`onCellEdge`：停在两格交界左边半个点上（往右 1 pt 就进了下一格）。
    private func parkPointer(in pane: Pane, onCellEdge: Bool = false) {
        let view = pane.session.ghostty.view
        var inView = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        if onCellEdge, let cell = view.uTermCellPixels {
            let width = cell.width / pane.window.backingScaleFactor
            inView.x = (inView.x / width).rounded() * width - 0.5
        }
        view.mouseMoved(with: RealEvents.mouse(.mouseMoved, window: pane.window, at: view.convert(inView, to: nil)))
    }

    /// 开关与目录同 `LocalShellAgentImagePasteTests.testRealClaudeCodeTakesCommandV`。只启动到首屏、不发提示词。
    private func launchClaude(_ prefix: String = "") async throws -> Pane {
        let env = ProcessInfo.processInfo.environment
        guard env["UTERM_E2E_LOCAL_CLAUDE"] == "1" else { throw XCTSkip("没设 UTERM_E2E_LOCAL_CLAUDE") }
        let pane = await open()
        await waitForShell(pane)
        let workdir = env["UTERM_E2E_LOCAL_CLAUDE_DIR"] ?? "/tmp"
        pane.session.sendHostBytes(Data("cd '\(workdir)' && \(prefix)claude --debug-file /tmp/uterm-local-claude-keys-e2e.log\n".utf8))
        let reported = await waitUntil(40) { pane.session.programStatusTracker.hasRecords }
        XCTAssertTrue(reported, "Claude Code 没报状态：\(screen(pane).suffix(800))")
        try await Task.sleep(for: .seconds(2))
        let shadow = pane.session.shadow
        let modes = [1000, 1002, 1003, 1006, 1016].map { "\($0)=\(shadow.isModeSet(UInt16($0)))" }.joined(separator: " ")
        print("[control-key] claude kitty flags = \(shadow.kittyKeyboardFlags) mouse \(modes) captured=\(pane.session.ghostty.view.isMouseCaptured)")
        return pane
    }

    private func quitClaude(_ pane: Pane) async {
        for _ in 0..<3 {
            pane.session.sendHostBytes(Data([0x03]))
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private static let marker = "zqstashprobe"

    private func typeMarker(in pane: Pane) async throws {
        for character in Self.marker {
            RealEvents.press(window: pane.window, characters: String(character), keyCode: RealEvents.keyCode(for: character))
            try await Task.sleep(for: .milliseconds(30))
        }
        let typed = await waitUntil(5) { self.screen(pane).contains(Self.marker) }
        XCTAssertTrue(typed, "字没打进输入框：\(screen(pane).suffix(800))")
    }

    /// 输入框里打几个字，⌃S 收起来（输入框空了），再 ⌃S 放回来。指针不在终端上。
    func testRealClaudeCodeStashesOnControlS() async throws {
        let pane = try await launchClaude()
        try await typeMarker(in: pane)
        await holdControlAndPress("s", kVK_ANSI_S, in: pane)
        let stashed = await waitUntil(5) { !self.screen(pane).contains(Self.marker) }
        XCTAssertTrue(stashed, "⌃S 之后输入框里的字还在：Claude Code 没收到 ⌃S")
        await holdControlAndPress("s", kVK_ANSI_S, in: pane)
        let restored = await waitUntil(5) { self.screen(pane).contains(Self.marker) }
        XCTAssertTrue(restored, "再按 ⌃S 没放回来")
        await quitClaude(pane)
    }

    /// 同上，指针停在终端上（平时就是这样）。
    func testRealClaudeCodeStashesOnControlSWithPointerOverTerminal() async throws {
        let pane = try await launchClaude()
        try await typeMarker(in: pane)
        parkPointer(in: pane)
        try await Task.sleep(for: .milliseconds(300))
        await holdControlAndPress("s", kVK_ANSI_S, in: pane)
        let stashed = await waitUntil(5) { !self.screen(pane).contains(Self.marker) }
        print("[control-key] claude pointer-over after ⌃S:\n\(screen(pane).suffix(500))")
        XCTAssertTrue(stashed, "指针停在终端上时 ⌃S 之后输入框里的字还在：Claude Code 没收到 ⌃S")
        await quitClaude(pane)
    }

    /// ⌃X ⌃E（在外部编辑器里编辑输入）：两下之间松开过 ⌃。编辑器换成一个只留记号的脚本。指针停在终端上。
    func testRealClaudeCodeControlXChordWithPointerOverTerminal() async throws {
        let token = "CHORD\(Int.random(in: 100_000...999_999))"
        let editor = "/tmp/uterm-chord-editor.sh"
        let pane = try await launchClaude(
            "printf '#!/bin/sh\\necho \(token) > /tmp/uterm-chord-e2e.txt\\n' > \(editor) && chmod +x \(editor) && EDITOR=\(editor) ")
        try await typeMarker(in: pane)
        parkPointer(in: pane)
        try await Task.sleep(for: .milliseconds(300))
        await holdControlAndPress("x", kVK_ANSI_X, in: pane)
        try await Task.sleep(for: .milliseconds(300))
        print("[control-key] claude pointer-over after ⌃X:\n\(screen(pane).suffix(400))")
        await holdControlAndPress("e", kVK_ANSI_E, in: pane)
        try await Task.sleep(for: .seconds(2))
        await quitClaude(pane)
        pane.session.sendHostBytes(Data("clear; echo RESULT_$(cat /tmp/uterm-chord-e2e.txt)_END; rm -f /tmp/uterm-chord-e2e.txt \(editor)\n".utf8))
        let done = await waitUntil(10) { self.screen(pane).contains("_END") && !self.screen(pane).contains("$(cat") }
        XCTAssertTrue(done, String(screen(pane).suffix(400)))
        XCTAssertTrue(screen(pane).contains("RESULT_\(token)_END"), "⌃X ⌃E 没打开编辑器：Claude Code 没收到这一组按键。\(screen(pane).suffix(300))")
    }

    /// 指针停在两格交界上：按下 ⌃ 那一下不该让 Claude Code 收到鼠标移动，⌃S 照常收起输入。
    func testRealClaudeCodeStashesOnControlSWithPointerOnCellEdge() async throws {
        let pane = try await launchClaude()
        try await typeMarker(in: pane)
        parkPointer(in: pane, onCellEdge: true)
        try await Task.sleep(for: .milliseconds(300))
        await holdControlAndPress("s", kVK_ANSI_S, in: pane)
        let stashed = await waitUntil(5) { !self.screen(pane).contains(Self.marker) }
        print("[control-key] claude cell-edge after ⌃S:\n\(screen(pane).suffix(500))")
        XCTAssertTrue(stashed, "指针停在格子交界上时 ⌃S 之后输入框里的字还在：Claude Code 没收到 ⌃S")
        await quitClaude(pane)
    }

    /// 同上，⌃X ⌃E。
    func testRealClaudeCodeControlXChordWithPointerOnCellEdge() async throws {
        let token = "CHORD\(Int.random(in: 100_000...999_999))"
        let editor = "/tmp/uterm-chord-editor.sh"
        let pane = try await launchClaude(
            "printf '#!/bin/sh\\necho \(token) > /tmp/uterm-chord-e2e.txt\\n' > \(editor) && chmod +x \(editor) && EDITOR=\(editor) ")
        try await typeMarker(in: pane)
        parkPointer(in: pane, onCellEdge: true)
        try await Task.sleep(for: .milliseconds(300))
        await holdControlAndPress("x", kVK_ANSI_X, in: pane)
        try await Task.sleep(for: .milliseconds(300))
        await holdControlAndPress("e", kVK_ANSI_E, in: pane)
        try await Task.sleep(for: .seconds(2))
        await quitClaude(pane)
        pane.session.sendHostBytes(Data("clear; echo RESULT_$(cat /tmp/uterm-chord-e2e.txt)_END; rm -f /tmp/uterm-chord-e2e.txt \(editor)\n".utf8))
        let done = await waitUntil(10) { self.screen(pane).contains("_END") && !self.screen(pane).contains("$(cat") }
        XCTAssertTrue(done, String(screen(pane).suffix(400)))
        XCTAssertTrue(screen(pane).contains("RESULT_\(token)_END"), "指针停在格子交界上时 ⌃X ⌃E 没打开编辑器。\(screen(pane).suffix(300))")
    }
}
