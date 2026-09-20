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
        // 预热：第一次挂载要吃字体加载、首次建树这些一次性成本。不丢掉的话，跑在最前面的
        // 那一档基线被抬高，实测静态档 0.144s 而 CA 档只有 0.048s —— 基线脏了，
        // 「CA 不比静态贵」这条断言就名存实亡。
        _ = await cpuSeconds(.still, seconds: 0.4)
        unmountAll()
        // 正序 + 反序各跑一遍求和，摊掉「先跑的那档占便宜」这类顺序效应。
        for arm in [Arm.still, .ca, .swiftUIForever, .swiftUIForever, .ca, .still] {
            cpu[arm, default: 0] += await cpuSeconds(arm)
            unmountAll()
        }
        for arm in [Arm.still, .ca, .swiftUIForever] {
            print(String(format: "[ca-motion] %-24@ 主线程 CPU %.3fs   相对静态 %.1f×",
                         arm.rawValue as NSString, cpu[arm]!, cpu[arm]! / cpu[.still]!))
        }

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

    /// 全仓（mac + iOS）不得再出现 `.repeatForever(`。
    ///
    /// 搜带括号的形态而不是裸名：注释里要提这个名字解释「为什么不能用它」，搜裸名会被
    /// 自己的说明文字绊倒。代码形态一定带括号（即便用默认参数也要写 `()`）。
    func testNoForeverAnimationsInAppSources() throws {
        var offenders: [String] = []
        var scanned = 0
        for dir in ["uTerm", "uTermMobile"] {
            let root = Self.repoRoot.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                if text.contains("repeatForever(") {
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
