import XCTest
import SwiftUI
@testable import uTerm

/// 远控镜像（`TerminalMirrorTap`）：Mac 端会话被假后端驱动（字节经输出泵的入站任务进来，和正式路径一样），
/// 订阅者取到的快照段与字节交给一台「手机端」影子终端，两边读到的画面必须最终一致。
/// 不经入站任务、直接喂字节的那一组在 `TerminalMirrorSnapshotTests`。
@MainActor
final class TerminalMirrorTapTests: XCTestCase {

    private func connectedSession() async -> (TerminalSession, MockBackend) {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        let backend = MockBackend()
        await session.connect(using: backend)
        return (session, backend)
    }

    /// 手机端：和 Mac 此刻同样行列数的影子终端 + 泵。
    private func phone(matching session: TerminalSession) -> MirrorPhone {
        let size = session.shadow.size
        return MirrorPhone(cols: size.cols, rows: size.rows)
    }

    /// 取走订阅者攒着的全部数据交给手机端：快照段过一遍线上的编码再拼回，字节原样喂。
    private func drain(_ subscriber: TerminalMirrorTap.Subscriber, into phone: MirrorPhone, assembly: SnapshotAssembly) {
        while let chunk = subscriber.take(maxBytes: RemoteConstants.maxOutputChunkBytes) {
            switch chunk {
            case .snapshot(let piece, let isFirst, let isLast):
                let wire = RemoteTerminalSnapshotPiece.encode(piece, isFirst: isFirst, isLast: isLast)
                guard let decoded = RemoteTerminalSnapshotPiece.decode(wire) else { return XCTFail("快照段解不开") }
                if let snapshot = assembly.append(decoded.data, isFirst: decoded.isFirst, isLast: decoded.isLast) {
                    phone.pump.applySnapshot(snapshot)
                }
            case .output(let bytes):
                phone.pump.route(bytes)
            }
        }
    }

