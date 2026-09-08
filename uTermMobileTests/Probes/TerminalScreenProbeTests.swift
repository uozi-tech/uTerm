import SwiftUI
import SwiftData
import UIKit
import XCTest
@testable import uTermMobile

/// 终端屏（`TerminalScreen` / `TerminalSessionBody` / `SessionTabBar` / `TerminalKeyBar`）的评估探针。
///
/// ## 规模从哪来
///
/// - **输出速率**：60 行/秒 = 交互式 shell 的正常量（`tail -f` 跟一条中等流量日志）；
///   2000 行/秒 = `yes` / `cat 大文件` 级别的洪水，80 列 ≈ 160KB/s，与真实 SSH 在
///   内网被 PTY 流控压住的量级同阶。两档都跑满 10 秒。
/// - **会话数**：1 / 4 / 8。`TerminalScreen` 对同一台主机默认去重（`openTab` 里
///   `allowDuplicate` 才会重开），但「新建终端」是显式 `allowDuplicate: true`，
///   所以会话数只受用户手指限制；8 个是手机上还算合理的上界。
///
/// ## 为什么不用 `measureScroll`
///
/// 终端屏没有「列表」。SwiftTerm 的 `TerminalView` 虽然是 `UIScrollView` 子类，
/// 但刚连上时 `contentSize == bounds`，`requireScrollable()` 会（正确地）判红。
/// 换成 `MobileTerminalLoad.measure`：同一个窗口里同时收心跳、单帧、CPU 三样，
/// 口径与 `MobileProbeRig.heartbeat` / `measureScroll` 对齐。
///
/// **闸门只用结构判据与同轮相对比，绝对毫秒只打印。**
@MainActor
final class TerminalScreenProbeTests: XCTestCase {

    // MARK: - 共用夹具

    private func container() throws -> ModelContainer {
        // 主机只需要几台（会话数才是规模），但要是**真的** `ServerProfile`：
        // 控制器 `start()` 会写 `lastConnectedAt` 并 `save()`。写入 → 不能用 shared。
        try MobileFixtures.modelContainer(seed: .smoke)
    }

