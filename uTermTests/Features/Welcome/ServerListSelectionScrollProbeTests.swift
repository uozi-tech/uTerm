import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 欢迎页服务器列表的**选中驱动滚动**探针：`LazyVStack` + `ScrollViewReader.scrollTo`
/// + `withAnimation` 三要素齐全，与 uTable 曾经卡死的 AI 面板（`753575d`）同形。
///
/// ## 为什么单开一个探针
///
/// `WelcomeServerListCostTests` 量的是「鼠标滚轮扫列表」那条路径，它根本不碰
/// `onChange(of: selectedID)`。而 `753575d` 那次卡死的触发点不是滚轮，是
/// **程序性 `scrollTo`**：
///
/// > 消息到达 → `withAnimation { scrollTo("tail") }` → `measureEstimates` 全量测行
/// > × 弹性祖先反复探 ideal 高度 → 单次布局事务 3s+、99% CPU。
/// > （uTable `docs/swiftui-scroll-perf-playbook.md` §七）
///
/// 欢迎页里对应的触发点是**键盘 ↑↓ 换选中行**（`WelcomeKeymap` 的 `.next` / `.prev`）
/// 与**搜索过滤**（`profiles` 变了 → `selectFirstIfNeeded` → `selectedID` 变 →
/// 又一次 `withAnimation { scrollTo }`）。所以这个探针驱动的是 `selectedID`
/// 和 `query`，不是 `contentView.scroll(to:)`。
///
/// ## §七 三判据在 `ServerList` 上的逐条判定（2026-09-08）
///
/// 1. **无 `withAnimation` 包着的 `scrollTo`** —— **不满足**
///    （`onChange(of: selectedID)` 里 `withAnimation(.easeInOut(duration: 0.12))`）。
/// 2. 容器提案：`ScrollView` 挂 `.frame(maxWidth:.infinity, maxHeight:.infinity)`，
///    坐在填满整个 pane 的 `HStack` 里 —— 填充提案，满足。
/// 3. 行高稳定廉价：`ServerRow` 单行固定 61pt（探针实测 docHeight/rows），满足。
///
/// ## 判据 1 不过，但**失效模式没复现**，而且照方抓药是负收益
///
/// 三臂各两轮交替，2000 台 / 60 组，连续 200 次换选中行：
///
/// | 一次「换选中行 + 布局」 | p50 | p95 | max | 3s 心跳 | NSView |
/// |---|---|---|---|---|---|
/// | 带 `withAnimation`（现状） | 34.97 / 36.69ms | 91.21 / 56.19ms | 98 / 61ms | 242 / 246 | 39 |
/// | 去掉 `withAnimation` | 39.11 / 39.79ms | 63.91 / 64.25ms | 67 / 67ms | 245 / 251 | 39 |
/// | 连 `scrollTo` 一起去掉（当时的归因臂：**完全不滚**） | **6.59ms** | **9.16ms** | **11ms** | **333** | 39 |
///
/// 100 台真实档同向：带动画 p50 6.18 / 6.37ms，去掉动画 8.32 / 8.87ms。
///
/// 两条结论都跟去之前的先验相反：
///
/// 1. **753575d 的失效模式在这里不发生。** 那次是「单次布局事务 3s+、99% CPU」；
///    这里最坏一步 98ms，3 秒心跳 242~251 拍（被按死的话是个位数），
///    NSView 恒 39 不随行数涨（§七 第四条：判回不回收只看扫完之后数 NSView）。
/// 2. **去掉 `withAnimation` 不是收益，是负收益。** p50 35 → 39ms，
///    真实档 6.2 → 8.6ms，只有尾部收紧一点。账在 `scrollTo` 本身：
///    它逼 `LazyVStack` 解析 2000 行的目标偏移，35ms vs 完全不滚的 6.6ms。
///    （这 35 : 6.6 里混着「整屏重绘」的账；把分母换成手滚同样距离之后，
///    纯 `scrollTo` 的税是 2.0~2.3×，见下面第三轮。）
///
/// 所以动画留着（键盘导航的设计语义）。
///
/// ## 闸门为什么不再钉绝对拍数（2026-09-08 第二轮）
///
/// 这个类第一版把真实档写成 `beats > 200`（当时实测 324~334）。它在**全量套件里
/// 读到 177 判红，单跑同一条用例 214~238 判绿**——同事拿闸门开 / 关做了三组交替
/// A/B（238 / 222 / 214 vs 228 / 212 / 224），证明与 `ScrollHoverGate` 无关，
/// 纯粹是**绝对阈值在负载下翻面**。这正是 playbook §二·4 点名的错误：
///
/// > 绝对基准不可移植，只做同一次运行内的相对比较。闸门写成「A 必须优于 B 的 N 倍」，
/// > 不要写死毫秒数——否则换台机器就是假红。
///
/// 所以整类的判据换成两种，绝对数字只打印（`[server-list raw]` 行）：
///
/// - **结构判据**：NSView 不随规模涨（100 台 vs 2000 台 ± 小常数）、
///   每行高度跨规模一致且文档高 == 行数 × 行高、`scrollTo` 真的把目标行送进视口
///   （12 个散点全中），归因臂的视口原点纹丝不动（证明分母确实少了那次 `scrollTo`）。
/// - **同轮相对判据**：同一个进程里跑「带 `scrollTo`」与「归因臂」两臂，
///   正反各一遍取均值，只比两臂的比值。
///
/// 留下的绝对护栏只有**数量级**级别（心跳 > 60 拍、单步 < 500ms、过滤 < 800ms）：
/// 它们钉的是 `753575d` 那种「一次布局事务吞掉整个交互」的形态，
/// 离实测值有一到两个数量级，负载翻不动。
///
/// ## 分母也要干同样多的活（2026-09-08 第三轮，本轮）
///
/// 「换成比值」还不够。第一版比值的分母是**连滚都不滚**的那一臂，结果在旁边跑着
/// 另一套全量测试的机器上（load ~5）当场翻面：
///
/// | 100 台 · 一步 | 空闲时 | 有负载时 | 膨胀 |
/// |---|---|---|---|
/// | 带 `scrollTo`（分子） | 6.2ms | 16.1ms | **2.6×** |
/// | 不滚的分母（旧） | 5.3ms | 6.1ms | 1.15× |
/// | 比值 | 1.17× | **2.62×（判红）** | —— |
///
/// 原因是两臂的**绘制量根本不一样**：滚动那臂每一步整屏重绘，不滚那臂只重画两行
/// 高亮。WindowServer 一忙，只有分子涨。「同轮比值能约掉机器负载」的前提是
/// 两臂干同样多的活——这一条 playbook §二·4 没写透，本轮补上。
///
/// 现在的分母是**手滚镜像**：归因臂照样关掉 `scrollsSelectionIntoView`，但探针每一步
/// 用 `NSClipView.scroll(to:)` 把目标行滚进视口（最小可见滚动，与 `scrollTo(id)`
/// 默认锚点同语义）。两臂重绘同样多、滚同样远，差的只剩 `scrollTo` 自己：
/// 把 id 解析成偏移（`LazyVStack` 要为此摸行）+ 那 0.12s 补间。
///
/// 换分母之后（七轮，机器负载各不相同——其中三轮旁边跑着另一套全量测试）：
///
/// | 比值 | 七轮读数 | 闸门（max × 1.5） |
/// |---|---|---|
/// | 2000 台 一步 p50 | 2.24 / 2.25 / 2.13 / 1.97 / 2.19 / 2.01 / 2.23× | < 3.4 |
/// | 2000 台 心跳（倒过来） | 1.27 / 1.16 / 1.23 / 1.15 / 1.18 / 1.13 / 1.23× | < 1.9 |
/// | 100 台 一步 p50 | 0.98 / 0.91 / 0.90 / 0.88 / 0.90 / 0.92 / 0.96× | < 1.5 |
/// | 100 台 心跳（倒过来） | 1.18 / 1.06 / 1.15 / 0.96 / 1.12 / 1.17 / 1.28× | < 1.9 |
///
/// 同期的绝对读数在 13~17ms（100 台）与 64~72ms（2000 台）之间漂了 20~30%，
/// 比值只漂 5~7%。顺带得到一个新结论：**真实档上 `scrollTo` 不收税**
/// （0.88~0.98×，比手滚还略便宜）；那笔税全是 2000 行档才有的。
///
/// 手滚镜像只在 ①②③ 的计时段里跑；④ 落点那段归因臂一步都不滚，
/// 所以 `scrollSpan == 0` 仍然是「产品开关真的关掉了」的自证。
///
/// ## 「落定」也得是轮询出来的（2026-09-08 第四轮，本轮）
///
/// 第三轮把时间闸门都换成比值之后，全量套件里翻面的换成了一条**结构判据**：
/// 「2000 台：动画落定后目标行必须在视口内」——12 个散点只中 10 个判红，
/// 同一条单跑三次全绿。当时同机还压着 uTable 的全量（本条一步 p50 50~73ms、
/// 超预算 100%）。
///
/// 判据本身没问题（`scrollTo` 必须把目标行滚进视口），坏的是**「落定」的定义**：
/// ④ 那段原本固定 `Task.sleep(260ms)`，赌 0.12s 补间加 SwiftUI 调度一定跑得完。
/// 负载一来赌输，读到的就是补间中途的几何——**固定等待量的是机器有多闲，
/// 不是 `scrollTo` 有没有生效**。这跟第二、三轮是同一个病（绝对量在负载下翻面），
/// 只是这次穿的是结构判据的外衣。
///
/// 现在 ④ 轮询到「目标行进入视口 **且** 视口原点连续两拍不动」为止：8ms 心跳步进，
/// 每拍 `layoutSubtreeIfNeeded()` + `displayIfNeeded()`，上限 2s（`settleTimeout`）。
/// 超时才判红。落定耗时逐点记录、**只打印**：
///
/// | 落定耗时 | 空闲（三轮） | 人为加负载（14 忙循环 + 同机另一套全量，load ≈ 26） |
/// |---|---|---|
/// | 100 台 · 带 `scrollTo` | p50 249~256ms，max 251~270ms | p50 244~253ms，max 249~259ms |
/// | 2000 台 · 带 `scrollTo` | p50 341~352ms，**max 447~497ms** | p50 467~540ms，**max 682~715ms** |
/// | 超时 | 0 | 0 |
///
/// 也就是说 260ms 那条线**空闲时就已经压不住 2000 台档**（旧写法还能绿，是因为
/// 「行进了视口」比「补间彻底停下」来得早）；负载一来整档 330~715ms，必然读到中途几何。
/// 换成轮询后 `landed = 12/12`、`timeouts = 0`，负载轮的同轮比值也照常
/// （2000 台一步 1.95×、100 台 0.97×）。计时段 ①②③ 一行没改，读数与第三轮可比。
///
/// ## 规模来源
///
/// 与 `WelcomeServerListCostTests` 同源：真实档 100 台 / 10 组，极端档
/// 2000 台 / 60 组（`~/.ssh/config` 批量导入是产品功能；Tweaks 那个 50 台的钳
/// 是调试旋钮上限，不是数据上限）。
@MainActor
final class ServerListSelectionScrollProbeTests: XCTestCase {

