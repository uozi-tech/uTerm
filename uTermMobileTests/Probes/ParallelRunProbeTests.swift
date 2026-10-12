import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 并行执行屏（`ParallelRunView`）的渲染成本探针。
///
/// 走 `MobileProbeRig`（建窗 / 心跳 / 往返 / 结构 全套一个口径），假执行器
/// `MobileFakeParallelRun` 经 `ParallelCommandExecuting` 注进**真控制器**，
/// 再经 `ParallelRunView(request:controller:onClose:)` 挂**真整屏** ——
/// `runLane` / `markUnreachable` / `finalize` 一条不少，只有 SSH 会话是假的。
///
/// ## 规模来源
///
/// - **真实档 6 台 × 600 行**：一条快捷命令绑定的服务器数（`QuickCommand.serverIDs`，
///   一次广播通常是「一个分组」量级）；行数来自 `SSHCommandExecutor(maxLines: 200)`
///   × 自愈几步。
/// - **极端档 24 台 × 1200 行**：`ParallelRunController.maxAgentSteps = 6`，每步一条
///   命令最多回 200 行 → 6 × 200 = 1200 行封顶；24 台 = 一个中型分组整批广播。
/// - **追加速率**：任务给的口径是 50 行/秒/台；这里与桌面
///   `ParallelRunScrollCostTests` 对齐成「10 秒内把该档的行数全流进来」
///   （真实档 60 行/秒、极端档 120 行/秒），于是两档的**追加期一样长**、可比。
/// - **不预置历史**：真实场景里命令刚开跑时 `lines` 是空的；预置几百行会让
///   「贴底跟随」那条判据量的不是同一件事（桌面就是这么踩过的）。
///
/// ## 闸门只用结构判据
///
/// 绝对毫秒只打印（README「每把尺怎么读」）。硬断言只有：可滚动余量 > 0、
/// `travelled` 够、心跳没被追加占死、`UIView` 数不随台数涨、展开后内容真的变高、
/// 完成态两帧像素一致（= ticker / 脉冲真的停了）。唯一的**相对计时**闸门是
/// 「跨格一跳不随每格行数涨」，它只比同一轮里的两档，写法见
/// `testCrossPaneJumpDoesNotScaleWithLinesPerPane`。
@MainActor
final class ParallelRunProbeTests: XCTestCase {

    // MARK: - 读数

    struct Reading {
        var hosts = 0
        var linesPerHost = 0
        var mountMS = 0.0
        /// 追加期 8ms 心跳实收拍数 / 理想拍数。
        var streamBeats = 0
        var idealBeats = 0
        /// 追加期每拍「布局 + CA 提交」的主线程墙钟。
        var streamP50 = 0.0
        var streamP95 = 0.0
        var streamMax = 0.0
        /// 超本机刷新率预算的比例（%）。
        var streamOverBudget = 0.0
        /// 固定 8.33ms 的比例（%），跨机器对照用。
        var streamOverStrict = 0.0
        /// 追加期结束时「离底还差多少」（pt）。跟随成立 → 0 附近；没有跟随 → 随内容一起涨。
        var tailGap = 0.0
        /// 追加刚开始时的 tail-gap —— 与 `tailGap` 一起证明「跟随到底开没开」。
        var tailGapStart = 0.0
        var contentHeight = 0.0
        var totalLines = 0
        var views = 0
        var scrollP50 = 0.0
        var scrollP95 = 0.0
        var scrollOverBudget = 0.0
        var travelled = 0.0
        var scrollable = 0.0
        /// 「翻到下一台」的一跳成本（ms）。往返扫掠钳在 3 个视口内，而极端档一格就有
        /// 两万多 pt —— 那套读数**永远跨不过一格**，跨格这一跳得单量。
        var jumpP50 = 0.0
        var jumpMax = 0.0
        /// 逐跳原始读数（先一格格往下、再一格格回来）。跨档比较时要合并几轮取中位数，
        /// 单轮七八个样本的中位数自己就能差出一倍。
        var jumps: [Double] = []
        var hitP50 = 0.0
        var ink = 0.0
        var histogram = ""
    }