    private func hosts(_ c: ModelContainer, _ n: Int) -> [ServerProfile] {
        let all = (try? c.mainContext.fetch(
            FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\ServerProfile.sortOrder)]))) ?? []
        return Array(all.prefix(max(1, n)))
    }

    /// 单会话主体：`TerminalSessionBody` 就是 `TerminalScreen` 里 `ForEach` 的那一片
    ///（Agent 层 + 终端层 + 键盘条），单独挂它就是「一个会话的全部代价」。
    private func sessionBody(_ tab: TermTab, container: ModelContainer,
                             store: MobileStore) -> some View {
        TerminalSessionBody(tab: tab, isActive: true, onClose: {})
            .environment(store)
            .environment(\.mAccent, M.accent)
            .modelContainer(container)
    }

    /// 整屏：`TerminalScreen` 吃一个已经填好会话的 `TerminalSessions`。
    private func screen(_ sessions: TerminalSessions, container: ModelContainer,
                        store: MobileStore, relay: HostKeyChallengeRelay) -> some View {
        TerminalScreen()
            .environment(store)
            .environment(relay)
            .environment(sessions)
            .environment(\.mAccent, M.accent)
            .modelContainer(container)
    }

    // MARK: - 尺一：单会话在输出压力下的心跳 / 单帧 / CPU

    /// 真实档：60 行/秒 × 10 秒。
    func testSingleSessionOutput60LinesPerSecond() async throws {
        try await runSingleSessionLoad(label: "term-1x60", linesPerSecond: 60)
    }

    /// 极端档：2000 行/秒 × 10 秒（`yes` / `cat 大文件`）。
    func testSingleSessionOutput2000LinesPerSecond() async throws {
        try await runSingleSessionLoad(label: "term-1x2000", linesPerSecond: 2000)
    }

    private func runSingleSessionLoad(label: String, linesPerSecond: Double) async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try container()
        let store = MobileStore()
        let relay = HostKeyChallengeRelay()
        let host = try XCTUnwrap(hosts(c, 1).first)

        // 脚本比量测窗口长一点，保证整个 10 秒都在吐。
        let script = MobileFakeTerminalScript(linesPerSecond: linesPerSecond, seconds: 14)
        let (tab, handles) = MobileFakeTerminal.tab(host: host, script)

        let rig = MobileProbeRig(label: label)
        rig.mount(sessionBody(tab, container: c, store: store))
        tab.controller.start(profile: host, container: c, relay: relay)
        let probeOK0 = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(probeOK0, "假传输应当连上：state=\(tab.controller.state)")

        let before = MobileTerminalConsumption.read(tab.controller)
        let reading = try await MobileTerminalLoad.measure(rig, seconds: 10)
        let after = MobileTerminalConsumption.read(tab.controller)

        let shot = await rig.snapshot()
        let ledger = await handles.latest!.ledger
        rig.report(nil, shot, nil)
        MobileTerminalLoad.report(label, reading)
        print(String(format: "[%@-io] emitted=%d lines / %d bytes  consumed(advance)=%d  view-rows=%d",
                     label, ledger.linesEmitted, ledger.bytesEmitted,
                     after.advanced - before.advanced, after.topRow))
        attachProbePNG(shot.png, name: label)

        // 闸门：结构判据。
        XCTAssertGreaterThan(ledger.linesEmitted, Int(linesPerSecond * 5),
                             "脚本没吐够——节拍或连接坏了，后面所有读数都是假的")
        XCTAssertGreaterThan(after.advanced, before.advanced,
                             "终端没有消费任何输出——feed 链路断了")
        XCTAssertGreaterThan(shot.ink, 0.005, "截图是空壳")
        XCTAssertGreaterThan(reading.displayRatio, 0.1, "渲染循环没在交付帧——窗口没真上屏")
        await rig.close()
    }

    // MARK: - 尺二：N 个会话「全部常驻挂载」的代价

    /// 1 / 4 / 8 个会话同时挂载：`UIView` 数、挂载耗时、切 tab 耗时。
    ///
    /// `TerminalScreen.sessionContainer` 是 `ZStack { ForEach(tabs) { TerminalSessionBody } }` ——
    /// 每片 = 一个 SwiftTerm `TerminalView` + 一个完整 `MobileAgentChat` + 一条键盘条，
    /// **全部常驻**（非活动片只是 `opacity(0)` + 移出屏外）。这一条就是量它的账。
    func testResidentSessionsScaling() async throws {
        defer { MobileProbeWindow.closeAll() }
        var rows: [(n: Int, mount: Double, views: Int, hitP50: Double,
                    switchP50: Double, switchP95: Double, footprint: Double)] = []

        for n in [1, 4, 8] {
            let c = try container()
            let store = MobileStore()
            let relay = HostKeyChallengeRelay()
            // 每个会话一台不同的主机：`openTab` 的去重逻辑不参与（我们直接塞 tabs），
            // 但主机名长短不同才让标签片的排版成本进账。
            let hs = hosts(c, n)
            let (sessions, _) = MobileFakeTerminal.sessions(
                count: n, hosts: hs, script: .idle, container: c, relay: relay)
            for tab in sessions.tabs {
                _ = await MobileFakeTerminal.waitUntilConnected(tab.controller)
            }

            let label = "term-resident-\(n)"
            let rig = MobileProbeRig(label: label)
            let mount = rig.mount(screen(sessions, container: c, store: store, relay: relay))
            // ZStack 里的片是懒建的吗？逼一轮布局 + 提交后再数。
            rig.layout()

            // 切 tab：把 activeID 轮着换一遍，每次量 layout + CA 提交的墙钟。
            var switches: [Double] = []
            let ids = sessions.tabs.map(\.id)
            if ids.count > 1 {
                for round in 0..<(ids.count * 3) {
                    let target = ids[round % ids.count]
                    let t0 = CFAbsoluteTimeGetCurrent()
                    sessions.activeID = target
                    rig.layout()
                    switches.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    try await Task.sleep(for: .milliseconds(16))
                }
            }

            let shot = await rig.snapshot()
            rig.report(nil, shot, nil)
            print(String(format: "[%@-switch] n=%d samples=%d p50=%.3fms p95=%.3fms max=%.3fms",
                         label, n, switches.count,
                         ProbeMetrics.percentile(switches, 0.50),
                         ProbeMetrics.percentile(switches, 0.95),
                         switches.max() ?? 0))
            attachProbePNG(shot.png, name: label)
            rows.append((n, mount, shot.views, shot.hitP50,
                         ProbeMetrics.percentile(switches, 0.50),
                         ProbeMetrics.percentile(switches, 0.95),
                         shot.footprintMB))
            await rig.close()
            MobileProbeWindow.closeAll()
        }

        print("[term-resident-table] n | mount ms | views | hit p50 us | switch p50 | switch p95 | footprint MB")
        for r in rows {
            print(String(format: "[term-resident-table] %d | %.2f | %d | %.1f | %.3f | %.3f | %.1f",
                         r.n, r.mount, r.views, r.hitP50, r.switchP50, r.switchP95, r.footprint))
        }

        // 闸门：结构判据 —— `UIView` 数**随会话数涨**就是「全部常驻」的直接证据。
        // 这里不设「不许涨」的门槛（涨是现状，也是这条探针要记录的事实），
        // 只钉住「确实随规模涨」这个判据本身有效：1 → 8 必须严格增加，
        // 否则说明片根本没挂上（后面所有读数作废）。
        let v1 = rows.first { $0.n == 1 }!.views
        let v8 = rows.first { $0.n == 8 }!.views
        XCTAssertGreaterThan(v8, v1, "8 个会话的 UIView 数不比 1 个多——片没有真的挂上")
        // hitTest 不该随会话数崩：非活动片 `allowsHitTesting(false)`，命中路径应当稳定。
        let h1 = rows.first { $0.n == 1 }!.hitP50
        let h8 = rows.first { $0.n == 8 }!.hitP50
        XCTAssertLessThan(h8, max(h1 * 6, 60), "hitTest 随会话数明显劣化：\(h1)µs → \(h8)µs")
    }

    // MARK: - 尺三：非活动 tab 还在不在消费输出

    /// 4 个会话全部以 2000 行/秒吐 —— 只有一个是激活标签。
    ///
    /// 判据是**消费计数**（SwiftTerm 的 scroll-invariant 顶行号 + 光标行，随 `feed`
    /// 单调推进）：非活动片的推进量若与激活片同阶，就说明「切走的会话仍在全量渲染」。
    func testInactiveTabsStillConsumeOutput() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try container()
        let store = MobileStore()
        let relay = HostKeyChallengeRelay()
        let n = 4
        let script = MobileFakeTerminalScript(linesPerSecond: 2000, seconds: 12)
        let (sessions, handles) = MobileFakeTerminal.sessions(
            count: n, hosts: hosts(c, n), script: script, container: c, relay: relay)
        for tab in sessions.tabs { _ = await MobileFakeTerminal.waitUntilConnected(tab.controller) }

        let label = "term-inactive-4x2000"
        let rig = MobileProbeRig(label: label)
        rig.mount(screen(sessions, container: c, store: store, relay: relay))
        rig.layout()

        let before = MobileTerminalConsumption.read(sessions.tabs)
        let reading = try await MobileTerminalLoad.measure(rig, seconds: 8)
        let after = MobileTerminalConsumption.read(sessions.tabs)

        let shot = await rig.snapshot()
        rig.report(nil, shot, nil)
        MobileTerminalLoad.report(label, reading)

        var advances: [Int] = []
        for i in 0..<n {
            let adv = after[i].advanced - before[i].advanced
            advances.append(adv)
            let emitted = await handles[i].latest!.ledger.linesEmitted
            print(String(format: "[%@-tab%d] active=%@ emitted=%d consumed-advance=%d",
                         label, i, sessions.tabs[i].id == sessions.activeID ? "yes" : "NO",
                         emitted, adv))
        }
        let activeAdvance = advances[0]
        let inactiveAvg = advances.dropFirst().reduce(0, +) / max(1, n - 1)
        let ratio = activeAdvance == 0 ? 0 : Double(inactiveAvg) / Double(activeAdvance)
        print(String(format: "[%@-verdict] active=%d inactive-avg=%d ratio=%.2f",
                     label, activeAdvance, inactiveAvg, ratio))

        XCTAssertGreaterThan(activeAdvance, 0, "激活会话都没消费输出——链路坏了")
        XCTAssertGreaterThan(shot.ink, 0.005, "截图是空壳")
        await rig.close()
    }

    /// 同轮对照：**只有一个**会话吐 vs **四个都吐**（会话数相同，只有吐的数量不同）。
    /// 两档之差就是「非活动片消费输出」实际要付的主线程账。
    func testInactiveTabOutputCostAB() async throws {
        defer { MobileProbeWindow.closeAll() }

        func run(_ label: String, flooding: Int) async throws -> MobileTerminalLoad.Reading {
            let c = try container()
            let store = MobileStore()
            let relay = HostKeyChallengeRelay()
            let n = 4
            let hs = hosts(c, n)
            let sessions = TerminalSessions()
            for i in 0..<n {
                let script = i < flooding
                    ? MobileFakeTerminalScript(linesPerSecond: 2000, seconds: 12)
                    : MobileFakeTerminalScript.idle
                let (tab, _) = MobileFakeTerminal.tab(host: hs[i % hs.count], script)
                tab.controller.start(profile: hs[i % hs.count], container: c, relay: relay)
                sessions.tabs.append(tab)
            }
            sessions.activeID = sessions.tabs.first?.id
            for tab in sessions.tabs { _ = await MobileFakeTerminal.waitUntilConnected(tab.controller) }

            let rig = MobileProbeRig(label: label)
            rig.mount(screen(sessions, container: c, store: store, relay: relay))
            rig.layout()
            let reading = try await MobileTerminalLoad.measure(rig, seconds: 8)
            let shot = await rig.snapshot()
            rig.report(nil, shot, nil)
            MobileTerminalLoad.report(label, reading)
            XCTAssertGreaterThan(shot.ink, 0.005, "截图是空壳")
            await rig.close()
            MobileProbeWindow.closeAll()
            return reading
        }

        let one = try await run("term-ab-1flood-of-4", flooding: 1)
        let four = try await run("term-ab-4flood-of-4", flooding: 4)
        let ratio = one.p50 == 0 ? 0 : four.p50 / one.p50
        print(String(format: "[term-ab-verdict] p50 %.3f → %.3f (×%.2f)  cpu %.3fs → %.3fs (×%.2f)",
                     one.p50, four.p50, ratio,
                     one.cpuSeconds, four.cpuSeconds,
                     one.cpuSeconds == 0 ? 0 : four.cpuSeconds / one.cpuSeconds))
        // 闸门只钉「两档都真的跑起来了」，比值只打印 —— 判定看报告。
        XCTAssertGreaterThan(one.sleepBeats, 100)
        XCTAssertGreaterThan(four.sleepBeats, 100)
    }

    // MARK: - 尺四：键盘面板展开的挂载账

    /// `TerminalKeyBar` 收起 vs 展开。展开面板是 4 个 `LazyVGrid` 共 57 个键帽，
    /// 每个键帽一个 `Button` —— 密集网格里 `Button` 是已知的主因（uTable playbook §三）。
    func testKeyboardPanelMountCost() async throws {
        defer { MobileProbeWindow.closeAll() }
        var rows: [(String, Double, Int, Double)] = []

        for expanded in [false, true] {
            let (controller, _) = MobileFakeTerminal.controller(.idle)
            let label = expanded ? "term-keybar-expanded" : "term-keybar-compact"
            let rig = MobileProbeRig(label: label, size: CGSize(width: 390, height: 320))
            let mount = rig.mount(
                VStack {
                    Spacer()
                    TerminalKeyBar(controller: controller, expanded: expanded)
                }
                .environment(\.mAccent, M.accent))
            let shot = await rig.snapshot()
            rig.report(nil, shot, nil)
            attachProbePNG(shot.png, name: label)
            rows.append((label, mount, shot.views, shot.hitP50))
            await rig.close()
            MobileProbeWindow.closeAll()
        }

        print("[term-keybar-table] 档 | mount ms | views | hit p50 us")
        for r in rows {
            print(String(format: "[term-keybar-table] %@ | %.2f | %d | %.1f", r.0, r.1, r.2, r.3))
        }
        // 闸门：展开面板必须真的多出视图（否则这一档什么都没量到）。
        XCTAssertGreaterThan(rows[1].2, rows[0].2,
                             "展开档的 UIView 数没比收起档多——面板没挂上")
    }

    // MARK: - 尺五：`MDot` 只在连接中的会话片动

    /// 8 片标签，两档：全部 `.connected`（不呼吸）vs 全部 `.connecting`（呼吸）。
    ///
    /// `MDot` 里带 `repeatForever` 的那一层包在 `if pulse` 内，所以「有几个圈在动」
    /// = 「有几个会话在连」。这一条量的是两档的心跳 / 单帧差，并钉住结构判据：
    /// 连接中档不应该把渲染循环拖垮。
    func testTabBarDotsPulseOnlyWhileConnecting() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try container()
        let relay = HostKeyChallengeRelay()
        let n = 8
        let hs = hosts(c, n)

        func bar(connecting: Bool) async throws -> (MobileProbeRig, TerminalSessions) {
            let sessions = TerminalSessions()
            for i in 0..<n {
                // 连接中档：`connectLatency` 60 秒 —— 整个量测窗口都停在 `.connecting`。
                let script = connecting
                    ? MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0,
                                               connectLatency: .seconds(60))
                    : MobileFakeTerminalScript.idle
                let (tab, _) = MobileFakeTerminal.tab(host: hs[i % hs.count], script)
                tab.controller.start(profile: hs[i % hs.count], container: c, relay: relay)
                sessions.tabs.append(tab)
            }
            sessions.activeID = sessions.tabs.first?.id
            if !connecting {
                for tab in sessions.tabs { _ = await MobileFakeTerminal.waitUntilConnected(tab.controller) }
            }
            let label = connecting ? "term-dots-connecting-8" : "term-dots-connected-8"
            let rig = MobileProbeRig(label: label, size: CGSize(width: 390, height: 120))
            rig.mount(SessionTabBar(tabs: sessions.tabs, activeID: sessions.activeID,
                                    onSelect: { _ in }, onClose: { _ in },
                                    onNew: {}, onBack: {}, onAgent: {})
                .environment(\.mAccent, M.accent))
            return (rig, sessions)
        }

        var readings: [(String, MobileTerminalLoad.Reading, Int, Int)] = []
        for connecting in [false, true] {
            let (rig, sessions) = try await bar(connecting: connecting)
            let pulsing = sessions.tabs.filter { $0.controller.state == .connecting }.count
            let label = connecting ? "term-dots-connecting-8" : "term-dots-connected-8"
            let reading = try await MobileTerminalLoad.measure(rig, seconds: 4)
            let shot = await rig.snapshot()
            rig.report(nil, shot, nil)
            MobileTerminalLoad.report(label, reading)
            attachProbePNG(shot.png, name: label)
            readings.append((label, reading, pulsing, shot.views))
            XCTAssertGreaterThan(shot.ink, 0.005, "截图是空壳")
            // 结构判据：呼吸圈的数量 == 处于 `.connecting` 的会话数（不是标签片数）。
            XCTAssertEqual(pulsing, connecting ? n : 0,
                           "\(label)：处于 connecting 的会话数不对")
            for tab in sessions.tabs { tab.controller.close() }
            await rig.close()
            MobileProbeWindow.closeAll()
        }

        print("[term-dots-table] 档 | 呼吸圈数 | views | ticks/ideal | p50 ms | cpu s")
        for r in readings {
            print(String(format: "[term-dots-table] %@ | %d | %d | %.2f | %.3f | %.3f",
                         r.0, r.2, r.3, r.1.displayRatio, r.1.p50, r.1.cpuSeconds))
        }
        // 视图数两档必须一致：`if pulse` 那一层是 SwiftUI 图层，不该多出 `UIView`。
        XCTAssertEqual(readings[0].3, readings[1].3,
                       "呼吸档多出了 UIView —— MDot 的实现变了，判据要重写")
    }
}