    // MARK: - 闸门常数（全部由同轮比值定，见文件头「闸门为什么不再钉绝对拍数」）

    /// 2000 台：带 `scrollTo` 的一步 p50 ÷ 归因臂手滚的一步 p50。
    /// 七轮实测 1.97~2.25（最大 2.25），留 1.5× 余量。
    /// 这是 `scrollTo` 在 2000 行 `LazyVStack` 上「把 id 解析成偏移」的税
    /// —— 同样的滚动距离，手滚 33ms、`scrollTo` 66ms。
    private static let bigStepRatioCeiling = 3.4

    /// 2000 台：归因臂心跳拍数 ÷ 带 `scrollTo` 心跳拍数（分子分母倒过来，
    /// 因为拍数越大越好）。七轮实测 1.13~1.27（最大 1.27），留 1.5× 余量。
    private static let bigBeatsRatioCeiling = 1.9

    /// 100 台真实档：同两臂的一步 p50 比值。真实档上 `scrollTo` 几乎不收税——
    /// 七轮实测 0.88~0.98（最大 0.98，**比手滚还便宜一点**），留 1.5× 余量。
    /// 这条才是「日常规模不许退化」的钉子：2000 台允许 3.4×，100 台只允许 1.5×。
    private static let smallStepRatioCeiling = 1.5