    private func log(_ tag: String, _ r: Reading) {
        print(String(format: """
            [%@] hosts=%d lines/host=%d total-lines=%d mount=%.1fms \
            stream-beats=%d/%d stream-p50=%.2fms stream-p95=%.2fms stream-max=%.1fms \
            stream-over-budget=%.1f%% stream-over-8.33=%.1f%% \
            tail-gap=%.0f→%.0fpt content=%.0f \
            scroll-p50=%.2fms scroll-p95=%.2fms scroll-over=%.1f%% travelled=%.0f scrollable=%.0f \
            jump-p50=%.1fms jump-max=%.1fms hit-p50=%.1fus views=%d ink=%.4f
            """,
            tag, r.hosts, r.linesPerHost, r.totalLines, r.mountMS,
            r.streamBeats, r.idealBeats, r.streamP50, r.streamP95, r.streamMax,
            r.streamOverBudget, r.streamOverStrict,
            r.tailGapStart, r.tailGap, r.contentHeight,
            r.scrollP50, r.scrollP95, r.scrollOverBudget, r.travelled, r.scrollable,
            r.jumpP50, r.jumpMax, r.hitP50, r.views, r.ink))
        print("[\(tag)-views] \(r.histogram)")
    }

    // MARK: - 装配

    /// 一台档：真控制器 + 假执行器 + 真整屏。返回控制器与 rig，用完调用方负责收尾。
    private func makeScreen(hosts: Int, lines: Int, seconds: Double,
                            failing: Int, unreachable: Int, label: String)
        throws -> (rig: MobileProbeRig, controller: ParallelRunController, fake: MobileFakeParallelRun) {
        // 现建容器而不是 `MobileFixtures.shared`：控制器收尾时会 `recordRun()` 往库里写，
        // 共享容器只给只读用例（README「夹具跨用例契约」第 4 条）。
        let container = try MobileFixtures.modelContainer(seed: hosts > 12 ? .realistic : .smoke)
        let profiles = Array(try container.mainContext.fetch(
            FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\.sortOrder)])).prefix(hosts))
        XCTAssertEqual(profiles.count, hosts, "播种的主机不够撑这一档")

        let config = MobileFakeParallelRun.Config.streaming(
            hosts: hosts, lines: lines, seconds: seconds,
            failing: failing, unreachable: unreachable)
        let fake = MobileFakeParallelRun(config: config, targets: profiles)
        let commandID = UUID()
        let controller = ParallelRunController(
            commandID: commandID, commandName: "重启并抓日志",
            command: config.command, intent: "", aiAssisted: false,
            targets: profiles, doctor: nil,
            store: QuickCommandStore(context: container.mainContext),
            container: container, executor: fake)
        let request = ParallelRunRequest(commandID: commandID, name: "重启并抓日志",
                                         command: config.command, intent: "",
                                         aiAssisted: false, serverIDs: profiles.map(\.id))

        let rig = MobileProbeRig(label: label)
        // 注入现成的控制器 → 首帧就是内容（否则第一帧是 `ProgressView`，rig 拿不到
        // `UIScrollView`，后面所有滚动读数都无从谈起）。`start()` 由这里发。
        controller.start()
        rig.mount(ParallelRunView(request: request, controller: controller, onClose: {})
            .modelContainer(container))
        return (rig, controller, fake)
    }

    /// 当前 `UIScrollView` 离底还差多少 pt。
    private func tailGap(_ scroll: UIScrollView) -> Double {
        Double(max(0, scroll.contentSize.height - scroll.bounds.height - scroll.contentOffset.y))
    }

    // MARK: - Shell：追加期 + 落定后的往返

    private func measureShell(hosts: Int, lines: Int, seconds: Double = 10,
                              label: String) async throws -> Reading {
        let (rig, controller, _) = try makeScreen(hosts: hosts, lines: lines, seconds: seconds,
                                                  failing: max(1, hosts / 6), unreachable: 1,
                                                  label: label)
        var r = Reading(hosts: hosts, linesPerHost: lines, mountMS: rig.mountMS)
        let scroll = try rig.requireScrollView()

        // ── 追加期：8ms 心跳，每拍逼一次布局 + CA 提交并记账。
        var frames: [Double] = []
        var beats = 0
        let budget = MobileProbeWindow.frameBudgetMS()
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            try await Task.sleep(for: .milliseconds(8))
            beats += 1
            let start = CFAbsoluteTimeGetCurrent()
            rig.layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if beats == 12 { r.tailGapStart = tailGap(scroll) }
        }
        r.streamBeats = beats
        r.idealBeats = Int(seconds / 0.008)
        r.streamP50 = ProbeMetrics.percentile(frames, 0.5)
        r.streamP95 = ProbeMetrics.percentile(frames, 0.95)
        r.streamMax = frames.max() ?? 0
        r.streamOverBudget = Double(frames.filter { $0 > budget }.count)
            / Double(max(1, frames.count)) * 100
        r.streamOverStrict = Double(frames.filter { $0 > ProbeBudget.strictMS }.count)
            / Double(max(1, frames.count)) * 100

        // 跟随是否成立：追加停下来之后再看一眼「离底还差多少」。
        try await Task.sleep(for: .milliseconds(400))
        rig.layout()
        r.tailGap = tailGap(scroll)

        // ── 全部落定（用户真正会去翻输出的时刻）再量往返。
        for _ in 0..<40 where !controller.allDone {
            try await Task.sleep(for: .milliseconds(100))
        }
        rig.layout()
        r.totalLines = controller.states.reduce(0) { $0 + $1.lines.count }
        r.contentHeight = Double(scroll.contentSize.height)

        let reading = try await rig.measureScroll()
        r.scrollP50 = reading.p50
        r.scrollP95 = reading.p95
        r.scrollOverBudget = reading.overBudgetPct
        r.travelled = Double(reading.travelled)
        r.scrollable = Double(reading.scrollable)

        // ── 跨格跳转：一格一格往下翻（每格 = 一台的输出）。
        // 这是这一屏真正贵的动作 —— 往返扫掠钳在 3 个视口内，极端档一格两万多 pt，
        // 那套读数**从头到尾都在同一格里**，跨格的账它一次都没量到。
        var jumps: [Double] = []
        let paneHeight = Double(scroll.contentSize.height) / Double(max(1, hosts))
        rig.scrollTo(0)
        rig.layout()
        try await Task.sleep(for: .milliseconds(200))
        // 先往下一格格翻，再原路翻回来：样本翻倍，且回程落的是已经建过一次的格子，
        // 两种跳都量到。
        let reach = min(8, hosts - 1)
        for k in Array(1...reach) + Array((0..<reach).reversed()) {
            let start = CFAbsoluteTimeGetCurrent()
            rig.scrollTo(CGFloat(paneHeight * Double(k)))
            rig.layout()
            jumps.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(120))
        }
        r.jumps = jumps
        r.jumpP50 = ProbeMetrics.percentile(jumps, 0.5)
        r.jumpMax = jumps.max() ?? 0
        print("[\(label)-jumps] " + jumps.map { String(format: "%.1f", $0) }.joined(separator: " "))

        let shot = await rig.snapshot()
        r.views = shot.views
        r.hitP50 = shot.hitP50
        r.ink = shot.ink
        r.histogram = shot.histogram
        rig.report(reading, shot)
        attachProbePNG(shot.png, name: label)

        controller.cancel()
        await rig.close()
        return r
    }

    /// **翻到下一台的一跳不随「每格多少行」涨** —— 内层那叠输出行必须是懒建的。
    ///
    /// 内层非懒的话，落进新的一格要把整格的行都建出来，成本正比于每格行数
    /// （改懒栈前实测 600 行 161.4ms、1200 行 316.2ms，约 0.26ms/行）；懒栈只建视野内
    /// 那几十行，与每格多少行无关。
    ///
    /// 这条原先挂在主用例里，拿「6 台 × 600 行」对「24 台 × 1200 行」的单轮中位数比，
    /// 闸门 1.6。iOS 27 上它成了假红，原因有两个，都与内层懒不懒无关：
    ///
    /// - 两档**同时差着台数**。台数固定成 8 之后，每格 300 / 1200 / 2400 行的一跳都落在
    ///   20–45ms，看不出随行数涨；外层那叠格子多了才是变贵的来源。
    /// - **单轮中位数自己就飘一倍**。同一档连跑两轮是 44.8 对 20.5ms（各 7 个样本），
    ///   原判据在基线提交上的比值是 0.91–3.22。
    ///
    /// 所以改成：台数固定 8，只差每格行数，而且差 8 倍（300 对 2400）而不是 2 倍；
    /// 轻重两档按 轻-重-重-轻 各跑两轮抵掉先后顺序，每档合并 28 个样本取中位数。
    /// 懒的时候比值在 1 上下（四轮实测 0.70 / 1.23 / 1.67 / 1.34）；把内层临时换回 `VStack`
    /// 反向自证，比值是 20.18（35.8 → 723.0ms）。闸门放在 3，两边都留了余量。
    func testCrossPaneJumpDoesNotScaleWithLinesPerPane() async throws {
        defer { MobileProbeWindow.closeAll() }

        var light: [Double] = []
        var heavy: [Double] = []
        for (round, lines) in [300, 2400, 2400, 300].enumerated() {
            let reading = try await measureShell(hosts: 8, lines: lines, seconds: 4,
                                                 label: "par-jump-8x\(lines)-\(round)")
            XCTAssertGreaterThan(reading.totalLines, 8 * lines / 2, "8 台 × \(lines) 行没流够，这一档没在量")
            XCTAssertFalse(reading.jumps.isEmpty, "一跳都没量到")
            if lines == 300 { light += reading.jumps } else { heavy += reading.jumps }
        }
        let lightP50 = ProbeMetrics.percentile(light, 0.5)
        let heavyP50 = ProbeMetrics.percentile(heavy, 0.5)
        print(String(format: "[par-jump] 8 台，每格行数 300→2400，跨格一跳 p50 %.1f→%.1fms（比值 %.2f，各 %d 个样本）",
                     lightP50, heavyP50, heavyP50 / max(0.001, lightP50), light.count))
        XCTAssertLessThan(heavyP50, lightP50 * 3,
                          "跨格跳转成本随每格行数线性涨 = 某一格的行不再是懒建的")
    }

    /// 主用例：真实档 + 极端档各量一次。
    func testShellStreamingAndScroll() async throws {
        defer { MobileProbeWindow.closeAll() }

        let real = try await measureShell(hosts: 6, lines: 600, label: "par-shell-6x600")
        log("par-shell", real)
        let extreme = try await measureShell(hosts: 24, lines: 1200, label: "par-shell-24x1200")
        log("par-shell", extreme)

        // ① 这两档真的滚得动 —— 不然下面所有读数都是「静止画面」。
        XCTAssertGreaterThan(real.scrollable, 0)
        XCTAssertGreaterThan(extreme.scrollable, 0)
        XCTAssertGreaterThan(real.travelled, 700, "驱动没把列表推动")
        XCTAssertGreaterThan(extreme.travelled, 700, "驱动没把列表推动")

        // ② 输出真的流进来了（假执行器经协议接回了控制器）。
        XCTAssertGreaterThan(real.totalLines, 6 * 400, "6 台 × 600 行没流够")
        XCTAssertGreaterThan(extreme.totalLines, 24 * 800, "24 台 × 1200 行没流够")

        // ③ 主线程没被追加占死。
        XCTAssertGreaterThan(real.streamBeats, real.idealBeats / 8,
                             "真实档追加期心跳掉到 1/8 以下 = 主线程被追加占死")
        XCTAssertGreaterThan(extreme.streamBeats, extreme.idealBeats / 16,
                             "极端档追加期心跳掉到 1/16 以下 = 主线程被追加占死")

        // ④ `UIView` 数不随台数涨（纯 `Text` 的懒栈在 iOS 上恒个位数，README 基线 6）。
        //    这一条是判 B/C 的第一判据：每行一个 Button/TextField 才会让它跟着涨。
        XCTAssertLessThan(extreme.views, real.views + 24,
                          "视图数随台数线性涨 = 每台在建真控件，得按 B/C 处方改")

        // ⑤ 跨格一跳这里只记账，判据在 `testCrossPaneJumpDoesNotScaleWithLinesPerPane`：
        //    这两档同时差着台数（6 对 24）和每格行数，比值说明不了内层懒不懒。
        print(String(format: "[par-shell-jump] 6 台×600 行 / 24 台×1200 行，跨格一跳 p50 %.1f / %.1fms",
                     real.jumpP50, extreme.jumpP50))

        // ⑥ **贴底跟随**：移动端这一屏整个没有跟随（无 `ScrollViewReader` / 无
        //    `defaultScrollAnchor`，见 `shellBody`），所以 gap 只会随内容一起长。
        //    这条断言把「没有跟随」钉成事实：不是量错了，是产品就没有这条路。
        //    真加了跟随之后它会红 —— 那时把断言翻成 `< 200`（桌面口径）。
        XCTAssertGreaterThan(extreme.tailGap, extreme.tailGapStart,
                             "gap 没随内容涨 = 要么跟随已经存在了，要么这一档根本没在追加")
        print(String(format: "[par-shell-follow] 真实档 gap %.0f→%.0fpt，极端档 %.0f→%.0fpt "
                     + "（移动端 shellBody 无贴底跟随，桌面 ParallelShellGrid 有）",
                     real.tailGapStart, real.tailGap, extreme.tailGapStart, extreme.tailGap))
    }

    // MARK: - AI 泳道展开成本

    /// 造一批「已收尾、带 6 步处理过程」的泳道 —— `PServerState` 的字段都是 `var`，
    /// 直接构造比跑一遍假 Agent 便宜且确定。
    private func resolvedLanes(_ n: Int) -> [PServerState] {
        (0..<n).map { i in
            var s = PServerState(id: UUID(), name: "web-\(String(format: "%02d", i + 1))",
                                 endpoint: "ops@10.0.0.\(i + 1):22",
                                 endpointDisplay: "ops@10.0.0.\(i + 1)")
            let failed = i % 5 == 4
            s.status = failed ? .failed : .succeeded
            s.tone = failed ? .failed : .ok
            s.exitCode = failed ? 1 : 0
            s.durationMs = 900 + i * 37
            s.summary = failed
                ? "apt 锁被占用，更新未完成；已回滚到更新前状态，建议稍后复核 /var/log/apt/term.log 再重试。"
                : "已更新软件包并重启 app.service，健康检查返回 200，目标达成。"
            // maxAgentSteps = 6：一台最多 6 步。
            s.steps = (0..<6).map { k in
                "执行 检查并修复第 \(k + 1) 步（systemctl status app --no-pager -l）→ 退出码 \(k == 3 ? 1 : 0)"
            }
            return s
        }
    }

    private func measureAILanes(_ states: [PServerState], open: Bool, label: String)
        async throws -> Reading {
        let rig = MobileProbeRig(label: label)
        var r = Reading(hosts: states.count, linesPerHost: 6)
        r.mountMS = rig.mount(
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(states) { s in ParAILane(state: s, initiallyOpen: open) {} }
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(M.bg))

        let reading = try await rig.measureScroll()
        let shot = await rig.snapshot()
        r.scrollP50 = reading.p50
        r.scrollP95 = reading.p95
        r.scrollOverBudget = reading.overBudgetPct
        r.travelled = Double(reading.travelled)
        r.scrollable = Double(reading.scrollable)
        r.contentHeight = Double(reading.contentHeight)
        r.views = shot.views
        r.hitP50 = shot.hitP50
        r.ink = shot.ink
        r.histogram = shot.histogram
        rig.report(reading, shot)
        await rig.close()
        return r
    }

    /// AI 泳道「查看处理过程」展开的账：收起 vs 展开，同一批泳道同轮对照。
    func testAILaneExpansionCost() async throws {
        defer { MobileProbeWindow.closeAll() }

        let lanes = resolvedLanes(24)
        let collapsed = try await measureAILanes(lanes, open: false, label: "par-ai-24-collapsed")
        log("par-ai", collapsed)
        let expanded = try await measureAILanes(lanes, open: true, label: "par-ai-24-expanded")
        log("par-ai", expanded)

        // ① 展开真的发生了（内容更高）—— 不成立的话下面比的是同一件事。
        XCTAssertGreaterThan(expanded.contentHeight, collapsed.contentHeight * 1.2,
                             "展开后内容没变高：`initiallyOpen` 没生效，这一轮对照作废")
        // ② 两档都滚得动。
        XCTAssertGreaterThan(collapsed.scrollable, 0)
        XCTAssertGreaterThan(expanded.scrollable, 0)
        XCTAssertGreaterThan(expanded.travelled, 700)
        // ③ 展开不该把视图树撑成「每步一个控件」。步骤行是纯 Text + Circle，
        //    `UIView` 数应当基本不动（README 基线：纯 Text 懒栈恒 6）。
        XCTAssertLessThan(expanded.views, collapsed.views + 24,
                          "展开后视图数跟着步数涨 = 每步在建真控件")
        print(String(format: "[par-ai-expand] content %.0f→%.0fpt views %d→%d p50 %.2f→%.2fms",
                     collapsed.contentHeight, expanded.contentHeight,
                     collapsed.views, expanded.views, collapsed.scrollP50, expanded.scrollP50))
    }

    // MARK: - ticker / MDot 脉冲只在运行中的行跑

    /// 0.5s `ticker`（`ParallelRunView.onReceive`）与 `MDot(pulse:)` 的
    /// `repeatForever` 都应当**只在还有行在跑的时候**动。
    ///
    /// 判据是像素：同一屏隔 1.2 秒截两张。
    /// - 运行态（**对照组**）：两张必须**不同** —— 证明这套判法看得见「屏幕在动」。
    ///   为了让差异只来自脉冲与秒表，这一档配成 60 秒才吐 4 行（1.2 秒窗口里一行都不会来）。
    /// - 完成态：两张必须**逐字节相同** —— ticker 被 `allDone` 门住、`MDot` 的
    ///   `if pulse` 把带 `repeatForever` 的那一层整个撤掉了。
    func testTickerAndPulseOnlyRunWhileRunning() async throws {
        defer { MobileProbeWindow.closeAll() }

        // ── 对照组：运行中，但这 1.2 秒里没有新行。
        let running = try makeScreen(hosts: 4, lines: 4, seconds: 60,
                                     failing: 0, unreachable: 0, label: "par-ticker-running")
        try await Task.sleep(for: .milliseconds(300))
        let runA = running.rig.capturePNG()
        try await Task.sleep(for: .milliseconds(1200))
        let runB = running.rig.capturePNG()
        let linesDuringWindow = running.controller.states.reduce(0) { $0 + $1.lines.count }
        running.controller.cancel()
        await running.rig.close()
        XCTAssertEqual(linesDuringWindow, 4, "这一档不该在窗口里吐行（每台只有首行 cmd）")
        XCTAssertNotNil(runA)
        XCTAssertNotEqual(runA, runB,
                          "运行态两帧一模一样 = 这套像素判法看不见变化，下面的「完成态相同」就没有意义")

        // ── 完成态：全部落定之后不该再有任何东西在动。
        let done = try makeScreen(hosts: 4, lines: 40, seconds: 1,
                                  failing: 1, unreachable: 0, label: "par-ticker-done")
        for _ in 0..<60 where !done.controller.allDone {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(done.controller.allDone, "假执行器没把这一档跑完")
        try await Task.sleep(for: .milliseconds(600))
        done.rig.layout()
        let doneA = done.rig.capturePNG()
        try await Task.sleep(for: .milliseconds(1200))
        let doneB = done.rig.capturePNG()
        done.controller.cancel()
        await done.rig.close()

        XCTAssertNotNil(doneA)
        XCTAssertEqual(doneA, doneB,
                       "完成态两帧不同 = ticker 或 MDot 脉冲还在跑（应当只在运行中的行上跑）")
        print("[par-ticker] 运行态两帧不同（\(runA?.count ?? 0) vs \(runB?.count ?? 0) 字节）、"
              + "完成态两帧一致（\(doneA?.count ?? 0) 字节）")
    }
}
