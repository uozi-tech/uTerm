import XCTest
import SwiftUI
import SwiftTerm
@testable import uTerm

/// 远控镜像（`TerminalMirrorTap`）：Mac 端会话被假后端驱动，订阅者的字节喂给一台「手机端」终端，
/// 两边的状态指纹（vendor 补丁 #6）必须最终一致。
@MainActor
final class TerminalMirrorTapTests: XCTestCase {

    private final class SilentDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let phoneDelegate = SilentDelegate()

    private func corpus(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "terminal-corpus-\(name)", withExtension: "bin"))
        return [UInt8](try Data(contentsOf: url))
    }

    private func connectedSession() async -> (TerminalSession, MockBackend) {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        return (session, backend)
    }

    private func phoneTerminal(matching mac: Terminal) -> Terminal {
        Terminal(delegate: phoneDelegate, options: TerminalOptions(cols: mac.cols, rows: mac.rows, scrollback: 2000))
    }

    /// 反复取走积压喂给手机端，直到两边一致或超时。返回最后一次的差异（空 = 一致）。
    private func drainUntilConsistent(_ subscriber: TerminalMirrorTap.Subscriber, mac: Terminal, phone: Terminal,
                                      timeout: TimeInterval = 3) async -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        var diff: [String: String] = ["未比对": ""]
        while Date() < deadline {
            while let bytes = subscriber.take(maxBytes: RemoteConstants.maxOutputChunkBytes) {
                phone.feed(byteArray: [UInt8](bytes))
            }
            diff = mac.snapshotFingerprint(historyLines: RemoteConstants.snapshotScrollback)
                .differences(from: phone.snapshotFingerprint(historyLines: RemoteConstants.snapshotScrollback))
            if diff.isEmpty && subscriber.pendingBytes == 0 { return [:] }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return diff
    }

    private func emit(_ bytes: [UInt8], to backend: MockBackend, chunk: Int = 433) async {
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + chunk)
            await backend.emitOutput(Data(bytes[offset..<end]))
            offset = end
        }
    }

    func test_attach_mid_session_then_stream_stays_identical() async throws {
        let (session, backend) = await connectedSession()
        let mac = session.terminalView.getTerminal()
        let data = try corpus("mixed")
        // 先跑一半再接入：接入时拿到的是快照。
        await emit(Array(data[0..<(data.count / 2)]), to: backend)
        try? await Task.sleep(for: .milliseconds(200))

        let phone = phoneTerminal(matching: mac)
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        await emit(Array(data[(data.count / 2)...]), to: backend)
        let diff = await drainUntilConsistent(subscriber, mac: mac, phone: phone)
        XCTAssertEqual(diff, [:])
        session.mirrorTap.unsubscribe(id: subscriber.id)
        session.dispose()
    }

    /// 订阅者一直不取（对端太慢）：积压超限后丢弃并改发快照，最终仍一致。
    func test_overflow_drops_backlog_and_resyncs_with_snapshot() async throws {
        let (session, backend) = await connectedSession()
        let mac = session.terminalView.getTerminal()
        let phone = phoneTerminal(matching: mac)
        let subscriber = session.mirrorTap.subscribe(id: UUID(), limit: 4 * 1024) {}
        await emit(try corpus("shell") + corpus("vim"), to: backend, chunk: 2048)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(subscriber.pendingBytes, 4 * 1024 + 70 * 1024, "积压被上限截住（快照本身可能超过上限）")
        let diff = await drainUntilConsistent(subscriber, mac: mac, phone: phone)
        XCTAssertEqual(diff, [:])
        session.dispose()
    }

    /// 清屏不走输出流：镜像端要靠重发快照对齐。
    func test_clear_output_resyncs() async throws {
        let (session, backend) = await connectedSession()
        let mac = session.terminalView.getTerminal()
        let phone = phoneTerminal(matching: mac)
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        await emit(try corpus("shell"), to: backend)
        _ = await drainUntilConsistent(subscriber, mac: mac, phone: phone)
        session.clearOutput()
        let diff = await drainUntilConsistent(subscriber, mac: mac, phone: phone)
        XCTAssertEqual(diff, [:])
        session.dispose()
    }

    /// 接管尺寸：Mac 终端钉成对端行列数，PTY 跟着调整，镜像端收到新尺寸下的快照。
    func test_pin_remote_grid_resizes_terminal_backend_and_mirror() async throws {
        let (session, backend) = await connectedSession()
        let mac = session.terminalView.getTerminal()
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        await emit(try corpus("shell"), to: backend)
        try? await Task.sleep(for: .milliseconds(100))

        session.pinRemoteGrid(cols: 57, rows: 23, controller: "测试 iPhone")
        XCTAssertEqual(mac.cols, 57)
        XCTAssertEqual(mac.rows, 23)
        XCTAssertEqual(session.remoteController, "测试 iPhone")
        try? await Task.sleep(for: .milliseconds(200))
        let lastResize = await backend.resizes.last
        XCTAssertEqual(lastResize?.cols, 57)
        XCTAssertEqual(lastResize?.rows, 23)

        let phone = Terminal(delegate: phoneDelegate, options: TerminalOptions(cols: 57, rows: 23, scrollback: 2000))
        await emit(try corpus("vim"), to: backend)
        let diff = await drainUntilConsistent(subscriber, mac: mac, phone: phone)
        XCTAssertEqual(diff, [:])

        session.unpinRemoteGrid()
        XCTAssertNil(session.remoteController)
        XCTAssertNil((session.terminalView as? CopyableTerminalView)?.pinnedFrameSize)
        session.dispose()
    }

    /// 手机连着变尺寸（Duo 展开 / 合上、转屏）：每一次 Mac 都要钉到恰好那个行列数。差一列 Claude Code 就按
    /// 另一个宽度画框，手机上的输入框整个错位（真机回归：手机 62 列，Mac 停在 61 列）。
    func test_pin_remote_grid_lands_exactly_after_a_sequence_of_sizes() async throws {
        let (session, _) = await connectedSession()
        let mac = session.terminalView.getTerminal()
        var misses: [String] = []
        let sizes = [(89, 32), (120, 40), (62, 30), (89, 32), (61, 29), (62, 30), (150, 45), (40, 20), (89, 32),
                     (88, 32), (90, 33), (63, 30), (62, 30)]
        for (cols, rows) in sizes {
            session.pinRemoteGrid(cols: cols, rows: rows, controller: "测试 iPhone")
            if mac.cols != cols || mac.rows != rows { misses.append("\(cols)×\(rows) → \(mac.cols)×\(mac.rows)") }
        }
        XCTAssertEqual(misses, [])
        session.dispose()
    }

    /// 原来这里核的是 `RemoteGridFit`（按实测列数逼近 SwiftTerm 视图宽度的二分）。Ghostty 没有内留白，视图钉成
    /// 「行列数 × 格子像素 ÷ 屏幕倍率」就正好是那个行列数，不需要逼近，算法已删；钉任意行列数都精确命中由
    /// `GhosttyMacHostTests` 在真的 surface 上核。
    func test_grid_fit_converges_even_when_the_cell_estimate_is_off() throws {
        throw XCTSkip("RemoteGridFit 随 SwiftTerm 一起删除：Ghostty 按格子像素直接算，见 GhosttyMacHostTests")
    }

    /// 钉住的终端比窗格矮：贴左上角；比窗格高、不知道光标在哪：贴底边（裁掉顶上的旧行）。
    func test_pinned_terminal_keeps_its_bottom_visible_when_taller_than_the_pane() {
        let insets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
        let pane = NSRect(x: 0, y: 0, width: 800, height: 500)

        let short = TerminalContainerView.pinnedFrame(NSSize(width: 400, height: 300), in: pane, insets: insets)
        XCTAssertEqual(short, NSRect(x: 8, y: 200, width: 400, height: 300), "放得下：顶边贴着窗格顶")

        let tall = TerminalContainerView.pinnedFrame(NSSize(width: 400, height: 700), in: pane, insets: insets)
        XCTAssertEqual(tall.minY, 6, "放不下：底边贴着窗格底（留出下边距）")
        XCTAssertEqual(tall.size, NSSize(width: 400, height: 700), "不缩放，行列数不变")
    }

    /// 接管状态条占窗格自己的高度：终端容器让到它下面，两者不重叠；断开后容器铺回整个窗格。
    func test_remote_control_banner_sits_above_the_terminal_instead_of_covering_it() async throws {
        let (session, _) = await connectedSession()
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500))
        defer { window.orderOut(nil) }
        let host = NSHostingView(rootView: RemoteControlledTerminal(session: session))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        window.contentView = host

        func settledContainerHeight() async throws -> CGFloat {
            try? await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            return try XCTUnwrap(session.terminalView.superview).frame.height
        }

        let bare = try await settledContainerHeight()
        XCTAssertEqual(bare, 500, accuracy: 0.5, "没人接管时没有状态条")

        session.pinRemoteGrid(cols: 57, rows: 23, controller: "测试 iPhone")
        let taken = try await settledContainerHeight()
        XCTAssertEqual(taken, 472, accuracy: 0.5, "状态条高 28pt，终端容器让到它下面")
        XCTAssertEqual(session.terminalView.getTerminal().rows, 23, "状态条不影响钉住的行列数")

        session.unpinRemoteGrid()
        let released = try await settledContainerHeight()
        XCTAssertEqual(released, 500, accuracy: 0.5, "断开后铺回整个窗格")
        session.dispose()
    }

    /// 比窗格高的钉住终端跟着光标走：光标在屏幕顶上（程序刚起来、刚清过屏）时贴顶，不裁；光标往下走，
    /// 从顶上按整行裁，裁到光标往下 3 行刚好在窗格里；光标到了最后几行就是贴底。
    func test_pinned_terminal_taller_than_the_pane_follows_the_cursor() {
        let insets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
        let pane = NSRect(x: 0, y: 0, width: 800, height: 500)
        let pinned = NSSize(width: 400, height: 700)   // 35 行，每行 20pt；窗格里放得下 494pt
        func frame(cursor: Int) -> NSRect {
            TerminalContainerView.pinnedFrame(pinned, in: pane, insets: insets, cursorRow: cursor, rows: 35)
        }
        XCTAssertEqual(frame(cursor: 2).maxY, 500, "光标在第 3 行：贴顶，一行不裁")
        XCTAssertEqual(frame(cursor: 20).maxY, 500, "光标往下 3 行（到第 24 行底，480pt）还在窗格里：仍然贴顶")
        XCTAssertEqual(frame(cursor: 26).maxY, 620, "光标在第 27 行：往下 3 行到 600pt，超出 106pt，按整行裁 6 行")
        XCTAssertEqual(frame(cursor: 34).minY, 6, "光标在最后一行：贴底")
        XCTAssertEqual(frame(cursor: 31).minY, 6, "往下留的 3 行已经到屏幕底：贴底，不会裁过头")
        for cursor in 0..<35 {
            let f = frame(cursor: cursor)
            let cut = f.maxY - 500
            XCTAssertGreaterThanOrEqual(cut, 0)
            XCTAssertLessThanOrEqual(CGFloat(cursor + 1) * 20 - cut, 494, "光标那一行（第 \(cursor + 1) 行）应当在窗格里")
            XCTAssertGreaterThanOrEqual(CGFloat(cursor) * 20 - cut, 0, "光标那一行（第 \(cursor + 1) 行）不该被裁在顶上")
        }
    }

    /// 真实链路：手机的行数比 Mac 窗格多。屏幕没写满（内容在顶上、下面是空行）时窗格里看到的是顶上那几行，
    /// 不是一屏空白；输出把光标推到屏幕底之后，窗格跟到底。
    /// 起因：user 用 iPhone Duo 接管本机终端里刚起来的 Claude Code，窗格里只剩输入框的下边线和一屏空白。
    func test_pinned_terminal_shows_the_cursor_rows_as_output_moves_it() async throws {
        let (session, backend) = await connectedSession()
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500))
        defer { window.orderOut(nil) }
        let host = NSHostingView(rootView: RemoteControlledTerminal(session: session))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        window.contentView = host
        func settle() async throws -> (view: NSRect, container: NSRect) {
            try? await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let container = try XCTUnwrap(session.terminalView.superview)
            return (session.terminalView.frame, container.bounds)
        }
        _ = try await settle()
        await emit(Array("\u{1B}[2J\u{1B}[Hwelcome\r\n> ".utf8), to: backend)
        session.pinRemoteGrid(cols: 57, rows: 60, controller: "测试 iPhone")
        let top = try await settle()
        XCTAssertGreaterThan(top.view.height, top.container.height, "用例前提：钉住的终端比窗格高")
        XCTAssertEqual(top.view.maxY, top.container.height, accuracy: 0.5, "光标在屏幕顶上：终端的顶边贴着窗格顶，内容不被裁掉")

        // 80 行输出把光标推到最后一行。
        await emit(Array((1...80).map { "line \($0)\r\n" }.joined().utf8), to: backend)
        let bottom = try await settle()
        XCTAssertEqual(session.terminalView.getTerminal().getCursorLocation().y, 59)
        XCTAssertEqual(bottom.view.minY, 6, accuracy: 0.5, "光标到了屏幕底：终端的底边贴着窗格底")

        // 清屏回到顶上：窗格跟回去。
        await emit(Array("\u{1B}[2J\u{1B}[H> ".utf8), to: backend)
        let again = try await settle()
        XCTAssertEqual(again.view.maxY, again.container.height, accuracy: 0.5, "清屏后光标回到顶上：窗格跟回顶上")
        session.dispose()
    }

    func test_tap_without_subscribers_is_inert() async throws {
        let (session, backend) = await connectedSession()
        XCTAssertFalse(session.mirrorTap.hasSubscribers)
        await emit(try corpus("htop"), to: backend)
        try? await Task.sleep(for: .milliseconds(100))
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        session.mirrorTap.unsubscribe(id: subscriber.id)
        XCTAssertFalse(session.mirrorTap.hasSubscribers)
        session.dispose()
    }
}