    /// 100 台真实档：心跳比值。两臂在真实档上本该几乎一样。
    /// 七轮实测 0.96~1.28（最大 1.28），留 1.5× 余量（1.28 × 1.5 = 1.92）。
    private static let smallBeatsRatioCeiling = 1.9

    /// NSView 数跨规模允许的常数漂移（`LazyVStack` 在两档裁出的行数会差几行）。
    private static let viewCountSlack = 12

    /// ④ 落点段等「动画落定」的上限（秒）。产品那次补间是 0.12s，这里给到 2s
    /// 是为了**给负载留足余量**：全量套件里同机压着另一套测试时，一步换选中行
    /// 就要 50~73ms，260ms 的固定等待连一次补间都盖不住（12 个散点中 10 个假红）。
    /// 等满 2s 还没把目标行滚进视口，才是 `scrollTo` 真的没生效。
    private static let settleTimeout = 2.0

    // MARK: - 夹具

    private var windows: [NSWindow] = []

    /// 见 `ProbeSmokeTests`：`uTermTests` 默认隔离 `nonisolated`，不能覆写
    /// `tearDown()` 拆窗，每条用例开头 `defer { closeAllWindows() }`。
    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static let size = NSSize(width: 900, height: 620)

    struct Reading {
        var label = ""
        var rows = 0
        /// 这一臂是不是带 `scrollTo`（false = 归因臂手滚：探针自己滚同样的距离）。
        var scrollsIntoView = true
        var mountMS = 0.0
        /// 3 秒 8ms 心跳实际收到的拍数（理想 375）。每一拍都换一次选中行。
        /// **只作分子分母，不单独判红**——绝对拍数在负载下会翻面。
        var beats = 0
        /// 一次「换选中行 + 布局」的耗时分布。同上，只作比值。
        var stepP50 = 0.0
        var stepP95 = 0.0
        var stepMax = 0.0
        var overBudget = 0.0
        /// 一次「切换搜索过滤 + 布局」的最坏耗时。
        var filterMax = 0.0
        var views = 0
        var histogram = ""
        var docHeight = 0.0
        /// 视口高度（`NSClipView.bounds.height`），拿来算「还能滚多远」。
        var viewportHeight = 0.0
        /// 选第一行 ⇄ 选最后一行，视口原点走了多远。带 `scrollTo` 时应当≈满量程，
        /// 归因臂应当是 0（④ 那段不镜像手滚，见文件头）。
        var scrollSpan = 0.0
        /// 12 个散点里，动画落定后目标行真的落在视口内的次数。
        var landed = 0
        var landingProbes = 0
        /// ④ 每个落点等到「落定」花了多久（含首尾那两次量 `scrollSpan` 的）。
        /// **只打印，不判红**——绝对毫秒在负载下没有可比性。
        var settleMS: [Double] = []
        /// 等到超时（`settleTimeout`）还没落定的次数。> 0 才谈得上真回归。
        var settleTimeouts = 0

