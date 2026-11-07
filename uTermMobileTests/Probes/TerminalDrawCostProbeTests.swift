import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// iOS 终端一次整屏重画的开销（SwiftTerm 补丁 #20：按行缓存排版结果）。
///
/// iOS 上 `setNeedsDisplay(rect)` 只标一小块也没用：`draw` 拿到的永远是整个视图，位图整块重画，滚动时每一帧也是。
/// 能省的是「没变的行别再排一遍版」：建属性串、建 CTLine 约占一次重画的四成（uTerm 配色、54×58 的屏、优化构建采样）。
/// 三种情形在同一次运行里比：
/// - 每行都变：缓存全部失效，等于没缓存；
/// - 什么都没变：滚动、回弹时的每一帧；
/// - 只变一行：Claude Code 思考时每帧只改转圈那一行。
/// 只比同一次运行里的相对值，不看绝对毫秒数（模拟器和真机、负载高低都差很多）。
/// 准备步骤只喂字节、不画：在计时外画一次，缓存就在计时前重建好了，三组会一样快（踩过）。
@MainActor
final class TerminalDrawCostProbeTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    /// 像 Claude Code 跑了一阵之后的屏幕：带色的 diff、路径、中文、界面符号，每行接近铺满但不溢出。
    /// Claude Code（Ink）按终端宽度自己断行、输出硬换行；行要是溢出折到下一行，整屏会连成一个软折行段落，
    /// 段落里一行变了整段都要重排（双向文字按段落排版），量的就不是 Claude 的情形了（踩过）。
    private static func screen(rows: Int, salt: Int) -> String {
        let colors = ["32", "31", "36", "33", "38;2;215;119;87", "90"]
        return (0..<rows).map { index in
            "\u{1B}[\(index + 1);1H\u{1B}[2K\u{1B}[\(colors[(index + salt) % colors.count])m\(index % 2 == 0 ? "+" : "⎿")"
                + " let v\(salt % 10) = f(\(index % 100))\u{1B}[0m \u{1B}[2m// 说明\u{1B}[0m"
                + " \u{1B}[1mApp/File\(index % 100).swift\u{1B}[0m"
        }.joined()
    }

    /// 和 `SwiftTermView` 一样装上 uTerm 的配色：背景是实色（SwiftTerm 默认是 `.clear`、靠图层底色显示，
    /// 那种配置下背景填充走逐像素混合、量出来的账完全不同）。
    private func configuredTerminal() throws -> SwiftTerm.TerminalView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 760)
        window.isHidden = false
        self.window = window
        let terminal = SwiftTerm.TerminalView(frame: window.bounds,
                                              font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        window.addSubview(terminal)
        terminal.layoutIfNeeded()
        let scheme = MTerminalColors.resolve(dark: true)
        TerminalAppearance.applyColors(to: terminal, scheme: scheme)
        TerminalAppearance.applyCaretColors(to: terminal, scheme: scheme, shape: .block)
        terminal.backgroundColor = scheme.backgroundColor
        feedFrame(terminal, Self.screen(rows: terminal.getTerminal().rows, salt: 0) + "\u{1B}[?25l")
        return terminal
    }

    /// 喂一帧（同步输出包起来），把排队的显示更新做掉，但不画。
    private func feedFrame(_ terminal: SwiftTerm.TerminalView, _ text: String) {
        terminal.feed(text: "\u{1B}[?2026h" + text + "\u{1B}[?2026l")
        terminal.flushPendingDisplay()
    }

    /// 一次整屏重画的耗时中位数（毫秒）。`prepare` 在计时外改内容，不画。
    private func redrawCost(_ terminal: SwiftTerm.TerminalView, samples: Int = 30,
                            prepare: (Int) -> Void) -> Double {
        var times: [Double] = []
        for sample in 0..<samples {
            prepare(sample)
            terminal.setNeedsDisplay(terminal.bounds)
            let start = CFAbsoluteTimeGetCurrent()
            terminal.layer.displayIfNeeded()
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return ProbeMetrics.percentile(times, 0.5)
    }

    func testUnchangedRowsAreNotLaidOutAgain() throws {
        let terminal = try configuredTerminal()
        let rows = terminal.getTerminal().rows
        XCTAssertLessThan(Self.screen(rows: 1, salt: 0).count, terminal.getTerminal().cols * 2)
        // 热身：字体回退、属性缓存都建好，三组都在同样的热状态下比。
        _ = redrawCost(terminal, samples: 5) { self.feedFrame(terminal, Self.screen(rows: rows, salt: $0)) }

        let everyRow = redrawCost(terminal) { self.feedFrame(terminal, Self.screen(rows: rows, salt: 100 + $0)) }
        let unchanged = redrawCost(terminal) { _ in }
        let spinner = redrawCost(terminal) { sample in
            let glyph = ["✢", "✳", "✶", "✻", "✽"][sample % 5]
            self.feedFrame(terminal, "\u{1B}[\(rows - 4);1H\u{1B}[2K\u{1B}[38;2;215;119;87m\(glyph)"
                + " Thinking… (\(sample)s)\u{1B}[0m")
        }
        print("DRAWCOST rows=\(rows) cols=\(terminal.getTerminal().cols) everyRow=\(everyRow)ms "
            + "unchanged=\(unchanged)ms spinner=\(spinner)ms")

        XCTAssertLessThan(unchanged, everyRow * 0.75, "内容没变的整屏重画不该和每行都变一样贵")
        XCTAssertLessThan(spinner, everyRow * 0.75, "只变一行时其余行应该直接用缓存")
    }
}
