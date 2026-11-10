import AppKit
import Carbon.HIToolbox
import SwiftData
import XCTest
@testable import uTerm

/// 真 sshd 上的真 Claude Code / Codex：对端协议变了，只有这里能发现。
///
/// 默认跳过。对端要能在登录 shell 里找到 `claude` / `codex`，且已登录（会消耗少量额度）。
/// xcodebuild 传环境变量要加 `TEST_RUNNER_` 前缀：
/// - `UTERM_E2E_SSH_PORT`、`UTERM_E2E_SSH_USER`：127.0.0.1 上的 sshd
/// - `UTERM_E2E_SSH_KEY_B64`：base64 编码的私钥（测试宿主有沙盒，读不了任意路径）
/// - `UTERM_E2E_WORKDIR`：Agent 的工作目录，要已被它们信任
///
/// 终端挂在真窗口里（Ghostty 的 surface 要答 Agent 启动时发的各种查询）；读屏、状态、通知读的是影子终端那一侧
/// （`snapshotScreen` / `programStatus`），键入走会话的输入通道，和 App 里一样。
@MainActor
final class AgentE2ETests: XCTestCase {

    private struct Server {
        let port: Int
        let user: String
        let pem: String
        let workdir: String
    }

    private var server: Server!
    private var session: TerminalSession!
    private var connection: SSHConnection!
    private var view: GhosttySurfaceView!
    private var window: NSWindow!
    private var extraWindows: [NSWindow] = []
    private var attentions: [TerminalAttention] = []
    /// 状态变化序列，失败时用来看 Agent 实际走过哪些状态。
    private var statusLog: [String] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["UTERM_E2E_SSH_PORT"].flatMap(Int.init),
              let user = env["UTERM_E2E_SSH_USER"],
              let key = env["UTERM_E2E_SSH_KEY_B64"].flatMap({ Data(base64Encoded: $0) }),
              let workdir = env["UTERM_E2E_WORKDIR"] else {
            throw XCTSkip("没设 UTERM_E2E_*")
        }
        server = Server(port: port, user: user, pem: String(decoding: key, as: UTF8.self), workdir: workdir)
        attentions = []
        (session, connection) = try await openSession()
        session.attentionSink = { [unowned self] in self.attentions.append($0) }
        view = session.ghostty.view
        // 真的主菜单会把 ⌘ 组合执行掉；这里只按 ⌃V，保险起见仍然不问它。
        view.performMenuKeyEquivalent = { _ in false }
        window = try await mount(session, size: NSSize(width: 1100, height: 700))
        // 焦点不在终端上 = 用户没在看：状态变化该发通知。
        window.makeFirstResponder(nil)
    }

    override func tearDown() async throws {
        await connection?.close()
        session?.dispose()
        window?.orderOut(nil)
        extraWindows.forEach { $0.orderOut(nil) }
        extraWindows = []
    }

    /// 把会话的终端挂进一个透明、在屏上的窗口（引擎要有显示节拍），等 surface 建好、开始吃实时字节。
    private func mount(_ session: TerminalSession, size: NSSize) async throws -> NSWindow {
        let rect = NSRect(origin: .zero, size: size)
        let container = GhosttyContainerView(surface: session.ghostty.view)
        let window = ProbeWindow.make(contentRect: rect, styleMask: [.titled], contentView: container,
                                      placement: .transparentOnScreen)
        container.frame = window.contentView?.bounds ?? rect
        container.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(10)
        while !session.ghostty.isLive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.ghostty.isLive, "Ghostty surface 没就绪")
        return window
    }

    private func openSession() async throws -> (TerminalSession, SSHConnection) {
        let profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = server.port
        profile.username = server.user
        let container = try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let connection = SSHConnection(
            profile: SSHConnection.ProfileSnapshot(profile),
            auth: .privateKey(username: server.user, pem: server.pem, passphrase: nil),
            jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container),
            hostKeyApprover: { _ in true })
        let session = TerminalSession()
        await session.connect(using: connection)
        return (session, connection)
    }

    // MARK: 操作与等待

    /// Agent 把一次收到的「文字 + 回车」当粘贴，回车不提交，要分开发。
    private func submit(_ text: String) async throws {
        type(text)
        try await Task.sleep(for: .milliseconds(600))
        type("\r")
    }

    private func type(_ text: String, to target: TerminalSession? = nil) {
        let target = target ?? session!
        // 和键盘输入同一条有序通道。
        target.sendHostBytes(Data(text.utf8))
    }

    /// 最近 400 行（含回滚），读的是影子终端。
    private func screen(of target: TerminalSession? = nil) -> String {
        let target = target ?? session!
        return target.snapshotScreen(lines: 400, maxBytes: 1 << 20).lines.joined(separator: "\n")
    }

    private func waitUntil(_ what: String,
                           seconds: Int = 120,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            recordStatus()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("等「\(what)」超时。状态序列：\(statusLog)\n屏幕：\n\(screen())")
        throw CancellationError()
    }

    private func recordStatus() {
        let current = session.programStatus.map { "\($0.state)/\($0.app ?? "-")" } ?? "nil"
        if statusLog.last != current { statusLog.append(current) }
    }

    /// 等到 Agent 的输入框出现。Claude Code 在第一条提示前不上报状态，所以不能拿状态判断。
    private func start(_ command: String) async throws {
        try await waitUntil("shell 提示符") { screen().contains("%") || screen().contains("$") }
        type("cd '\(server.workdir)' && exec \(command)\r")
        try await waitUntil("输入框") { screen().contains("for shortcuts") }
    }

    private func controlV() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "\u{16}", charactersIgnoringModifiers: "v",
                                       isARepeat: false, keyCode: UInt16(kVK_ANSI_V)))
    }

    private func redPNG() throws -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let rep = try XCTUnwrap(image)
        for x in 0..<64 {
            for y in 0..<64 {
                rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: Claude Code

    func testClaudeCodePermissionResultAndImagePaste() async throws {
        try await start("claude --model haiku --permission-mode default --strict-mcp-config")
        XCTAssertTrue(attentions.isEmpty, "启动不该发通知：\(attentions)")

        // 要批准的命令：标签转等待确认，并发通知。
        try await submit("Use the Bash tool to run exactly: touch /tmp/uterm-e2e-marker")
        try await waitUntil("等待确认") { session.programStatus?.state == .blocked }
        XCTAssertEqual(session.programStatus?.kind, .permission)
        XCTAssertEqual(session.programStatus?.app, "claude-code")
        XCTAssertEqual(attentions.count, 1, "\(attentions)")
        XCTAssertTrue(attentions.first?.body.contains("touch") == true, "\(attentions)")
        XCTAssertTrue(session.programStatus?.message?.contains("touch") == true)

        // 批准后跑完：没看着时结果留在标签上，再通知一次。
        type("\r")
        try await waitUntil("完成") { session.programStatus?.state == .done }
        XCTAssertEqual(attentions.count, 2, "\(attentions)")

        // 回到这个终端：结果算看过了。
        window.makeFirstResponder(view)
        XCTAssertNotEqual(session.programStatus?.state, .done)

        // ⌃V 只有图片的剪贴板：传到对端，Claude 真的读得到。
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("uterm-e2e-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(try redPNG(), forType: .png)
        view.pasteboard = pasteboard
        XCTAssertTrue(view.performKeyEquivalent(with: try controlV()))
        try await waitUntil("图片占位") { screen().contains("[Image #1]") }
        try await submit("Reply with exactly COLOR= followed by the image's main color in uppercase.")
        try await waitUntil("Claude 看到图", seconds: 180) {
            screen().contains("COLOR=RED") || screen().contains("COLOR=#FF0000")
        }

        // 上传的文件只有本人可读。
        let (shell, shellConnection) = try await openSession()
        extraWindows.append(try await mount(shell, size: NSSize(width: 900, height: 400)))
        try await waitUntil("shell 提示符") { screen(of: shell).contains("%") || screen(of: shell).contains("$") }
        type("ls -t /tmp/uterm-image-* | head -1 | xargs stat -f MODE=%Lp; rm -f /tmp/uterm-image-* /tmp/uterm-e2e-marker\r",
             to: shell)
        try await waitUntil("文件权限") { screen(of: shell).contains("MODE=600") }
        await shellConnection.close()
        shell.dispose()
    }

    // MARK: Codex

    func testCodexReportsResult() async throws {
        try await start("codex")
        XCTAssertTrue(attentions.isEmpty, "启动不该发通知：\(attentions)")

        // 服务端容量不足是外部状态，多试几次；这条路径上 error 也要发通知。
        for attempt in 1...3 {
            attentions.removeAll()
            try await submit("Reply with exactly ANSWER= followed by the sum of 40 and 2. Do not run any tools.")
            try await waitUntil("结果通知", seconds: 180) { !attentions.isEmpty }
            XCTAssertEqual(attentions.count, 1, "\(attentions)")
            if session.programStatus?.state != .error { break }
            guard screen().contains("at capacity") else { return XCTFail("Codex 报错：\n\(screen())") }
            if attempt == 3 { throw XCTSkip("Codex 服务容量不足，error 路径已走过，完成路径没测到") }
            try await Task.sleep(for: .seconds(30))
        }
        try await waitUntil("回答") { screen().contains("ANSWER=42") }
        XCTAssertTrue(statusLog.contains("working/codex"), "\(statusLog)")
    }
}