        var rowHeight: Double { rows > 0 ? docHeight / Double(rows) : 0 }
        /// 满量程：文档高减去视口高。
        var scrollRange: Double { max(0, docHeight - viewportHeight) }
        var settleP50: Double { ProbeMetrics.percentile(settleMS, 0.5) }
        var settleMax: Double { settleMS.max() ?? 0 }
    }

    /// 一臂的多轮读数（正序一遍 + 反序一遍），比值一律拿均值算。
    private struct Arm {
        var readings: [Reading] = []
        var label: String { readings.first?.label ?? "?" }
        var beats: Double { mean { Double($0.beats) } }
        var stepP50: Double { mean(\.stepP50) }
        var stepP95: Double { mean(\.stepP95) }
        var stepMax: Double { readings.map(\.stepMax).max() ?? 0 }
        var filterMax: Double { readings.map(\.filterMax).max() ?? 0 }
        var minBeats: Int { readings.map(\.beats).min() ?? 0 }
        /// 结构量在两轮之间不该动，取第一轮即可。
        var first: Reading { readings[0] }

        private func mean(_ key: KeyPath<Reading, Double>) -> Double {
            mean { $0[keyPath: key] }
        }

        private func mean(_ pick: (Reading) -> Double) -> Double {
            guard !readings.isEmpty else { return 0 }
            return readings.map(pick).reduce(0, +) / Double(readings.count)
        }
    }

    private func log(_ r: Reading) {
        print(String(format: """
            [server-list raw] %@ rows=%d scrollTo=%@ mount=%.1fms beats=%d \
            step p50=%.2fms p95=%.2fms max=%.1fms over8.33=%.1f%% \
            filterMax=%.1fms views=%d docH=%.0f rowH=%.2f viewportH=%.0f \
            span=%.0f/%.0f landed=%d/%d settle p50=%.0fms max=%.0fms timeouts=%d
            """,
            r.label, r.rows, r.scrollsIntoView ? "on" : "OFF", r.mountMS, r.beats,
            r.stepP50, r.stepP95, r.stepMax, r.overBudget,
            r.filterMax, r.views, r.docHeight, r.rowHeight, r.viewportHeight,
            r.scrollSpan, r.scrollRange, r.landed, r.landingProbes,
            r.settleP50, r.settleMax, r.settleTimeouts))
        print("[server-list raw]   \(r.label) 每个落点的落定耗时(ms)："
              + r.settleMS.map { String(format: "%.0f", $0) }.joined(separator: " "))
        print("[server-list raw]   \(r.label) 类名直方图：\(r.histogram)")
    }

    private func logRatios(_ tag: String, with: Arm, without: Arm) {
        print(String(format: """
            [server-list raw] %@ 同轮比值 step p50 %.2f/%.2f=%.2f× \
            beats %.1f/%.1f=%.2f×（分母是归因臂手滚，%d 轮均值）
            """,
            tag, with.stepP50, without.stepP50, with.stepP50 / max(without.stepP50, 0.001),
            without.beats, with.beats, without.beats / max(with.beats, 0.001),
            with.readings.count))
    }

    // MARK: - 量

    private func measure(_ label: String,
                         rows: Int,
                         groups: Int,
                         scrollsIntoView: Bool) async throws -> Reading {
        let profiles = WelcomeServerListCostTests.makeProfiles(count: rows, groups: groups)
        let driver = SelectionDriver()
        driver.selectedID = profiles.first?.id
        let harness = ServerListSelectionHarness(
            driver: driver,
            profiles: profiles,
            existingGroups: WelcomeServerListCostTests.groupNames(groups),
            groupColorHexes: WelcomeServerListCostTests.groupColorHexes(groups),
            scrollsSelectionIntoView: scrollsIntoView)
        let host = NSHostingView(rootView: AnyView(
            harness.frame(width: Self.size.width, height: Self.size.height)))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: Self.size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)

        var r = Reading(label: label, rows: rows, scrollsIntoView: scrollsIntoView)
        let t0 = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        r.mountMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        XCTAssertTrue(ProbeWindow.blindsRealMouse(window),
                      "透明屏内档必须谎报鼠标位置，否则用户光标会点亮 .onHover")

        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        try await Task.sleep(for: .milliseconds(250))
        layout()
        let scrollView = host.firstScrollView()
        var flipped = true
        if let scroll = scrollView, let doc = scroll.documentView {
            r.docHeight = Double(doc.frame.height)
            r.viewportHeight = Double(scroll.contentView.bounds.height)
            flipped = doc.isFlipped
        }

