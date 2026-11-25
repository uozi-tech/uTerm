import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 对话正文（Code 标签页 / 历史窗口右边）滚动的手感探针：真窗口、真滚轮事件（带 phase），按 16ms 一个事件的节奏回放，
/// 每个事件之后看「画面实际走了多少」和「手指给了多少」差多少。
///
/// 画面走了多少靠截图比对（`rowSignature` + `visualShift`）：相邻两次截图找一个纵向位移让两张对得最齐，这才是用户看到的。
/// 只看 clip view 的偏移量不到抖：懒栈改估高时坐标照手指走，内容却在文档里挪了位置。
/// 记录是手写的假数据（长 Markdown、代码块、工具调用卡片、短行混排，行高差别很大），不读用户真实记录。
///
/// 2026-11-25 用户录屏（往回翻一长段对话时画面在几处之间来回跳、滚动条滑块跟着跳）在这里的复现：往回翻 12 拨，
/// 文档高度在滚动中变了几次、每次几百点，画面跟着往前跳 200 多点或往回退 100 多点。原因与改法见
/// `AgentTranscriptMarkdown`（`AgentHistoryBrowser.swift`）。
@MainActor
final class ClaudeTranscriptScrollProbeTests: XCTestCase {
    private let root = "/home/user/.claude/projects"
    private let project = "-home-user-projects-demo"
    private var path: String { "\(root)/\(project)/\(ClaudeFixture.sessionID).jsonl" }

    // MARK: 假对话

