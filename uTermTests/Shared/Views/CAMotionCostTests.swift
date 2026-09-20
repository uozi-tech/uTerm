import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 常驻动画的主线程账，以及「别再写 `.repeatForever`」的源码闸门。
///
/// 背景：SwiftUI 的常驻动画会把整个 `NSHostingView` 钉在「每帧重跑 render +
/// display list diff」的状态，代价跟**整棵视图树**成正比而非动画元素，且窗口不可见
/// 也不停。2026-09-20 实测 1.16.4 @ 120Hz：欢迎页两个呼吸点让 app **空载** 吃
/// 31.9% CPU、WindowServer 顶到 61%，而当时一个窗口都不在可见 Space 上。
///
/// 现在这些装饰都走 `CAMotion.swift` 的 CA 图元。这条量的是「换完之后主线程真的
/// 不付钱了」，同时充当 AppKit 分支的**运行时冒烟** —— 之前那个必崩的反向
/// `ClosedRange`（`0.0324...0`）编译期抓不到，只有真跑起来才会炸。
@MainActor
final class CAMotionCostTests: XCTestCase {
    private var windows: [NSWindow] = []

    /// 拆窗不走 `tearDown()`：`XCTestCase.tearDown()` 是 `nonisolated` 的，在模块级
    /// `@MainActor` 默认隔离下覆写它会被严格并发拦住（`sending 'self' risks causing
    /// data races`）。同 `ProbeSmokeTests:22` 的做法：用例开头 `defer { unmountAll() }`，
    /// 断言抛错也能把窗拆掉。
    private func unmountAll() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - 三档对照

    private enum Arm: String {
        /// 静态圆点，完全不动 —— 地板。
        case still = "static-dot"
        /// 现在的实现：CA 驱动。
        case ca = "PulseDot(CA)"
        /// 改前的实现：SwiftUI `.repeatForever`。**只活在这个测试里**，用来证明这套
        /// 量法看得见差异 —— 否则「CA 不比静态贵」那句话没有意义。
        case swiftUIForever = "SwiftUI repeat-forever"
    }

    /// 文本密集的树 —— 代价 ∝ 树大小，所以树要接近真实（欢迎页是服务器列表 + 详情面板）。
    private struct Panel: View {
        let arm: Arm
        let dots: Int
        let rows: Int

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ForEach(0..<dots, id: \.self) { _ in indicator }
                    Text("已连接 · probe").font(UD.caption).foregroundStyle(UD.text2)
                }
                ForEach(0..<rows, id: \.self) { i in
                    Text("host-\(i).example.internal   root@10.0.\(i % 255).\(i % 99)   :22")
                        .font(UD.caption)
                        .foregroundStyle(i.isMultiple(of: 2) ? UD.text2 : UD.text3)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        @ViewBuilder private var indicator: some View {
            switch arm {
            case .still:
                Circle().fill(UD.success).frame(width: 8, height: 8)
            case .ca:
                PulseDot(color: UD.success, pulse: true)
            case .swiftUIForever:
                LegacyPulseDot()
            }
        }
    }