        // 归因臂的**手滚镜像**：把 `scrollTo` 会走的那段路，用 `NSClipView.scroll(to:)`
        // 原样走一遍（最小可见滚动，与 `scrollTo(id)` 的默认锚点同语义）。
        //
        // 为什么不能让分母「干脆不滚」：第一版就是那么写的，结果 2026-09-08 这轮
        // 在旁边跑着另一套全量测试的机器上直接翻面 —— 带 `scrollTo` 那臂 100 台
        // 6.2 → 16.1ms（2.6×），不滚的分母 5.3 → 6.1ms（1.15×），比值从 1.17
        // 涨到 2.62 判红。原因是**两臂的绘制量根本不一样**：滚动那臂每步整屏重绘，
        // 不滚那臂只重画两行高亮；WindowServer 一忙，只有分子涨。
        // 「同轮比值」要能约掉负载，两臂就得干同样多的活（playbook §二·4 的本意）。
        // 现在两臂都整屏重绘同样的距离，差的只剩 `scrollTo` 自己：
        // 把 id 解析成偏移（`LazyVStack` 要为此摸行）+ 那 0.12s 补间。
        func mirrorScroll(toRow index: Int) {
            guard !scrollsIntoView, let scroll = scrollView, r.rowHeight > 0 else { return }
            let rowHeight = CGFloat(r.rowHeight)
            let docHeight = CGFloat(r.docHeight)
            let visible = scroll.contentView.bounds
            // 文档翻转时行号越大 y 越大；不翻转时相反。
            let top = flipped
                ? CGFloat(index) * rowHeight
                : docHeight - CGFloat(index + 1) * rowHeight
            var y = visible.origin.y
            if top < visible.minY { y = top }                                   // 目标在上方
            else if top + rowHeight > visible.maxY { y = top + rowHeight - visible.height }
            else { return }                                                     // 已经可见 —— 和 scrollTo 一样不滚
            let maxOffset = max(0, docHeight - visible.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // ① 心跳：3 秒里每 8ms 换一次选中行（= 用户按住 ↓ 不放）。
        //    主线程要是被一次 3s 的布局事务吃掉，拍数会掉到个位数。
        let heartbeatStart = Date()
        var cursor = 0
        while Date().timeIntervalSince(heartbeatStart) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            cursor = (cursor + 1) % profiles.count
            driver.selectedID = profiles[cursor].id
            mirrorScroll(toRow: cursor)
            r.beats += 1
        }
        layout()
        try await Task.sleep(for: .milliseconds(120))

        // ② 单步耗时：连续 200 次 ↓，每次量「改选中 + 同步布局」端到端。
        //    步长 7 让选中行不断跨出视口，逼 `scrollTo` 真的滚。
        var steps: [Double] = []
        cursor = 0
        for _ in 0..<200 {
            cursor = (cursor + 7) % profiles.count
            let start = CFAbsoluteTimeGetCurrent()
            driver.selectedID = profiles[cursor].id
            mirrorScroll(toRow: cursor)
            layout()
            steps.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(8))
        }
        r.stepP50 = ProbeMetrics.percentile(steps, 0.5)
        r.stepP95 = ProbeMetrics.percentile(steps, 0.95)
        r.stepMax = steps.max() ?? 0
        r.overBudget = Double(steps.filter { $0 > 8.33 }.count) / Double(steps.count) * 100