    /// 一轮：问一句 → 一段长回答（标题、列表、围栏代码块）→ 一次工具调用和结果 → 一句短的。轮与轮之间长度错开。
    private func transcriptLines(turns: Int, salt: String, outputBytes: Int = 0) -> [String] {
        var lines: [String] = []
        for turn in 0 ..< turns {
            lines.append(ClaudeFixture.userText("第 \(turn) 个问题：部署脚本在第 \(turn % 7 + 1) 步报错，日志里说权限不够，该怎么查？",
                                                uuid: "u-\(turn)"))
            var answer = "## \(salt)第 \(turn) 轮排查\n\n先确认是哪一步失败的。"
            for paragraph in 0 ..< (turn % 4 + 1) {
                answer += "\n\n第 \(paragraph + 1) 段：" + String(repeating: "检查服务账号的权限、目录的属主和挂载选项，再看审计日志。", count: turn % 3 + 2)
            }
            answer += "\n\n- 看 `journalctl -u deploy`\n- 看 `/var/log/audit/audit.log`\n- 对一下 `id deploy`"
            if turn % 2 == 0 {
                answer += "\n\n```bash\n" + (0 ..< (turn % 5 + 3)).map { "sudo -u deploy ls -la /srv/app/releases/\($0)" }
                    .joined(separator: "\n") + "\n```"
            }
            answer += "\n\n> 改完之后重跑一次，看看还报不报。"
            lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock(answer) + ","
                + ClaudeFixture.toolUse(id: "t-\(turn)", name: "Bash", input: #"{"command":"ls -la /srv/app"}"#),
                uuid: "a-\(turn)"))
            var output = (0 ..< (turn % 6 + 2)).map { "drwxr-xr-x  5 deploy deploy 160 Nov 20 10:0\($0) release-\($0)" }
                .joined(separator: "\n")
            // 工具输出撑大文件（界面里折叠着，不改行高），让记录分成几页读。
            if outputBytes > 0 { output += "\n" + String(repeating: "-rw-r--r-- 1 deploy deploy 0 app.log\n", count: outputBytes / 38) }
            lines.append(ClaudeFixture.toolResult(id: "t-\(turn)", text: output))
            lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("好的。"), uuid: "b-\(turn)"))
        }
        return lines
    }

    private func makeTranscript(turns: Int, salt: String = UUID().uuidString.prefix(8) + " ",
                                loadsAll: Bool = true, outputBytes: Int = 0) async throws -> AgentTranscriptModel {
        let sftp = MockSFTP()
        await sftp.setFile(path, data: ClaudeFixture.file(transcriptLines(turns: turns, salt: salt, outputBytes: outputBytes)), mtime: Date())
        let file = AgentHistorySessionFile(sessionID: ClaudeFixture.sessionID,
                                           project: AgentHistoryProject(id: project, path: "\(root)/\(project)", modifiedAt: nil),
                                           path: path, size: 0, modifiedAt: Date())
        let transcript = AgentTranscriptModel(file: file, pager: ClaudeTranscriptPager(provider: sftp, path: path))
        if loadsAll {
            while !transcript.reachedStart { await transcript.loadEarlier() }
        } else {
            await transcript.loadEarlier()
        }
        return transcript
    }


    private func mount(_ transcript: AgentTranscriptModel) async throws -> (NSWindow, NSScrollView) {
        let rect = NSRect(x: 0, y: 0, width: 760, height: 620)
        let host = NSHostingView(rootView: AgentTranscriptPane(transcript: transcript, metadata: nil, canResume: false,
                                                               onResume: {}))
        host.frame = rect
        let window = ProbeWindow.make(contentRect: rect, contentView: host, placement: .transparentOnScreen)
        try? await Task.sleep(for: .milliseconds(800))
        let scroll = try XCTUnwrap(host.firstScrollView())
        return (window, scroll)
    }

    private func topOffset(_ scroll: NSScrollView) -> CGFloat {
        let visible = scroll.documentVisibleRect
        let height = scroll.documentView?.bounds.height ?? 0
        return (scroll.documentView?.isFlipped ?? true) ? visible.minY : height - visible.maxY
    }

    // MARK: 画面

    /// 截滚动视图左边一条，每一行（点）压成两个数：墨量与按横坐标加权的墨量。正文是左对齐的，这一条里几乎每行都有字。
    private func rowSignature(_ scroll: NSScrollView) -> [(ink: Double, weighted: Double)] {
        let rect = NSRect(x: 18, y: 0, width: 320, height: scroll.bounds.height)
        guard let rep = scroll.bitmapImageRepForCachingDisplay(in: rect) else { return [] }
        scroll.cacheDisplay(in: rect, to: rep)
        let scale = Double(rep.pixelsHigh) / Double(rect.height)
        return (0 ..< Int(rect.height)).map { row in
            let y = Int(Double(row) * scale)
            var ink = 0.0, weighted = 0.0
            for x in stride(from: 0, to: rep.pixelsWide, by: 6) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let v = 1 - (c.redComponent + c.greenComponent + c.blueComponent) / 3
                ink += v
                weighted += v * Double(x % 97) / 40
            }
            return (ink, weighted)
        }
    }

    /// 画面从 `a` 到 `b` 往下走了多少点（正 = 内容往下 = 在看更早的）。只比有墨的行（空白行跟什么都对得上）。
    /// 最好的对齐也差得多（整屏换了内容）返回 nil。
    private func visualShift(_ a: [(ink: Double, weighted: Double)], _ b: [(ink: Double, weighted: Double)]) -> CGFloat? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let n = a.count
        var best: (shift: Int, error: Double)?
        for s in -(n * 2 / 3) ... (n * 2 / 3) {
            let lo = max(0, s), hi = min(n, n + s)
            guard hi - lo > n / 3 else { continue }
            var total = 0.0, count = 0
            for y in lo ..< hi where a[y - s].ink > 0.5 {
                total += abs(a[y - s].ink - b[y].ink) + abs(a[y - s].weighted - b[y].weighted)
                count += 1
            }
            guard count > 10 else { continue }
            let error = total / Double(count)
            if best == nil || error < best!.error || (error == best!.error && abs(s) < abs(best!.shift)) { best = (s, error) }
        }
        guard let best, best.error < 2 else { return nil }
        return CGFloat(best.shift)
    }

    // MARK: 事件

    /// 触控板的一次拨动：began → 一串 changed → ended。`delta` 为正 = 往回看（内容往下走）。
    /// 不发惯性事件：合成的惯性事件 SwiftUI 的滚动视图不认（实测一点不动），拖动段已经够把懒栈翻过一长段。
    private func stroke(direction: Int, peak: Int = 60, events: Int = 8) -> [(delta: Int, phase: Int64)] {
        let ramp = [peak / 4, peak / 2] + Array(repeating: peak, count: max(0, events - 2))
        return [(0, 1)] + ramp.map { ($0 * direction, 2) } + [(0, 4)]
    }

    private func wheel(_ delta: Int, phase: Int64) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return NSEvent(cgEvent: cg)!
    }

    // MARK: 读数

    private struct Reading: CustomStringConvertible {
        var samples = 0
        var fingers: CGFloat = 0
        var travelled: CGFloat = 0
        /// 画面往手指相反的方向走了（看得见的倒退，> 2pt）。
        var reversals = 0
        /// 画面比手指多走或少走 24pt 以上（跳）的次数、累计、单次最大。
        var jumps = 0
        var jumpTotal: CGFloat = 0
        var jumpMax: CGFloat = 0
        /// 整屏换了内容，截图一点也对不上。
        var unmatched = 0
        /// 滚动中文档高度变了几次（懒栈改估高）、累计多少。
        var heightChanges = 0
        var heightDelta: CGFloat = 0
        /// 每个事件之后交付一次布局与绘制的主线程耗时。
        var frameMs: [Double] = []
        var log: [String] = []

        var p50: Double { ProbeMetrics.percentile(frameMs, 0.5) }
        var p95: Double { ProbeMetrics.percentile(frameMs, 0.95) }
        var overBudget: Double { frameMs.isEmpty ? 0 : Double(frameMs.filter { $0 > 8.33 }.count) / Double(frameMs.count) * 100 }

        var description: String {
            String(format: "采样 %d · 手指 %.0fpt 画面 %.0fpt · 倒退 %d · 跳 %d 次 共 %.0fpt 最大 %.0fpt · 整屏换 %d · 文档高变 %d 次 共 %.0fpt · 帧 p50 %.2fms p95 %.2fms 超 8.33ms %.1f%%",
                   samples, fingers, travelled, reversals, jumps, jumpTotal, jumpMax, unmatched, heightChanges, heightDelta,
                   p50, p95, overBudget)
        }
    }

    private func replay(_ strokes: [[(delta: Int, phase: Int64)]], on scroll: NSScrollView, window: NSWindow) async -> Reading {
        var reading = Reading()
        var previousRows = rowSignature(scroll)
        var previousTop = topOffset(scroll)
        var previousHeight = scroll.documentView?.bounds.height ?? 0
        for (delta, phase) in strokes.joined() {
            let start = CACurrentMediaTime()
            scroll.scrollWheel(with: wheel(delta, phase: phase))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            reading.frameMs.append((CACurrentMediaTime() - start) * 1000)
            // 真用户 16ms 一个事件；这段时间里 onAppear 之类的下一拍工作跑完。
            try? await Task.sleep(for: .milliseconds(16))
            window.contentView?.layoutSubtreeIfNeeded()
            // 再等坐标真的挪到这个事件要去的地方（最多 250ms）才截：SwiftUI 的滚动视图按显示节拍把滚轮的位移交给 clip view，
            // 机器一忙，这个事件的位移常常要到下一拍才落下，16ms 后截到的是「这一拍没动、下一拍动了两个事件」——
            // 画面与坐标一起走、内容在文档里没挪，不是这里要抓的跳（2026-11-25 负载 35 时每轮假红 1～4 次）。
            // 文档改高时 SwiftUI 会把坐标补一大截、坐标永远到不了这里，等满 250ms 照常截，画面判据照旧。
            let wanted = previousTop - CGFloat(delta)
            let deadline = CACurrentMediaTime() + 0.25
            while delta != 0, abs(topOffset(scroll) - wanted) > 0.5, CACurrentMediaTime() < deadline {
                let edge = topOffset(scroll) < 1
                    || (scroll.documentView?.bounds.height ?? 0) - topOffset(scroll) - scroll.documentVisibleRect.height < 1
                if edge { break }
                try? await Task.sleep(for: .milliseconds(4))
                window.contentView?.layoutSubtreeIfNeeded()
            }
            let rows = rowSignature(scroll)
            let top = topOffset(scroll)
            let height = scroll.documentView?.bounds.height ?? 0
            reading.samples += 1
            reading.fingers += abs(CGFloat(delta))
            if abs(height - previousHeight) > 0.5 {
                reading.heightChanges += 1
                reading.heightDelta += abs(height - previousHeight)
            }
            let atEdge = top < 1 || height - top - scroll.documentVisibleRect.height < 1
            if let shift = visualShift(previousRows, rows) {
                reading.travelled += abs(shift)
                let finger = CGFloat(delta)
                if !atEdge, finger != 0, shift * finger < -2 {
                    reading.reversals += 1
                    reading.log.append(String(format: "倒退：手指 %.0f 画面 %.0f 坐标 %.0f 文档高 %.0f→%.0f", finger, shift,
                                              previousTop - top, previousHeight, height))
                }
                // 跳 = 画面和手指差了 24pt 以上。坐标不作数：文档改高时 SwiftUI 会把坐标补一大截、画面照旧跟手（不是跳）；
                // 画面和坐标一起没动只是这个事件没被吃进去（停一下），也不算跳。
                let coordinate = previousTop - top
                let off = shift == 0 && coordinate == 0 ? 0 : abs(shift - finger)
                if !atEdge, off > 24 {
                    reading.jumps += 1; reading.jumpTotal += off; reading.jumpMax = max(reading.jumpMax, off)
                    reading.log.append(String(format: "跳：手指 %.0f 画面 %.0f 坐标 %.0f 文档高 %.0f→%.0f", finger, shift,
                                              previousTop - top, previousHeight, height))
                }
            } else {
                reading.unmatched += 1
                reading.log.append(String(format: "整屏换：手指 %d 坐标 %.0f 文档高 %.0f→%.0f", delta, previousTop - top,
                                          previousHeight, height))
            }
            previousRows = rows; previousTop = top; previousHeight = height
        }
        return reading
    }

    private func report(_ name: String, _ reading: Reading) {
        print("[transcript-scroll] \(name) \(reading)")
        for line in reading.log.prefix(24) { print("[transcript-scroll]   \(line)") }
    }

    /// 真实 AX 树里按标题找按钮（懒栈的行挂在 `AccessibilityLazyLayoutNode` 下，要走 `AnyObject` 动态派发）。
    private func axButton(titled title: String, in root: NSView) -> AnyObject? {
        var out: AnyObject?
        var visited = 0
        func find(_ node: Any) {
            guard out == nil, visited < 20_000 else { return }
            visited += 1
            let element = node as AnyObject
            let texts = [element.accessibilityLabel?(), element.accessibilityTitle?()].compactMap { $0 }
            if texts.contains(where: { $0.contains(title) }) { out = element; return }
            for child in (element.accessibilityChildren?() ?? []) { find(child) }
            if out == nil, let view = node as? NSView { view.subviews.forEach(find) }
        }
        find(root)
        return out
    }

    // MARK: 用例

    /// 打开一份对话（挂上去到第一屏画完）要多久：每段 Markdown 改成在 body 里同步解析之后，这一下多付了解析的钱。
    /// 每次用新文字（`salt`），量的是没进缓存的第一次。
    func testMountCost() async throws {
        for turns in [30, 100] {
            let transcript = try await makeTranscript(turns: turns)
            let rect = NSRect(x: 0, y: 0, width: 760, height: 620)
            let window = ProbeWindow.make(contentRect: rect, placement: .transparentOnScreen)
            defer { window.orderOut(nil) }
            let cpu = ProbeMetrics.threadCPUSeconds()
            let start = CACurrentMediaTime()
            let host = NSHostingView(rootView: AgentTranscriptPane(transcript: transcript, metadata: nil, canResume: false,
                                                                   onResume: {}))
            host.frame = rect
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let mount = (CACurrentMediaTime() - start) * 1000
            try? await Task.sleep(for: .milliseconds(600))
            let settledCPU = (ProbeMetrics.threadCPUSeconds() - cpu) * 1000
            let scroll = try XCTUnwrap(host.firstScrollView())
            print(String(format: "[transcript-scroll] 挂载 %d 条：首屏 %.1fms，到停稳主线程 CPU %.1fms，文档高 %.0f",
                         transcript.items.count, mount, settledCPU, scroll.documentView?.bounds.height ?? 0))
            XCTAssertLessThan(mount, 1500, "打开一份 \(transcript.items.count) 条的对话太慢")
        }
    }

    /// 打开时停在最后一条，往回翻一长段、再往下翻回来：画面要跟着手指走，不跳、不倒退、不整屏换。
    func testScrollFollowsFingersWithoutJumps() async throws {
        let transcript = try await makeTranscript(turns: 30)
        let (window, scroll) = try await mount(transcript)
        defer { window.orderOut(nil) }
        XCTAssertTrue(ProbeWindow.blindsRealMouse(window))
        print("[transcript-scroll] items \(transcript.items.count) document \(Int(scroll.documentView?.bounds.height ?? 0))")

        let up = await replay((0 ..< 12).map { _ in stroke(direction: 1) }, on: scroll, window: window)
        report("往回翻", up)
        let down = await replay((0 ..< 12).map { _ in stroke(direction: -1) }, on: scroll, window: window)
        report("往下翻", down)

        for (name, reading) in [("往回翻", up), ("往下翻", down)] {
            XCTAssertGreaterThan(reading.travelled, reading.fingers * 0.5, "\(name)：画面没怎么动，量的不是滚动")
            XCTAssertEqual(reading.reversals, 0, "\(name)：画面往手指相反的方向退了")
            XCTAssertEqual(reading.jumps, 0, "\(name)：画面比手指多走 / 少走了 24pt 以上")
            XCTAssertEqual(reading.unmatched, 0, "\(name)：画面整屏换了内容")
        }
    }

    /// 只读了最后一页、翻到顶上再往前加一页（同「加载更早的消息」，这里直接调模型）：已经在看的内容不动，接着往回翻也不跳。
    func testLoadingEarlierPageKeepsPositionAndStaysSmooth() async throws {
        let transcript = try await makeTranscript(turns: 60, loadsAll: false, outputBytes: 12_000)
        XCTAssertFalse(transcript.reachedStart, "要有更早的页可加")
        let (window, scroll) = try await mount(transcript)
        defer { window.orderOut(nil) }

        let toTop = await replay((0 ..< 40).map { _ in stroke(direction: 1, peak: 240, events: 10) }, on: scroll, window: window)
        report("翻到顶", toTop)
        XCTAssertLessThan(topOffset(scroll), 1, "没翻到顶")
        XCTAssertEqual(toTop.jumps, 0, "翻到顶的路上画面跳了")
        XCTAssertEqual(toTop.unmatched, 0, "翻到顶的路上画面整屏换了")

        // 顶上的回弹落定了再截。
        try? await Task.sleep(for: .milliseconds(800))
        let before = rowSignature(scroll)
        let count = transcript.items.count
        // 走真按钮（`loadEarlier` 那条路记下原来最上面那条、加完滚回它）。AX 树一打开就关不掉，所以放在量完滚动之后。
        AccessibilityTreeForTests.enable(for: self)
        try? await Task.sleep(for: .milliseconds(300))
        let button = try XCTUnwrap(axButton(titled: "加载更早的消息", in: try XCTUnwrap(window.contentView)),
                                   "找不到「加载更早的消息」")
        XCTAssertTrue(button.accessibilityPerformPress?() ?? false)
        try? await Task.sleep(for: .milliseconds(800))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(transcript.items.count, count, "没加上更早的一页")
        let shift = visualShift(before, rowSignature(scroll))
        print("[transcript-scroll] 加一页 \(count)→\(transcript.items.count) 条，画面走了 \(shift.map { "\($0)" } ?? "整屏换")，top \(Int(topOffset(scroll)))")
        // 按钮那条路是 `scrollTo(原来最上面那条, anchor: .top)`：它顶到视口顶边，原来压在它上面的按钮那一截（约 80pt）让出去，
        // 画面整体上移这一截，是设计如此；要防的是整屏换到别处（改前懒栈新加的行先按空文档量高，加完再长）。
        let moved = try XCTUnwrap(shift, "往前加了一页，画面整屏换到了别处")
        XCTAssertLessThanOrEqual(abs(moved), 100, "往前加了一页，正在看的内容挪远了")

        let more = await replay((0 ..< 8).map { _ in stroke(direction: 1) }, on: scroll, window: window)
        report("加页后接着往回翻", more)
        XCTAssertEqual(more.reversals, 0)
        XCTAssertEqual(more.jumps, 0)
        XCTAssertEqual(more.unmatched, 0)
    }
}
