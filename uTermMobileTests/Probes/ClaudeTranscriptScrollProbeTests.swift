import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 历史会话标签里对话正文的滚动手感（同 Mac 的 `ClaudeTranscriptScrollProbeTests`）：真窗口、按 16ms 一步改 `contentOffset`
/// 往回翻，每一步截图比对「画面实际走了多少」和「这一步挪了多少」，同时看内容总高度在滚动中变不变。
///
/// 原因同 Mac：行里的 Markdown 改前在 `onAppear` 才解析，懒栈给还没出现过的行按空文档量高，往回翻时行一出现才长到真实高度，
/// 视口里的内容跟着跳。改法见 `MTranscriptMarkdown`（`ClaudeHistoryTab.swift`）。
/// 记录是手写的假数据（长 Markdown、代码块、工具调用、短行混排），不读用户真实记录。模拟器 60Hz，这里不断言帧率。
@MainActor
final class ClaudeTranscriptScrollProbeTests: XCTestCase {
    private typealias F = MobileClaudeFixture

    // MARK: 假对话

    private func transcript(turns: Int) -> Data {
        var lines: [String] = []
        for turn in 0 ..< turns {
            lines.append(F.user("第 \(turn) 个问题：部署脚本在第 \(turn % 7 + 1) 步报错，日志里说权限不够，该怎么查？", uuid: "u-\(turn)"))
            var answer = "## 第 \(turn) 轮排查\n\n先确认是哪一步失败的。"
            for paragraph in 0 ..< (turn % 4 + 1) {
                answer += "\n\n第 \(paragraph + 1) 段：" + String(repeating: "检查服务账号的权限、目录的属主和挂载选项，再看审计日志。",
                                                                  count: turn % 3 + 2)
            }
            answer += "\n\n- 看 `journalctl -u deploy`\n- 看 `/var/log/audit/audit.log`\n- 对一下 `id deploy`"
            if turn % 2 == 0 {
                answer += "\n\n```bash\n" + (0 ..< (turn % 5 + 3)).map { "sudo -u deploy ls -la /srv/app/releases/\($0)" }
                    .joined(separator: "\n") + "\n```"
            }
            answer += "\n\n> 改完之后重跑一次，看看还报不报。"
            lines.append(F.assistant(F.text(answer) + "," + F.toolUse(id: "t-\(turn)", name: "Bash",
                                                                      input: #"{"command":"ls -la /srv/app"}"#),
                                     uuid: "a-\(turn)"))
            lines.append(F.toolResult(id: "t-\(turn)", text: (0 ..< (turn % 6 + 2))
                .map { "drwxr-xr-x  5 deploy deploy 160 Nov 20 10:0\($0) release-\($0)" }.joined(separator: "\n")))
            lines.append(F.assistant(F.text("好的。"), uuid: "b-\(turn)"))
        }
        lines.append(F.title("一段很长的排查"))
        return F.file(lines)
    }

    /// 挂上历史会话的浏览器（窄屏：选中后整屏是对话），读完整份记录，返回对话的滚动视图。
    private func mount(turns: Int) async throws -> (UIWindow, UIScrollView, AgentTranscriptModel) {
        let tree = MobileFakeClaudeTree(home: F.home, files: [
            (F.projectPath + "/" + F.sessionID(21) + ".jsonl", transcript(turns: turns), Date().addingTimeInterval(-60)),
        ])
        let tab = MobileFakeClaudeHistory.tab(host: ServerProfile(), tree: tree)
        await tab.connection.open()
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled, "列表没读完")
        let model = try XCTUnwrap(tab.connection.history)
        model.select(try XCTUnwrap(model.visibleFiles.first))
        let transcript = try XCTUnwrap(model.transcript)
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { !transcript.items.isEmpty }
        while !transcript.reachedStart { await transcript.loadEarlier() }

        let cpu = ProbeMetrics.threadCPUSeconds()
        let start = CACurrentMediaTime()
        let (window, host) = MobileProbeWindow.make(size: CGSize(width: 390, height: 760), rootView:
            ClaudeHistoryBrowser(history: model, canResume: false, isActive: false, onResume: { _ in }))
        host.view.layoutIfNeeded()
        let firstLayout = (CACurrentMediaTime() - start) * 1000
        try? await Task.sleep(for: .milliseconds(1200))
        host.view.layoutIfNeeded()
        print(String(format: "[transcript-scroll-ios] 挂载 %d 条：首次布局 %.1fms，到停稳主线程 CPU %.1fms", transcript.items.count,
                     firstLayout, (ProbeMetrics.threadCPUSeconds() - cpu) * 1000))
        // 对话那一个：在窗口里看得见、内容最高。列表那一个被挪到了十万点外。
        var candidates: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height,
               window.bounds.intersects(scroll.convert(scroll.bounds, to: window)) {
                candidates.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(host.view)
        let scroll = try XCTUnwrap(candidates.max { $0.contentSize.height < $1.contentSize.height }, "找不到对话的滚动视图")
        return (window, scroll, transcript)
    }

    // MARK: 画面

    /// 截滚动视图左边一条，每一行（点）压成两个数：墨量与按横坐标加权的墨量。
    private func rowSignature(_ scroll: UIScrollView) -> [(ink: Double, weighted: Double)] {
        let width = 300, height = Int(scroll.bounds.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.cgContext.translateBy(x: -16, y: -scroll.bounds.minY)
            scroll.layer.render(in: context.cgContext)
        }
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let perRow = cg.bytesPerRow, perPixel = cg.bitsPerPixel / 8
        return (0 ..< min(height, cg.height)).map { y in
            var ink = 0.0, weighted = 0.0
            for x in stride(from: 0, to: min(width, cg.width), by: 4) {
                let p = bytes + y * perRow + x * perPixel
                let v = 1 - (Double(p[0]) + Double(p[1]) + Double(p[2])) / 765
                ink += v
                weighted += v * Double(x % 97) / 40
            }
            return (ink, weighted)
        }
    }

    /// 画面从 `a` 到 `b` 往下走了多少点（正 = 内容往下 = 在看更早的）；整屏换了内容对不上返回 nil。
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

    // MARK: 读数

    private struct Reading: CustomStringConvertible {
        var steps = 0
        var moved: CGFloat = 0
        var travelled: CGFloat = 0
        var reversals = 0
        var jumps = 0
        var jumpTotal: CGFloat = 0
        var jumpMax: CGFloat = 0
        var unmatched = 0
        var heightChanges = 0
        var heightDelta: CGFloat = 0
        var log: [String] = []

        var description: String {
            String(format: "步数 %d · 挪了 %.0fpt 画面 %.0fpt · 倒退 %d · 跳 %d 次 共 %.0fpt 最大 %.0fpt · 整屏换 %d · 内容高变 %d 次 共 %.0fpt",
                   steps, moved, travelled, reversals, jumps, jumpTotal, jumpMax, unmatched, heightChanges, heightDelta)
        }
    }

    /// 每 16ms 把 `contentOffset` 往回（`step` 为正）或往下挪一步，挪之后截图比对。
    private func replay(steps: Int, step: CGFloat, scroll: UIScrollView, window: UIWindow) async -> Reading {
        var reading = Reading()
        var previousRows = rowSignature(scroll)
        var previousHeight = scroll.contentSize.height
        for _ in 0 ..< steps {
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let from = scroll.contentOffset.y
            let target = min(max(-scroll.adjustedContentInset.top, from - step), maxY)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
            let asked = from - target
            try? await Task.sleep(for: .milliseconds(16))
            window.layoutIfNeeded()
            let rows = rowSignature(scroll)
            let height = scroll.contentSize.height
            reading.steps += 1
            reading.moved += abs(asked)
            if abs(height - previousHeight) > 0.5 {
                reading.heightChanges += 1
                reading.heightDelta += abs(height - previousHeight)
            }
            let atEdge = scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1 || target >= maxY - 1
            if let shift = visualShift(previousRows, rows) {
                reading.travelled += abs(shift)
                if !atEdge, asked != 0, shift * asked < -2 {
                    reading.reversals += 1
                    reading.log.append(String(format: "倒退：挪 %.0f 画面 %.0f 内容高 %.0f→%.0f", asked, shift, previousHeight, height))
                }
                let off = abs(shift - asked)
                if !atEdge, off > 24 {
                    reading.jumps += 1; reading.jumpTotal += off; reading.jumpMax = max(reading.jumpMax, off)
                    reading.log.append(String(format: "跳：挪 %.0f 画面 %.0f 偏移 %.0f→%.0f 内容高 %.0f→%.0f", asked, shift, from,
                                              scroll.contentOffset.y, previousHeight, height))
                }
            } else if !atEdge {
                reading.unmatched += 1
                reading.log.append(String(format: "整屏换：挪 %.0f 偏移 %.0f→%.0f 内容高 %.0f→%.0f", asked, from,
                                          scroll.contentOffset.y, previousHeight, height))
            }
            previousRows = rows
            previousHeight = height
        }
        return reading
    }

    private func report(_ name: String, _ reading: Reading) {
        print("[transcript-scroll-ios] \(name) \(reading)")
        for line in reading.log.prefix(24) { print("[transcript-scroll-ios]   \(line)") }
    }

    // MARK: 用例

    /// 打开时停在最后一条，往回翻一长段、再往下翻回来：画面要跟着走，不跳、不倒退、不整屏换，内容总高度不变。
    func testScrollFollowsOffsetWithoutJumps() async throws {
        let (window, scroll, transcript) = try await mount(turns: 30)
        defer { MobileProbeWindow.closeAll() }
        print("[transcript-scroll-ios] items \(transcript.items.count) 内容高 \(Int(scroll.contentSize.height)) 偏移 \(Int(scroll.contentOffset.y))")

        let up = await replay(steps: 100, step: 60, scroll: scroll, window: window)
        report("往回翻", up)
        let down = await replay(steps: 100, step: -60, scroll: scroll, window: window)
        report("往下翻", down)

        for (name, reading) in [("往回翻", up), ("往下翻", down)] {
            XCTAssertGreaterThan(reading.travelled, reading.moved * 0.5, "\(name)：画面没怎么动，量的不是滚动")
            XCTAssertEqual(reading.reversals, 0, "\(name)：画面往相反的方向退了")
            XCTAssertEqual(reading.jumps, 0, "\(name)：画面比挪的多走 / 少走了 24pt 以上")
            XCTAssertEqual(reading.unmatched, 0, "\(name)：画面整屏换了内容")
            XCTAssertEqual(reading.heightChanges, 0, "\(name)：滚动中内容总高度变了（懒栈在改估高）")
        }
    }
}