        // ③ 搜索过滤切换：`profiles` 换一批 → `selectFirstIfNeeded` → 又一次 scrollTo。
        //    "web" 命中 1/5，"" 回到全量，来回 20 次。
        var filters: [Double] = []
        for i in 0..<20 {
            let q = i % 2 == 0 ? "web" : ""
            let start = CFAbsoluteTimeGetCurrent()
            driver.query = q
            // 过滤后 `selectFirstIfNeeded` 把选中挪到第一行 → 带 scrollTo 那臂滚回顶部。
            mirrorScroll(toRow: 0)
            layout()
            filters.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(16))
        }
        driver.query = ""
        mirrorScroll(toRow: 0)
        layout()
        r.filterMax = filters.max() ?? 0

        // ④ 落点：换一行、**轮询到动画真的落定**、看目标行在不在视口里。
        //    这是「`scrollTo` 那 35ms 到底买到了什么」的结构判据 —— 时间判据能被
        //    负载翻面，落点不能。
        //    **这一段归因臂不镜像手滚**（`mirrorScroll` 只在 ①②③ 的计时段里跑），
        //    所以分母的视口在这里纹丝不动 —— `scrollSpan == 0` 依然是「产品开关
        //    真的关掉了」的自证。
        if let scroll = scrollView {
            func visibleRect() -> CGRect { scroll.contentView.bounds }
            let rowHeight = r.rowHeight
            func rowTop(_ index: Int) -> Double {
                // 文档翻转时行号越大 y 越大；不翻转时相反。
                flipped
                    ? Double(index) * rowHeight
                    : r.docHeight - Double(index + 1) * rowHeight
            }
            func rowIsInside(_ index: Int, _ visible: CGRect) -> Bool {
                let top = rowTop(index)
                return top + rowHeight > Double(visible.minY) - 2
                    && top < Double(visible.maxY) + 2
            }

            // 「落定」以前是**固定等 260ms** —— 那是在赌 `withAnimation` 的 0.12s
            // 补间加上 SwiftUI 的调度一定跑得完。全量套件里同机还压着另一套测试时
            // （本条一步 p50 50~73ms、超预算 100%）它赌输了：12 个散点只中 10 个，
            // 同一条单跑三次全绿。判据本身是对的（`scrollTo` 必须把目标行滚进视口），
            // 错的是「落定」的定义 —— 固定等待量的是机器有多闲，不是 scrollTo 有没有生效。
            //
            // 现在轮询到**目标行进入视口且视口原点连续两拍不动**为止：8ms 心跳步进，
            // 每拍 `layoutSubtreeIfNeeded` + `displayIfNeeded`，最多等 `settleTimeout`。
            // 超时才判红 —— 那才是真回归。计时段 ①②③ 一行没动，读数可比。
            func settle(rowIndex: Int?) async throws -> (ms: Double, settled: Bool) {
                let start = CFAbsoluteTimeGetCurrent()
                layout()
                // 归因臂在 ④ 一步都不滚，没有「落定」可等，保持原来的固定等待。
                guard scrollsIntoView, let index = rowIndex, rowHeight > 0 else {
                    try await Task.sleep(for: .milliseconds(260))
                    layout()
                    return ((CFAbsoluteTimeGetCurrent() - start) * 1000, true)
                }
                var lastY = Double(visibleRect().origin.y)
                while CFAbsoluteTimeGetCurrent() - start < Self.settleTimeout {
                    try await Task.sleep(for: .milliseconds(8))
                    layout()
                    let visible = visibleRect()
                    let y = Double(visible.origin.y)
                    if rowIsInside(index, visible) && abs(y - lastY) < 0.5 {
                        return ((CFAbsoluteTimeGetCurrent() - start) * 1000, true)
                    }
                    lastY = y
                }
                return ((CFAbsoluteTimeGetCurrent() - start) * 1000, false)
            }

            func record(_ outcome: (ms: Double, settled: Bool)) {
                r.settleMS.append(outcome.ms)
                if !outcome.settled { r.settleTimeouts += 1 }
            }

            driver.selectedID = profiles[0].id
            record(try await settle(rowIndex: 0))
            let yFirst = Double(visibleRect().origin.y)
            driver.selectedID = profiles[profiles.count - 1].id
            record(try await settle(rowIndex: profiles.count - 1))
            let yLast = Double(visibleRect().origin.y)
            r.scrollSpan = abs(yLast - yFirst)
            for k in 0..<12 {
                let index = k * profiles.count / 12
                driver.selectedID = profiles[index].id
                record(try await settle(rowIndex: index))
                if rowIsInside(index, visibleRect()) { r.landed += 1 }
                r.landingProbes += 1
            }
        }

        r.views = WelcomeServerListCostTests.viewCount(in: host)
        r.histogram = WelcomeServerListCostTests.classHistogram(in: host)
        await closeWindows()
        return r
    }

    /// 两臂正反各一遍（playbook §二·2 / §二·4：比值也要交错采样，
    /// 两档各只跑一遍且顺序固定时，机器状态一漂比值就塌）。
    private func measureInterleavedArms(rows: Int,
                                        groups: Int) async throws -> (with: Arm, without: Arm) {
        var with = Arm()
        var without = Arm()
        let name = "\(rows)台/\(groups)组"
        for (round, order) in [[true, false], [false, true]].enumerated() {
            for scrollsIntoView in order {
                let arm = scrollsIntoView ? "带scrollTo" : "归因臂手滚"
                let r = try await measure("\(name)·\(arm)·第\(round + 1)轮",
                                          rows: rows,
                                          groups: groups,
                                          scrollsIntoView: scrollsIntoView)
                log(r)
                if scrollsIntoView { with.readings.append(r) } else { without.readings.append(r) }
            }
        }
        return (with, without)
    }

    /// 每一臂共有的结构判据：文档高对得上行数、量的确实是那张长表。
    private func assertTableShape(_ r: Reading, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(r.docHeight, 0,
                             "\(r.label)：没量到滚动视图的文档高（量错视图了）",
                             file: file, line: line)
        XCTAssertEqual(r.docHeight, Double(r.rows) * r.rowHeight, accuracy: 1.0,
                       "\(r.label)：文档高必须 == 行数 × 行高",
                       file: file, line: line)
        // `ServerRow` 是固定单行（实测 61pt）。落到这个带子外面 = 行不再等高，
        // 或者量到了别的滚动视图 —— 两种都让「文档高 ÷ 行数」这把尺失效。
        XCTAssertTrue((40.0...90.0).contains(r.rowHeight),
                      "\(r.label)：行高 \(String(format: "%.1f", r.rowHeight))pt 落在 40~90 之外，"
                      + "要么行不再等高，要么量到了别的滚动视图",
                      file: file, line: line)
        XCTAssertGreaterThan(r.viewportHeight, 0,
                             "\(r.label)：视口高为 0 = 压根没滚动（playbook §二·3）",
                             file: file, line: line)
        XCTAssertGreaterThan(r.scrollRange, r.viewportHeight,
                             "\(r.label)：可滚动余量必须超过一屏，否则「换选中行要滚」这件事没发生",
                             file: file, line: line)
    }

    /// 数量级护栏：钉的是 `753575d` 那种「一次布局事务吞掉整个交互」的形态，
    /// 离实测值一到两个数量级，**不是**性能基线。绝对读数只在 `[server-list raw]` 里打印。
    private func assertOrderOfMagnitude(_ arm: Arm,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertGreaterThan(arm.minBeats, 60,
                             "\(arm.label)：3 秒 8ms 心跳掉到 60 拍以下 = 主线程被一次长事务吃掉"
                             + "（实测 \(arm.minBeats) 拍，正常在几百）——数量级护栏，不是基线",
                             file: file, line: line)
        XCTAssertLessThan(arm.stepMax, 500,
                          "\(arm.label)：单次换选中行最坏 "
                          + "\(String(format: "%.0f", arm.stepMax))ms —— 超过 500ms 就是 "
                          + "753575d 那种「一次布局事务吞掉整个交互」，数量级护栏",
                          file: file, line: line)
        XCTAssertLessThan(arm.filterMax, 800,
                          "\(arm.label)：一次搜索过滤切换最坏 "
                          + "\(String(format: "%.0f", arm.filterMax))ms —— 数量级护栏",
                          file: file, line: line)
    }

    // MARK: - 用例

    /// 主探针 + 闸门：2000 台连续换选中行不得把主线程按死，也不得随规模爆 NSView。
    ///
    /// 判据全是结构 / 同轮比值：`scrollTo` 的税用**同一份 `ServerList`、只关掉
    /// `scrollsSelectionIntoView`、改由探针手滚同样距离**的归因臂当分母
    /// （分母必须干同样多的活，否则负载一来比值就翻，见文件头第三轮）。
    /// 绝对拍数与毫秒只打印。
    func testSelectionDrivenScrollToStaysResponsive() async throws {
        defer { closeAllWindows() }
        let (big, bigWithout) = try await measureInterleavedArms(rows: 2000, groups: 60)
        logRatios("2000台", with: big, without: bigWithout)
        let small = try await measure("100台/10组·跨规模对照",
                                      rows: 100, groups: 10, scrollsIntoView: true)
        log(small)

        // —— 结构判据 ——

        assertTableShape(big.first)
        assertTableShape(bigWithout.first)
        assertTableShape(small)

        // 行高跨规模必须一致：这才叫「文档高度对得上行数」，
        // 而不是「某个绝对高度」。
        XCTAssertEqual(big.first.rowHeight, small.rowHeight, accuracy: 1.0,
                       "2000 台与 100 台的行高必须一致："
                       + "\(String(format: "%.2f", small.rowHeight)) vs "
                       + "\(String(format: "%.2f", big.first.rowHeight))pt")

        // `LazyVStack` 必须真的在回收行 —— 极端档的常驻 NSView 数不该随规模涨，
        // 只允许一个小常数的漂移（§七 第四条：判「回不回收」只看扫完之后数 NSView）。
        XCTAssertLessThanOrEqual(big.first.views, small.views + Self.viewCountSlack,
                                 "2000 台的 NSView 数不该随规模涨（允许 ±\(Self.viewCountSlack)）："
                                 + "100 台 \(small.views) → 2000 台 \(big.first.views)")

        // `scrollTo` 真的把选中行送进了视口：12 个散点全中，且视口确实走过了满量程。
        // 「落定」是轮询出来的（最多等 \(Self.settleTimeout)s），不是固定等待——
        // 所以这里读到的不中一定是 `scrollTo` 没生效，不是机器慢。
        XCTAssertEqual(big.first.landed, big.first.landingProbes,
                       "2000 台：等到落定（或 \(Self.settleTimeout)s 超时）后目标行必须在视口内 —— "
                       + "12 个散点只中了 \(big.first.landed) 个、超时 "
                       + "\(big.first.settleTimeouts) 次，`scrollTo` 没把选中行送到位")
        XCTAssertGreaterThan(big.first.scrollSpan, big.first.scrollRange * 0.9,
                             "2000 台：选第一行 ⇄ 选最后一行，视口原点只走了 "
                             + "\(String(format: "%.0f", big.first.scrollSpan))pt / 满量程 "
                             + "\(String(format: "%.0f", big.first.scrollRange))pt")

        // 分母的自证：归因臂确实关掉了产品那次 `scrollTo` —— ④ 落点那一段不镜像手滚，
        // 所以视口原点纹丝不动。否则「比值」比的是两个一样的东西，闸门形同虚设。
        XCTAssertLessThan(bigWithout.first.scrollSpan, 1,
                          "归因臂的视口不该动（实测走了 "
                          + "\(String(format: "%.0f", bigWithout.first.scrollSpan))pt）——"
                          + "分母没关掉 scrollTo，这条比值闸门就是假的")

        // —— 同轮相对判据 ——

        let stepRatio = big.stepP50 / max(bigWithout.stepP50, 0.001)
        XCTAssertLessThan(stepRatio, Self.bigStepRatioCeiling,
                          "2000 台一步换选中行：带 scrollTo "
                          + "\(String(format: "%.2f", big.stepP50))ms ÷ 归因臂 "
                          + "\(String(format: "%.2f", bigWithout.stepP50))ms = "
                          + "\(String(format: "%.2f", stepRatio))×，超过 "
                          + "\(Self.bigStepRatioCeiling)× 说明 scrollTo 在 2000 行上又变贵了")

        let beatsRatio = bigWithout.beats / max(big.beats, 0.001)
        XCTAssertLessThan(beatsRatio, Self.bigBeatsRatioCeiling,
                          "2000 台心跳：归因臂 \(String(format: "%.1f", bigWithout.beats)) 拍 ÷ "
                          + "带 scrollTo \(String(format: "%.1f", big.beats)) 拍 = "
                          + "\(String(format: "%.2f", beatsRatio))×，超过 "
                          + "\(Self.bigBeatsRatioCeiling)× 说明 scrollTo 把主线程吃掉的比例变大了")

        // —— 数量级护栏（不是基线）——

        assertOrderOfMagnitude(big)
    }

    /// 真实档（100 台）的键盘换行不许退化。
    ///
    /// 这条以前钉的是绝对拍数 `> 200`，在全量套件的同机负载下读到 177 假红、
    /// 单跑同一条 214~238 判绿（见文件头）。现在钉的是**同规模两臂的比值**：
    /// 真实档上 `scrollTo` 相对「手滚同样距离」根本不收税（实测 0.88~0.98×），
    /// 一旦某个改动让它厚起来，比值立刻翻；两臂同涨同落的机器负载会被约掉。
    func testRealisticScaleSelectionStaysCheap() async throws {
        defer { closeAllWindows() }
        let (arm, without) = try await measureInterleavedArms(rows: 100, groups: 10)
        logRatios("100台", with: arm, without: without)

        // —— 结构判据 ——

        assertTableShape(arm.first)
        assertTableShape(without.first)
        XCTAssertEqual(arm.first.landed, arm.first.landingProbes,
                       "100 台：等到落定（或 \(Self.settleTimeout)s 超时）后目标行必须在视口内 —— "
                       + "12 个散点只中了 \(arm.first.landed) 个、超时 "
                       + "\(arm.first.settleTimeouts) 次")
        XCTAssertGreaterThan(arm.first.scrollSpan, arm.first.scrollRange * 0.9,
                             "100 台：选第一行 ⇄ 选最后一行，视口原点只走了 "
                             + "\(String(format: "%.0f", arm.first.scrollSpan))pt / 满量程 "
                             + "\(String(format: "%.0f", arm.first.scrollRange))pt")
        XCTAssertLessThan(without.first.scrollSpan, 1,
                          "100 台归因臂的视口不该动（实测走了 "
                          + "\(String(format: "%.0f", without.first.scrollSpan))pt）")

        // —— 同轮相对判据 ——

        let stepRatio = arm.stepP50 / max(without.stepP50, 0.001)
        XCTAssertLessThan(stepRatio, Self.smallStepRatioCeiling,
                          "100 台一步换选中行：带 scrollTo "
                          + "\(String(format: "%.2f", arm.stepP50))ms ÷ 归因臂 "
                          + "\(String(format: "%.2f", without.stepP50))ms = "
                          + "\(String(format: "%.2f", stepRatio))×，超过 "
                          + "\(Self.smallStepRatioCeiling)× = 日常规模上 scrollTo 变贵了")

        let beatsRatio = without.beats / max(arm.beats, 0.001)
        XCTAssertLessThan(beatsRatio, Self.smallBeatsRatioCeiling,
                          "100 台心跳：归因臂 \(String(format: "%.1f", without.beats)) 拍 ÷ "
                          + "带 scrollTo \(String(format: "%.1f", arm.beats)) 拍 = "
                          + "\(String(format: "%.2f", beatsRatio))×")

        // —— 数量级护栏（不是基线）——

        assertOrderOfMagnitude(arm)
    }

}

