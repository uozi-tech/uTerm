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
/// | 连 `scrollTo` 一起去掉（归因臂） | **6.59ms** | **9.16ms** | **11ms** | **333** | 39 |
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
///    它逼 `LazyVStack` 解析 2000 行的目标偏移，35ms vs 归因臂的 6.6ms。
///
/// 所以动画留着（键盘导航的设计语义），闸门改成钉**后果**而不是钉形态：
/// 心跳拍数、单步不得出现 500ms 级长事务、NSView 不随规模涨、真实档 p95 有上限。
/// 遗留项：`scrollTo` 那 35ms 没动，见 `docs/scroll-perf-findings.md`。
///
/// ## 规模来源
///
/// 与 `WelcomeServerListCostTests` 同源：真实档 100 台 / 10 组，极端档
/// 2000 台 / 60 组（`~/.ssh/config` 批量导入是产品功能；Tweaks 那个 50 台的钳
/// 是调试旋钮上限，不是数据上限）。
@MainActor
final class ServerListSelectionScrollProbeTests: XCTestCase {

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
        var mountMS = 0.0
        /// 3 秒 8ms 心跳实际收到的拍数（理想 375）。每一拍都换一次选中行。
        var beats = 0
        /// 一次「换选中行 + 布局」的耗时分布。
        var stepP50 = 0.0
        var stepP95 = 0.0
        var stepMax = 0.0
        var overBudget = 0.0
        /// 一次「切换搜索过滤 + 布局」的最坏耗时。
        var filterMax = 0.0
        var views = 0
        var histogram = ""
        var docHeight = 0.0
    }

    private func log(_ r: Reading) {
        print(String(format: """
            [serverlist-scrollto] %@ rows=%d mount=%.1fms beats=%d \
            step p50=%.2fms p95=%.2fms max=%.1fms over8.33=%.1f%% \
            filterMax=%.1fms views=%d docH=%.0f
            """,
            r.label, r.rows, r.mountMS, r.beats,
            r.stepP50, r.stepP95, r.stepMax, r.overBudget,
            r.filterMax, r.views, r.docHeight))
        print("[serverlist-scrollto]   \(r.label) 类名直方图：\(r.histogram)")
    }

    // MARK: - 量

    private func measure(_ label: String, rows: Int, groups: Int) async throws -> Reading {
        let profiles = WelcomeServerListCostTests.makeProfiles(count: rows, groups: groups)
        let driver = SelectionDriver()
        driver.selectedID = profiles.first?.id
        let harness = ServerListSelectionHarness(
            driver: driver,
            profiles: profiles,
            existingGroups: WelcomeServerListCostTests.groupNames(groups),
            groupColorHexes: WelcomeServerListCostTests.groupColorHexes(groups))
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

        var r = Reading(label: label, rows: rows)
        let t0 = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        r.mountMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        XCTAssertTrue(ProbeWindow.blindsRealMouse(window),
                      "透明屏内档必须谎报鼠标位置，否则用户光标会点亮 .onHover")

        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        try await Task.sleep(for: .milliseconds(250))
        layout()
        if let scroll = host.firstScrollView(), let doc = scroll.documentView {
            r.docHeight = Double(doc.frame.height)
        }

        // ① 心跳：3 秒里每 8ms 换一次选中行（= 用户按住 ↓ 不放）。
        //    主线程要是被一次 3s 的布局事务吃掉，拍数会掉到个位数。
        let heartbeatStart = Date()
        var cursor = 0
        while Date().timeIntervalSince(heartbeatStart) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            cursor = (cursor + 1) % profiles.count
            driver.selectedID = profiles[cursor].id
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
            layout()
            filters.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(16))
        }
        driver.query = ""
        layout()
        r.filterMax = filters.max() ?? 0

        r.views = WelcomeServerListCostTests.viewCount(in: host)
        r.histogram = WelcomeServerListCostTests.classHistogram(in: host)
        await closeWindows()
        return r
    }

    // MARK: - 用例

    /// 主探针 + 闸门：2000 台连续换选中行不得把主线程按死，也不得随规模爆 NSView。
    func testSelectionDrivenScrollToStaysResponsive() async throws {
        defer { closeAllWindows() }
        let small = try await measure("100台/10组", rows: 100, groups: 10)
        log(small)
        let big = try await measure("2000台/60组", rows: 2000, groups: 60)
        log(big)

        // 心跳：8ms 一拍、3 秒理想 375 拍。掉到 60 以下 = 主线程被一次长事务吃掉
        // （753575d 那次是 3s 一个事务，拍数会掉到个位数）。
        XCTAssertGreaterThan(big.beats, 60,
                             "2000 台连续换选中行：3 秒 8ms 心跳掉到 60 拍以下 = 主线程被占死"
                             + "（实测 \(big.beats) 拍）")
        XCTAssertGreaterThan(small.beats, 60, "100 台档心跳也不该掉（实测 \(small.beats) 拍）")

        // 卡死判据：任何一次「换选中行 + 布局」不得超过 500ms。
        // 753575d 的形态是单次事务 3s+，这条闸门是它的直接钉子。
        XCTAssertLessThan(big.stepMax, 500,
                          "单次换选中行最坏 \(String(format: "%.0f", big.stepMax))ms —— "
                          + "超过 500ms 就是 753575d 那种「一次布局事务吞掉整个交互」")
        XCTAssertLessThan(big.filterMax, 800,
                          "一次搜索过滤切换最坏 \(String(format: "%.0f", big.filterMax))ms")

        // 结构判据：`LazyVStack` 必须真的在回收行 —— 极端档的常驻 NSView 数
        // 不该是真实档的 4 倍以上（§七 第四条：判「回不回收」只看扫完之后数 NSView）。
        XCTAssertLessThan(big.views, small.views * 4,
                          "2000 台的 NSView 数不该是 100 台的 4 倍以上：\(small.views) → \(big.views)")

        // 量的确实是那张长表。
        XCTAssertGreaterThan(big.docHeight, 2000 * 30.0,
                             "2000 行的文档高度必须与 2000 × 行高同量级（否则量错了滚动视图）")
    }

    /// 真实档（100 台）的键盘换行必须留在可交互预算里 —— 这条是「日常规模不许
    /// 退化」的钉子：改前实测 p50 6.2ms / p95 9.0ms，门槛留够噪声余量。
    func testRealisticScaleSelectionStaysCheap() async throws {
        defer { closeAllWindows() }
        let r = try await measure("100台/10组·真实档", rows: 100, groups: 10)
        log(r)
        XCTAssertGreaterThan(r.beats, 200,
                             "100 台档 3 秒 8ms 心跳只有 \(r.beats) 拍（实测基线 324~334）")
        XCTAssertLessThan(r.stepP95, 25,
                          "100 台换选中行 p95 \(String(format: "%.1f", r.stepP95))ms —— "
                          + "实测基线 9ms 上下，超过 25ms 说明行或 scrollTo 又变贵了")
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
private struct ServerListSelectionHarness: View {
    @ObservedObject var driver: SelectionDriver
    let profiles: [ServerProfile]
    let existingGroups: [String]
    let groupColorHexes: [String: String]

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
                   groupColorHexes: groupColorHexes)
    }
}