    /// 反复取走积压喂给手机端，直到两边一致（且 Mac 已经吃完 `fedBytes` 字节）或超时。返回最后一次的差异（空 = 一致）。
    private func drainUntilConsistent(_ subscriber: TerminalMirrorTap.Subscriber, session: TerminalSession,
                                      phone: MirrorPhone, fedBytes: Int? = nil,
                                      timeout: TimeInterval = 5) async -> [String: String] {
        let assembly = SnapshotAssembly()
        let deadline = Date().addingTimeInterval(timeout)
        var diff: [String: String] = ["未比对": ""]
        while Date() < deadline {
            drain(subscriber, into: phone, assembly: assembly)
            let macCaughtUp = fedBytes.map { session.shadow.totalFedBytes >= $0 } ?? true
            diff = session.shadow.mirrorDifferences(from: phone.shadow)
            if macCaughtUp, diff.isEmpty, subscriber.pendingBytes == 0 { return [:] }
            if !macCaughtUp { diff["Mac 还没吃完"] = "\(session.shadow.totalFedBytes) / \(fedBytes ?? 0)" }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return diff
    }

    private func emit(_ bytes: Data, to backend: MockBackend, chunk: Int = 433) async {
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(bytes.endIndex, offset + chunk)
            await backend.emitOutput(Data(bytes[offset..<end]))
            offset = end
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: 字节流

    func test_attach_mid_session_then_stream_stays_identical() async throws {
        let (session, backend) = await connectedSession()
        defer { session.dispose() }
        let data = try TerminalCorpus.bytes("mixed")
        let half = data.count / 2
        // 先跑一半再接入：接入时拿到的是快照。
        await emit(data.prefix(half), to: backend)
        let firstHalfFed = await waitUntil { session.shadow.totalFedBytes >= half }
        XCTAssertTrue(firstHalfFed, "前一半没喂完")

        let phone = phone(matching: session)
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        await emit(data.suffix(from: half), to: backend)
        let diff = await drainUntilConsistent(subscriber, session: session, phone: phone, fedBytes: data.count)
        XCTAssertEqual(diff, [:])
        session.mirrorTap.unsubscribe(id: subscriber.id)
    }

    /// 订阅者一直不取（对端太慢）：积压超限后丢弃并改发快照，最终仍一致。
    func test_overflow_drops_backlog_and_resyncs_with_snapshot() async throws {
        let (session, backend) = await connectedSession()
        defer { session.dispose() }
        let phone = phone(matching: session)
        let limit = 4 * 1024
        let subscriber = session.mirrorTap.subscribe(id: UUID(), limit: limit) {}
        // 接入时的那张（空屏）先取走，之后一直不取。
        let assembly = SnapshotAssembly()
        drain(subscriber, into: phone, assembly: assembly)
        XCTAssertEqual(subscriber.pendingBytes, 0)

        let data = try TerminalCorpus.bytes("shell") + TerminalCorpus.bytes("vim")
        XCTAssertGreaterThan(data.count, limit * 4, "用例前提：输出比上限多得多")
        await emit(data, to: backend, chunk: 2048)
        let fed = await waitUntil { session.shadow.totalFedBytes >= data.count }
        XCTAssertTrue(fed, "语料没喂完")
        // 积压被上限截住：攒着的是一张快照（它本身可以比上限大），加上它之后不超过上限的字节。
        let snapshotBytes = try session.shadow.snapshot().count
        XCTAssertLessThanOrEqual(subscriber.pendingBytes, snapshotBytes + limit + 64 * 1024)
        guard case .snapshot(let piece, let isFirst, let isLast)? = subscriber.take(maxBytes: .max) else {
            return XCTFail("超限之后下一段应当是一张新快照，而不是接着发原样字节")
        }
        XCTAssertTrue(isFirst)
        XCTAssertTrue(isLast)
        phone.pump.applySnapshot(piece)
        let diff = await drainUntilConsistent(subscriber, session: session, phone: phone)
        XCTAssertEqual(diff, [:])
    }

    /// 清屏走输出泵的分流（不是后端输出）：镜像端看到同样的字节，照样对齐。
    func test_clear_output_resyncs() async throws {
        let (session, backend) = await connectedSession()
        defer { session.dispose() }
        let phone = phone(matching: session)
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        let data = try TerminalCorpus.bytes("shell")
        await emit(data, to: backend)
        let before = await drainUntilConsistent(subscriber, session: session, phone: phone, fedBytes: data.count)
        XCTAssertEqual(before, [:])
        XCTAssertGreaterThan(session.shadow.totalRows, session.shadow.size.rows, "用例前提：清屏前有回滚")
        session.clearOutput()
        let diff = await drainUntilConsistent(subscriber, session: session, phone: phone)
        XCTAssertEqual(diff, [:])
        XCTAssertEqual(session.shadow.totalRows, session.shadow.size.rows, "清屏连回滚一起清")
        XCTAssertEqual(phone.shadow.totalRows, phone.shadow.size.rows)
    }

    func test_tap_without_subscribers_is_inert() async throws {
        let (session, backend) = await connectedSession()
        defer { session.dispose() }
        XCTAssertFalse(session.mirrorTap.hasSubscribers)
        let data = try TerminalCorpus.bytes("htop")
        await emit(data, to: backend)
        let fed = await waitUntil { session.shadow.totalFedBytes >= data.count }
        XCTAssertTrue(fed)
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        session.mirrorTap.unsubscribe(id: subscriber.id)
        XCTAssertFalse(session.mirrorTap.hasSubscribers)
        _ = subscriber.take(maxBytes: .max)
        await emit(Data("after\r\n".utf8), to: backend)
        let more = await waitUntil { session.shadow.totalFedBytes >= data.count + 7 }
        XCTAssertTrue(more)
        XCTAssertEqual(subscriber.pendingBytes, 0, "退订之后不再替它攒")
    }

    // MARK: 接管尺寸——会话没有画面（标签从没露出过，surface 没建）

    /// 接管尺寸：标签没露出过也要能接管。影子终端当场变成对端的行列数，PTY 跟着调整，镜像端收到新尺寸下的快照；
    /// 解除接管回到原来的尺寸。
    func test_pin_remote_grid_resizes_terminal_backend_and_mirror() async throws {
        let (session, backend) = await connectedSession()
        defer { session.dispose() }
        let original = session.shadow.size
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        let shell = try TerminalCorpus.bytes("shell")
        await emit(shell, to: backend)
        let fed = await waitUntil { session.shadow.totalFedBytes >= shell.count }
        XCTAssertTrue(fed)

        session.pinRemoteGrid(cols: 57, rows: 23, controller: "测试 iPhone")
        XCTAssertEqual(session.shadow.size.cols, 57)
        XCTAssertEqual(session.shadow.size.rows, 23)
        XCTAssertEqual(session.remoteController, "测试 iPhone")
        let told = await waitUntil {
            let last = await backend.resizes.last
            return last?.cols == 57 && last?.rows == 23
        }
        XCTAssertTrue(told, "PTY 应当收到 57×23")

        // 手机端从别的尺寸起步：快照把它带到 57×23。
        let phone = MirrorPhone(cols: 80, rows: 24)
        let vim = try TerminalCorpus.bytes("vim")
        await emit(vim, to: backend)
        let diff = await drainUntilConsistent(subscriber, session: session, phone: phone,
                                              fedBytes: shell.count + vim.count)
        XCTAssertEqual(diff, [:])
        XCTAssertEqual(phone.shadow.size.cols, 57)

        session.unpinRemoteGrid()
        XCTAssertNil(session.remoteController)
        XCTAssertNil(session.ghostty.view.pinnedFrameSize)
        XCTAssertEqual(session.shadow.size.cols, original.cols, "解除接管回到原来的列数")
        XCTAssertEqual(session.shadow.size.rows, original.rows)
        let restored = await waitUntil {
            let last = await backend.resizes.last
            return last.map { Int($0.cols) == original.cols && Int($0.rows) == original.rows } ?? false
        }
        XCTAssertTrue(restored, "PTY 应当收到原来的尺寸")
    }

    /// 手机连着变尺寸（Duo 展开 / 合上、转屏）：每一次 Mac 都要钉到恰好那个行列数。差一列 Claude Code 就按
    /// 另一个宽度画框，手机上的输入框整个错位（真机回归：手机 62 列，Mac 停在 61 列）。
    /// 这里是没有画面的会话；有画面时（视图钉成「行列数 × 格子像素」）由 `GhosttyMacHostTests` 在真的 surface 上核。
    func test_pin_remote_grid_lands_exactly_after_a_sequence_of_sizes() async throws {
        let (session, backend) = await connectedSession()
        defer { session.dispose() }
        var misses: [String] = []
        let sizes = [(89, 32), (120, 40), (62, 30), (89, 32), (61, 29), (62, 30), (150, 45), (40, 20), (89, 32),
                     (88, 32), (90, 33), (63, 30), (62, 30)]
        for (cols, rows) in sizes {
            session.pinRemoteGrid(cols: cols, rows: rows, controller: "测试 iPhone")
            let size = session.shadow.size
            if size.cols != cols || size.rows != rows { misses.append("\(cols)×\(rows) → \(size.cols)×\(size.rows)") }
        }
        XCTAssertEqual(misses, [])
        // 同一轮里连着钉的那几次合并成一次，PTY 最后停在最后那个尺寸。
        let told = await waitUntil {
            let last = await backend.resizes.last
            return last?.cols == 62 && last?.rows == 30
        }
        XCTAssertTrue(told)
    }

    /// 对端报来离谱的行列数：钳到上限，不让终端去分配几十亿个格子。
    func test_pin_remote_grid_clamps_absurd_sizes() async throws {
        let (session, _) = await connectedSession()
        defer { session.dispose() }
        session.pinRemoteGrid(cols: 65_535, rows: 65_535, controller: "测试 iPhone")
        XCTAssertEqual(session.shadow.size.cols, TerminalSession.maxRemoteGridCols)
        XCTAssertEqual(session.shadow.size.rows, TerminalSession.maxRemoteGridRows)
    }

    /// 原来这里核的是 `RemoteGridFit`（按实测列数逼近旧引擎视图宽度的二分）。Ghostty 没有内留白，视图钉成
    /// 「行列数 × 格子像素 ÷ 屏幕倍率」就正好是那个行列数，不需要逼近，算法已删；钉任意行列数都精确命中由
    /// `GhosttyMacHostTests` 在真的 surface 上核。
    func test_grid_fit_converges_even_when_the_cell_estimate_is_off() throws {
        throw XCTSkip("RemoteGridFit 随旧引擎一起删除：Ghostty 按格子像素直接算，见 GhosttyMacHostTests")
    }

    // MARK: 接管尺寸——钉住的终端摆在哪

    /// 钉住的终端比窗格矮：贴左上角；比窗格高、不知道光标在哪：贴底边（裁掉顶上的旧行）。
    func test_pinned_terminal_keeps_its_bottom_visible_when_taller_than_the_pane() {
        let insets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
        let pane = NSRect(x: 0, y: 0, width: 800, height: 500)

        let short = GhosttyContainerView.pinnedFrame(NSSize(width: 400, height: 300), in: pane, insets: insets)
        XCTAssertEqual(short, NSRect(x: 8, y: 200, width: 400, height: 300), "放得下：顶边贴着窗格顶")

        let tall = GhosttyContainerView.pinnedFrame(NSSize(width: 400, height: 700), in: pane, insets: insets)
        XCTAssertEqual(tall.minY, 6, "放不下：底边贴着窗格底（留出下边距）")
        XCTAssertEqual(tall.size, NSSize(width: 400, height: 700), "不缩放，行列数不变")
    }

    /// 比窗格高的钉住终端跟着光标走：光标在屏幕顶上（程序刚起来、刚清过屏）时贴顶，不裁；光标往下走，
    /// 从顶上按整行裁，裁到光标往下 3 行刚好在窗格里；光标到了最后几行就是贴底。
    func test_pinned_terminal_taller_than_the_pane_follows_the_cursor() {
        let insets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
        let pane = NSRect(x: 0, y: 0, width: 800, height: 500)
        let pinned = NSSize(width: 400, height: 700)   // 35 行，每行 20pt；窗格里放得下 494pt
        func frame(cursor: Int) -> NSRect {
            GhosttyContainerView.pinnedFrame(pinned, in: pane, insets: insets, cursorRow: cursor, rows: 35)
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

    // MARK: 接管尺寸——窗格里（真的 surface）

    /// 800×500 的窗口里挂着 `RemoteControlledTerminal`（窗格用的那个 SwiftUI 视图），等 Ghostty 的网格停稳。
    private func hostedSession(height: CGFloat = 500) async throws -> (session: TerminalSession, backend: MockBackend,
                                                 host: NSHostingView<RemoteControlledTerminal>, window: NSWindow) {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        let rect = NSRect(x: 0, y: 0, width: 800, height: height)
        let host = NSHostingView(rootView: RemoteControlledTerminal(session: session))
        host.frame = rect
        let window = ProbeWindow.make(contentRect: rect, contentView: host, placement: .transparentOnScreen)
        host.layoutSubtreeIfNeeded()
        let bridge = session.ghostty
        let live = await waitUntil(10) { bridge.isLive && bridge.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪")
        var last = bridge.grid.map { "\($0)" } ?? ""
        var stableSince = Date()
        while Date().timeIntervalSince(stableSince) < 0.4 {
            try? await Task.sleep(for: .milliseconds(20))
            let now = bridge.grid.map { "\($0)" } ?? ""
            if now != last { last = now; stableSince = Date() }
        }
        let backend = MockBackend()
        await session.connect(using: backend)
        return (session, backend, host, window)
    }

    /// 接管状态条占窗格自己的高度：终端容器让到它下面，两者不重叠；断开后容器铺回整个窗格。
    func test_remote_control_banner_sits_above_the_terminal_instead_of_covering_it() async throws {
        let rig = try await hostedSession()
        let session = rig.session
        defer { session.dispose(); rig.window.orderOut(nil) }

        func settledContainerHeight() async throws -> CGFloat {
            try? await Task.sleep(for: .milliseconds(100))
            rig.host.layoutSubtreeIfNeeded()
            return try XCTUnwrap(session.ghostty.view.superview).frame.height
        }

        let bare = try await settledContainerHeight()
        XCTAssertEqual(bare, 500, accuracy: 0.5, "没人接管时没有状态条")

        session.pinRemoteGrid(cols: 57, rows: 23, controller: "测试 iPhone")
        let taken = try await settledContainerHeight()
        XCTAssertEqual(taken, 472, accuracy: 0.5, "状态条高 28pt，终端容器让到它下面")
        let pinned = await waitUntil(3) { session.ghostty.grid?.rows == 23 && session.shadow.size.rows == 23 }
        XCTAssertTrue(pinned, "状态条不影响钉住的行列数：\(String(describing: session.ghostty.grid))")
        XCTAssertEqual(session.shadow.size.cols, 57)

        session.unpinRemoteGrid()
        let released = try await settledContainerHeight()
        XCTAssertEqual(released, 500, accuracy: 0.5, "断开后铺回整个窗格")
    }

    /// 真实链路：手机的行数比 Mac 窗格多。屏幕没写满（内容在顶上、下面是空行）时窗格里看到的是顶上那几行，
    /// 不是一屏空白；输出把光标推到屏幕底之后，窗格跟到底。
    /// 起因：user 用 iPhone Duo 接管本机终端里刚起来的 Claude Code，窗格里只剩输入框的下边线和一屏空白。
    func test_pinned_terminal_shows_the_cursor_rows_as_output_moves_it() async throws {
        let rig = try await hostedSession()
        let session = rig.session
        defer { session.dispose(); rig.window.orderOut(nil) }
        let view = session.ghostty.view
        func settle() async throws -> (view: NSRect, container: NSRect) {
            try? await Task.sleep(for: .milliseconds(150))
            rig.host.layoutSubtreeIfNeeded()
            let container = try XCTUnwrap(view.superview)
            container.layoutSubtreeIfNeeded()
            return (view.frame, container.bounds)
        }
        _ = try await settle()
        await emit(Data("\u{1B}[2J\u{1B}[Hwelcome\r\n> ".utf8), to: rig.backend)
        session.pinRemoteGrid(cols: 57, rows: 60, controller: "测试 iPhone")
        let pinned = await waitUntil(3) { session.ghostty.grid?.rows == 60 }
        XCTAssertTrue(pinned, "钉 57×60，Ghostty 的网格是 \(String(describing: session.ghostty.grid))")
        let top = try await settle()
        XCTAssertGreaterThan(top.view.height, top.container.height, "用例前提：钉住的终端比窗格高")
        XCTAssertEqual(top.view.maxY, top.container.height, accuracy: 0.5, "光标在屏幕顶上：终端的顶边贴着窗格顶，内容不被裁掉")

        // 80 行输出把光标推到最后一行。
        await emit(Data((1...80).map { "line \($0)\r\n" }.joined().utf8), to: rig.backend)
        let atBottom = await waitUntil(3) { session.shadow.cursor.y == 59 }
        XCTAssertTrue(atBottom, "80 行输出后光标应当在最后一行")
        let bottom = try await settle()
        XCTAssertEqual(bottom.view.minY, 6, accuracy: 0.5, "光标到了屏幕底：终端的底边贴着窗格底")

        // 清屏回到顶上：窗格跟回去。
        await emit(Data("\u{1B}[2J\u{1B}[H> ".utf8), to: rig.backend)
        let atTop = await waitUntil(3) { session.shadow.cursor.y == 0 }
        XCTAssertTrue(atTop)
        let again = try await settle()
        XCTAssertEqual(again.view.maxY, again.container.height, accuracy: 0.5, "清屏后光标回到顶上：窗格跟回顶上")
    }

    /// 真实链路：接管前窗格里已有历史，手机比窗格高，状态条随后出现；shell 里 `seq 1 300` 之后，第 300 行和提示符所在的行
    /// 都要落在窗格里（回归：最底下几行被裁到窗格底边外，滚动条已在底也看不到）。窗格高度取几种，让按行填满拉高过行距。
    func test_pinned_terminal_keeps_the_last_lines_visible_after_seq() async throws {
        for height in [500, 523, 537, 561, 609] as [CGFloat] {
            let rig = try await hostedSession(height: height)
            let session = rig.session
            defer { session.dispose(); rig.window.orderOut(nil) }
            let view = session.ghostty.view
            await emit(Data(((1...120).map { "old \($0)\r\n" }.joined() + "$ ").utf8), to: rig.backend)
            let phoneRows = 60
            session.pinRemoteGrid(cols: 57, rows: phoneRows, controller: "测试 iPhone")
            _ = await waitUntil(3) { session.ghostty.grid?.rows == phoneRows && session.shadow.size.rows == phoneRows }
            try? await Task.sleep(for: .milliseconds(150))
            await emit(Data("seq 1 300\r\n".utf8), to: rig.backend)
            for chunk in stride(from: 1, through: 300, by: 7) {
                await emit(Data((chunk...min(300, chunk + 6)).map { "\($0)\r\n" }.joined().utf8), to: rig.backend)
                try? await Task.sleep(for: .milliseconds(10))
            }
            await emit(Data("$ ".utf8), to: rig.backend)
            _ = await waitUntil(3) { session.shadow.cursor.y == phoneRows - 1 }
            try? await Task.sleep(for: .milliseconds(250))
            rig.host.layoutSubtreeIfNeeded()
            let container = try XCTUnwrap(view.superview)
            container.layoutSubtreeIfNeeded()
            let rowHeight = view.frame.height / CGFloat(phoneRows)
            func visible(_ row: Int) -> Bool {
                let top = view.frame.maxY - CGFloat(row) * rowHeight
                return top - rowHeight >= -0.5 && top <= container.bounds.height + 0.5
            }
            let tag = "窗格 \(height)pt（行高调整 \(view.uTermCellHeightAdjustment)），视图 \(view.frame)，容器 \(container.bounds)，网格 \(String(describing: session.ghostty.grid))"
            let lines = (session.ghostty.viewportText() ?? "").components(separatedBy: "\n")
            let cursorRow = try XCTUnwrap(lines.lastIndex { $0.hasPrefix("$ ") }, "画面上没有提示符：\(tag)")
            let row300 = try XCTUnwrap(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "300" }, "画面上没有 300：\(tag)")
            XCTAssertTrue(visible(cursorRow), "光标行 \(cursorRow) 被裁掉：\(tag)")
            XCTAssertTrue(visible(row300), "第 300 行（第 \(row300) 行）被裁掉：\(tag)")
        }
    }

    /// 有画面的会话被接管：镜像端最后拿到的是新尺寸下的快照，之后的输出两边一致。
    func test_pin_with_a_live_surface_resends_the_snapshot_at_the_phone_size() async throws {
        let rig = try await hostedSession()
        let session = rig.session
        defer { session.dispose(); rig.window.orderOut(nil) }
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        let shell = try TerminalCorpus.bytes("shell")
        await emit(shell, to: rig.backend)
        let fed = await waitUntil { session.shadow.totalFedBytes >= shell.count }
        XCTAssertTrue(fed)

        session.pinRemoteGrid(cols: 57, rows: 23, controller: "测试 iPhone")
        rig.host.layoutSubtreeIfNeeded()
        let pinned = await waitUntil(3) {
            session.ghostty.grid?.cols == 57 && session.ghostty.grid?.rows == 23 && session.shadow.size.cols == 57
        }
        XCTAssertTrue(pinned, "钉 57×23，Ghostty 的网格是 \(String(describing: session.ghostty.grid))")
        let told = await waitUntil(2) {
            let last = await rig.backend.resizes.last
            return last?.cols == 57 && last?.rows == 23
        }
        XCTAssertTrue(told, "PTY 应当收到 57×23")

        let phone = MirrorPhone(cols: 80, rows: 24)
        let vim = try TerminalCorpus.bytes("vim")
        await emit(vim, to: rig.backend)
        let diff = await drainUntilConsistent(subscriber, session: session, phone: phone,
                                              fedBytes: shell.count + vim.count)
        XCTAssertEqual(diff, [:])
        XCTAssertEqual(phone.shadow.size.cols, 57)
        XCTAssertEqual(phone.shadow.size.rows, 23)
    }
}