// MARK: - 驱动 / 宿主

/// 把 `selectedID` / `query` 从测试外部推进去。`ServerList` 的两个入口
/// （键盘换行、搜索过滤）都归结成这两个值的变化。
@MainActor
private final class SelectionDriver: ObservableObject {
    @Published var selectedID: UUID?
    @Published var query: String = ""
}

/// 宿主真实的 `ServerList`（不是拷贝）—— 判据要落在产品代码上。
/// 归因臂也走同一个类型，只把 `scrollsSelectionIntoView` 关掉。
private struct ServerListSelectionHarness: View {
    @ObservedObject var driver: SelectionDriver
    let profiles: [ServerProfile]
    let existingGroups: [String]
    let groupColorHexes: [String: String]
    var scrollsSelectionIntoView = true

    @State private var dragging: UUID?

    private var visible: [ServerProfile] {
        guard !driver.query.isEmpty else { return profiles }
        return profiles.filter { $0.name.localizedCaseInsensitiveContains(driver.query) }
    }

    var body: some View {
        ServerList(profiles: visible,
                   query: driver.query,
                   selectedID: $driver.selectedID,
                   draggingProfileID: $dragging,
                   onOpen: { _ in },
                   onContextAction: { _, _ in },
                   existingGroups: existingGroups,
                   groupColorHexes: groupColorHexes,
                   scrollsSelectionIntoView: scrollsSelectionIntoView)
    }
}