    /// 改前那版的等价实现，只用于对照组。
    private struct LegacyPulseDot: View {
        @State private var animate = false
        var body: some View {
            ZStack {
                Circle().fill(UD.success).padding(-2).opacity(0.18)
                    .scaleEffect(animate ? 1.1 : 0.9)
                    .opacity(animate ? 0.0 : 0.18)
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                               value: animate)
                    .onAppear { animate = true }
                Circle().fill(UD.success).frame(width: 8, height: 8)
            }
            .frame(width: 8, height: 8)
        }
    }

    /// 挂起一档，返回主线程在这段墙钟里真正烧掉的 CPU 秒数。
    ///
    /// 不要用「固定间隔心跳的实收拍数」量这个：那套量的是主线程堵不堵，粒度 8ms，
    /// 而单帧渲染远在其下 —— uTable 上实测三档 344/344/345 完全分不开。
    private func cpuSeconds(_ arm: Arm, seconds: Double = 1.5) async -> Double {
        let size = NSSize(width: 900, height: 620)
        let host = NSHostingView(rootView: Panel(arm: arm, dots: 8, rows: 90))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(
            contentRect: NSRect(origin: .zero, size: size),
            contentView: host,
            placement: .transparentOnScreen)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        // 动画起跳 + 首帧布局落定，别把建树成本算进账。
        try? await Task.sleep(for: .milliseconds(500))

        let cpu0 = ProbeMetrics.threadCPUSeconds()
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(for: .milliseconds(8))
        }
        return ProbeMetrics.threadCPUSeconds() - cpu0
    }

    /// CA 版呼吸点不该比静态圆点明显更贵；改前的 SwiftUI 写法必须明显更贵。
    func testPulseDotCostsNoMainThreadCPU() async throws {
        defer { unmountAll() }
        var cpu: [Arm: Double] = [:]
        // 预热：每档第一次挂载都有各自的一次性成本（CA 那档还要建平台视图、装
        // CAAnimation）。只热一档不够 —— 热过 `.still` 之后它自己仍量出 0.125s。
        for arm in [Arm.still, .ca, .swiftUIForever] {
            _ = await cpuSeconds(arm, seconds: 0.3)
            unmountAll()
        }
        // 轮转，让每档在「第一个 / 中间 / 最后一个」三种位置上各跑一次：最前面那档吃
        // 冷启动，紧跟在 `.repeatForever` 后面那档吃上一档的余波，位置确实有偏差。
        //
        // ⚠️ 但轮转**并没有**让 `still` 与 `ca` 对齐（轮转后仍是 0.062 vs 0.032）。
        // 所以别再花力气调这个：这两档都贴在**量测地板**上 —— 那点开销主要来自测量
        // 循环自身的 MainActor 往返，不是渲染 —— 地板上两个数的比值就是噪声放大，
        // 换什么顺序都不会稳。具体为什么 `still` 反而略高没有定论（猜测与 SwiftUI
        // 把内容拍平进一张大绘制层、而有平台视图时会分层有关，未验证）。
        //
        // 这条探针要抓的是「有人把 CA 换回 SwiftUI 常驻动画」，那个信号是 5–12×，
        // 在噪声之上一个数量级，判据依然可靠。
        for pass in [[Arm.still, .ca, .swiftUIForever],
                     [Arm.ca, .swiftUIForever, .still],
                     [Arm.swiftUIForever, .still, .ca]] {
            for arm in pass {
                cpu[arm, default: 0] += await cpuSeconds(arm, seconds: 0.8)
                unmountAll()
            }
        }
        for arm in [Arm.still, .ca, .swiftUIForever] {
            print(String(format: "[ca-motion] %-24@ 主线程 CPU %.3fs   相对静态 %.1f×",
                         arm.rawValue as NSString, cpu[arm]!, cpu[arm]! / cpu[.still]!))
        }
        // 注意：`static` 与 `ca` 两档都贴在量测地板上（这点开销主要来自测量循环自身的
        // MainActor 往返，不是渲染），两者之间的比值是噪声放大，别当结论读。
        // 有意义的是它俩与 `repeatForever` 的量级差。

        let still = cpu[.still]!, ca = cpu[.ca]!, legacy = cpu[.swiftUIForever]!

        // 对照组先行：量法看不见差异的话，下面那条「CA 不比静态贵」就是空话。
        XCTAssertGreaterThan(legacy, still * 1.5,
                             String(format: "对照组（SwiftUI .repeatForever）没比静态档贵多少"
                                    + "（%.3fs vs %.3fs）—— 这套量法看不见常驻动画的代价，"
                                    + "换更大的树或更长的窗口再量，别改判据", legacy, still))
        XCTAssertLessThan(ca, still + (legacy - still) * 0.5,
                          String(format: "CA 版呼吸点吃掉了主线程 CPU（%.3fs，静态 %.3fs，"
                                 + "旧写法 %.3fs）—— 它本该把插值交给渲染服务器，主线程不付钱",
                                 ca, still, legacy))
    }

    // MARK: - 源码闸门

    /// 把注释剥掉，只留代码。
    ///
    /// 源码闸门扫的是**代码**，但源文件的注释里必须能提这个 API 的名字来解释
    /// 「为什么不能用它」。本闸门第一版搜带括号的 `repeatForever(` 以为能躲开注释 ——
    /// uTable 上同一条思路换到 `symbolEffect(` 就当场红了（注释里写的就是
    /// `` `.symbolEffect(.pulse)` ``，括号照样在）。所以正解是先剥注释，
    /// 然后搜裸名 —— 这样 `.repeatForever` 这种不带括号的写法也逃不掉，反而更严。
    ///
    /// 不处理字符串字面量里的 `//`（真出现了也只会多剥一点，方向是把闸门变严）。
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var inBlock = false, inLine = false
        var i = source.startIndex
        while i < source.endIndex {
            let rest = source[i...]
            if inLine {
                if source[i] == "\n" { inLine = false; out.append("\n") }
                i = source.index(after: i); continue
            }
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; i = source.index(i, offsetBy: 2) }
                else { i = source.index(after: i) }
                continue
            }
            if rest.hasPrefix("//") { inLine = true; i = source.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("/*") { inBlock = true; i = source.index(i, offsetBy: 2); continue }
            out.append(source[i])
            i = source.index(after: i)
        }
        return out
    }

    /// 全仓（mac + iOS）的**代码**里不得再出现 `repeatForever`。
    func testNoForeverAnimationsInAppSources() throws {
        var offenders: [String] = []
        var scanned = 0
        for dir in ["uTerm", "uTermMobile"] {
            let root = Self.repoRoot.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                if Self.strippingComments(raw).contains("repeatForever") {
                    offenders.append(url.path.replacingOccurrences(
                        of: Self.repoRoot.path + "/", with: ""))
                }
            }
        }
        // 先证明真的扫到了东西。第一版 `repoRoot` 少退了一层，枚举器一个文件都没读到，
        // 这条断言**空过**了（是下面那条自检用例把它抓出来的）—— 空扫通过的闸门等于没有。
        XCTAssertGreaterThan(scanned, 200,
                             "只扫到 \(scanned) 个 swift 文件，路径八成错了：\(Self.repoRoot.path)")
        XCTAssertTrue(offenders.isEmpty,
                      "这些文件又用上了 SwiftUI 常驻动画：\(offenders.joined(separator: ", "))"
                      + " —— 常驻装饰走 CAMotion.swift 的 PulseDot / BlinkingBar / SpinningArc")
    }

    /// 闸门自身要能失败：扫不到源码就是闸门坏了，必须报错而不是静默通过。
    func testGuardActuallyScansSources() throws {
        let sentinel = Self.repoRoot.appendingPathComponent("uTerm/Shared/Views/CAMotion.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                      "找不到 CAMotion.swift，源码闸门已失效：\(sentinel.path)")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // 去掉文件名 → Views
            .deletingLastPathComponent()   // Shared
            .deletingLastPathComponent()   // uTermTests
            .deletingLastPathComponent()   // 仓库根
    }
}
