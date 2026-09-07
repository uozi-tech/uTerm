import AppKit
import UDesignKit
import SwiftData
import SwiftUI
import XCTest
@testable import uTerm

/// 全局端口转发窗口（`GlobalForwardingWindowView`）的渲染开销探针。
///
/// 量的是三件事：
/// 1. **挂载 / 滚动 / hitTest / NSView** —— 列表容器的形状（原版是
///    `ScrollView + VStack + ForEach(groups) → VStack + ForEach(group.rules)` 两层非 lazy，
///    1000 行时全部实例化）。
/// 2. **静止不滚时每秒一次的 `pollTraffic`** —— 它整体替换 `@State traffic`，
///    整窗 body 重求，连带 `groups` / `summary` / `launchItems` 三个计算属性全算。
///    判据是 3 秒静止窗口里的 8ms 心跳拍数与相邻拍间隔的尾巴（p99 / max）。
/// 3. **派生数据的纯逻辑账** —— `isHostOnline` 对每个分组扫一遍全部规则，
///    是 O(主机数 × 规则数)。这一条不上屏也能量，机器负载对它影响最小。
///
/// 规模来源：`@Query(sort: \ForwardingRule.sortOrder)` 无上限、按主机数展开。
/// 真实档 10 主机 × 5 规则 = 50 行；极端档 50 主机 × 20 规则 = 1000 行
/// （50 台的上界对齐欢迎页 Tweaks 的钳位 `MockServerFactory.make` 的 `clamp(serverCount, 0, 50)`）。
///
/// **同轮对照**：`legacyNestedList` 臂原样保留改前的容器形状（两层非 lazy `ForEach`），
/// 与产线视图在同一个进程里轮流量 —— 绝对毫秒跨进程不可比（playbook §二），
/// 只有同轮的相对差算数。
@MainActor
final class GlobalForwardingListCostTests: XCTestCase {

    private var windows: [NSWindow] = []

    /// 见 `ProbeSmokeTests`：`uTermTests` 默认 `nonisolated` + Swift 6，
    /// 覆写 `tearDown()` 拆窗过不了隔离检查，只能每条用例开头 `defer`。
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

    private static let size = NSSize(width: 900, height: 700)

    private enum Arm: String {
        /// 产线视图。
        case production
        /// 改前的容器形状：两层非 lazy `ForEach`（行组件仍是产线的 `GlobalForwardRow`）。
        case legacyNestedList
    }

    private struct Seeded {
        let container: ModelContainer
        let coordinator: ForwardingCoordinator
        let model: GlobalForwardingModel
        let relay: HostKeyChallengeRelay
        let profiles: [ServerProfile]
        let rules: [ForwardingRule]
        let baseTraffic: [UUID: TunnelBytes]
    }

    private func seed(hosts: Int, rulesPerHost: Int) throws -> Seeded {
        let s = try ForwardingProbeFixture.seed(hosts: hosts, rulesPerHost: rulesPerHost)
        return Seeded(container: s.container, coordinator: s.coordinator,
                      model: GlobalForwardingModel(), relay: HostKeyChallengeRelay(),
                      profiles: s.profiles, rules: s.rules, baseTraffic: s.traffic)
    }

    private func rootView(_ arm: Arm, _ seeded: Seeded) -> AnyView {
        let inner: AnyView
        switch arm {
        case .production:
            inner = AnyView(GlobalForwardingWindowView())
        case .legacyNestedList:
            inner = AnyView(LegacyGlobalForwardingList())
        }
        return AnyView(
            inner
                .environment(seeded.coordinator)
                .environment(seeded.model)
                .environment(seeded.relay)
                .modelContainer(seeded.container)
        )
    }

    private func measure(_ arm: Arm, _ seeded: Seeded, hosts: Int, rulesPerHost: Int)
        async throws -> ForwardingProbeReading {
        let mounted = try ForwardingProbeFixture.mount(rootView(arm, seeded),
                                                       size: Self.size,
                                                       windows: &windows)
        // 让隧道「真的在跑字节」：静止窗口里每 8 拍把累计字节推一格。
        // 不推的话每秒那一拍写回的是完全相同的字典，SwiftUI 的 `@State` 相等性比较
        // 直接吃掉这次写入、body 根本不重求 —— 读到的 idle 开销会假性为 0。
        var generation: UInt64 = 0
        let coordinator = seeded.coordinator
        let base = seeded.baseTraffic
        let bump: () -> Void = {
            generation &+= 1
            var next: [UUID: TunnelBytes] = [:]
            next.reserveCapacity(base.count)
            for (id, bytes) in base {
                next[id] = TunnelBytes(up: bytes.up &+ generation &* 65_536,
                                       down: bytes.down &+ generation &* 262_144)
            }
            coordinator.injectTrafficForTesting(next)
        }
        var reading = await ForwardingProbeFixture.measure(
            label: "\(arm.rawValue)/\(hosts)x\(rulesPerHost)",
            rows: hosts * rulesPerHost,
            mounted: mounted,
            mutateSource: bump)
        reading.label = "\(arm.rawValue)/\(hosts)x\(rulesPerHost)"
        print("[gfwd] \(reading.label) \(reading.oneLine)")
        print("[gfwd-views] \(reading.label) \(reading.histogram)")
        await closeWindows()
        return reading
    }

    // MARK: - 用例

    /// 真实档（10 主机 × 5 规则 = 50 行）与极端档（50 × 20 = 1000 行）两臂同轮交替。
    /// 轮内顺序反转一次，防单向漂移（playbook §二·「同轮交替」）。
    ///
    /// **四份数据必须在挂第一个窗口之前全部建好**：`ModelContext.save()` 会发
    /// `NSManagedObjectContextDidSave` 通知，`_SwiftData_SwiftUI` 的 `@Query` 观察者
    /// 一律收得到；上一档的宿主视图刚拆、观察者还没散时给下一档存盘，SwiftData 会
    /// 在通知回调里 `EXC_BREAKPOINT` 直接把测试宿主打没（xcresult 只留一句
    /// 「Restarting after unexpected exit」）。造完数据再挂窗就没有这个窗口期。
    func testGlobalForwardingListScaleAndIdleTick() async throws {
        defer { closeAllWindows() }

        let plan: [(Arm, Int, Int)] = [
            (.production, 10, 5),
            (.legacyNestedList, 10, 5),
            (.legacyNestedList, 50, 20),
            (.production, 50, 20),
        ]
        let seeds = try plan.map { try seed(hosts: $0.1, rulesPerHost: $0.2) }

        var readings: [String: ForwardingProbeReading] = [:]
        for (index, (arm, hosts, per)) in plan.enumerated() {
            let r = try await measure(arm, seeds[index], hosts: hosts, rulesPerHost: per)
            readings[r.label] = r
        }

        let smallProd = try XCTUnwrap(readings["production/10x5"])
        let bigProd = try XCTUnwrap(readings["production/50x20"])
        let bigLegacy = try XCTUnwrap(readings["legacyNestedList/50x20"])

        // 结构判据（硬断言，对机器负载免疫）：
        // ① 夹具真的画出了东西，且真的能滚。
        XCTAssertGreaterThan(smallProd.views, 50, "50 行档必须真的建出视图，不能是空壳")
        XCTAssertGreaterThan(bigProd.scrollableHeight, 0, "1000 行必须超过一屏")
        // ② 平台视图数不随行数线性涨 —— 非 lazy 的两层 ForEach 会把 1000 行全实例化，
        //    这条断言正是改前会红、改后才绿的那一条。改前的对照臂读数留在日志里。
        XCTAssertLessThan(Double(bigProd.views), Double(smallProd.views) * 3,
                          "1000 行的 NSView 数不该跟着行数长："
                          + "50 行 \(smallProd.views) vs 1000 行 \(bigProd.views)"
                          + "（同轮改前臂 \(bigLegacy.views)）")
        // ③ hitTest 不随规模涨。
        XCTAssertLessThan(bigProd.hitP50, max(400, smallProd.hitP50 * 4),
                          "hitTest 不该随行数涨：50 行 \(smallProd.hitP50)µs vs "
                          + "1000 行 \(bigProd.hitP50)µs（同轮改前臂 \(bigLegacy.hitP50)µs）")
    }

    /// 派生数据的纯逻辑账：`groups` + `summary` + `launchItems` + 组头的「在线 / 活跃数」。
    /// 每秒一次的 `pollTraffic` 会把它们**全部**重算一遍，所以这一条直接决定静止时的开销。
    ///
    /// 两臂同轮交替，判据是**结构性的**：改前 `isHostOnline` 对每个分组线性扫全部规则、
    /// 组头再 filter 一遍算活跃数，总成本 O(主机 × 规则)；改后一遍聚合，O(规则)。
    /// 所以「1000 条档 / 50 条档」的比值（规则数正好 20×）改前会远超 20，改后应贴着 20。
    func testDerivedDataCostDoesNotGrowQuadratically() throws {
        /// 改前的形状：`groups` 算三遍（body 里 `groups.count`、`listBody`、`launchItems` 各一次）、
        /// 每组一次 `isHostOnline` 全表扫、每组一次 activeN filter、`summary` 再扫一遍。
        func legacyCost(_ profiles: [ServerProfile], _ rules: [ForwardingRule],
                        _ coordinator: ForwardingCoordinator) -> Double {
            func groups() -> [GFGroup<ServerProfile, ForwardingRule>] {
                gfGroupByHost(hosts: profiles, rules: rules,
                              hostID: { $0.id }, ruleServerID: { $0.serverID })
            }
            func isHostOnline(_ hostID: UUID) -> Bool {
                for r in rules where r.serverID == hostID {
                    switch coordinator.status(r.id) {
                    case .active, .starting: return true
                    default: continue
                    }
                }
                return false
            }
            let rounds = 10
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<rounds {
                let hostCount = groups().count                       // 标题栏
                let summary = gfSummary(statuses: rules.map { coordinator.status($0.id) },
                                        launchFlags: rules.map(\.launchAtAppStart))
                let items = groups().flatMap { group in              // launchItems
                    group.rules.filter(\.launchAtAppStart).map {
                        GlobalForwardingModel.LaunchItem(rule: $0.snapshot, server: group.host)
                    }
                }
                var online = 0, activeSum = 0
                for group in groups() {                              // listBody + 每组组头
                    if isHostOnline(group.host.id) { online += 1 }
                    activeSum += group.rules.filter { coordinator.status($0.id) == .active }.count
                }
                XCTAssertEqual(hostCount, profiles.count)
                XCTAssertEqual(summary.ruleTotal, rules.count)
                XCTAssertGreaterThanOrEqual(items.count, 0)
                XCTAssertGreaterThanOrEqual(online + activeSum, 0)
            }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(rounds)
        }

        func currentCost(_ profiles: [ServerProfile], _ rules: [ForwardingRule],
                         _ coordinator: ForwardingCoordinator) -> Double {
            let rounds = 10
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<rounds {
                let d = GlobalForwardingDerived(profiles: profiles, rules: rules,
                                                coordinator: coordinator)
                XCTAssertEqual(d.summary.ruleTotal, rules.count)
                XCTAssertEqual(d.sections.count, profiles.count)
                var online = 0, activeSum = 0
                for group in d.sections {
                    if d.isOnline(group.host.id) { online += 1 }
                    activeSum += d.activeCount(group.host.id)
                }
                XCTAssertGreaterThanOrEqual(online + activeSum, 0)
            }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(rounds)
        }

        let small = try ForwardingProbeFixture.seed(hosts: 10, rulesPerHost: 5)   // 50 条
        let big = try ForwardingProbeFixture.seed(hosts: 50, rulesPerHost: 20)    // 1000 条
        // 预热两臂两档，再交替量（轮内顺序反转一次）。
        for _ in 0..<2 {
            _ = legacyCost(small.profiles, small.rules, small.coordinator)
            _ = currentCost(big.profiles, big.rules, big.coordinator)
        }
        let legacySmall = legacyCost(small.profiles, small.rules, small.coordinator)
        let currentSmall = currentCost(small.profiles, small.rules, small.coordinator)
        let currentBig = currentCost(big.profiles, big.rules, big.coordinator)
        let legacyBig = legacyCost(big.profiles, big.rules, big.coordinator)

        let legacyRatio = legacyBig / max(legacySmall, 1e-9)
        let currentRatio = currentBig / max(currentSmall, 1e-9)
        print(String(format: """
            [gfwd-derived] legacy small=%.4fms big=%.4fms ratio=%.1f× | \
            current small=%.4fms big=%.4fms ratio=%.1f×（规则数正好 20×）
            """, legacySmall, legacyBig, legacyRatio,
            currentSmall, currentBig, currentRatio))

        // 结构判据：规则数 20 倍，线性实现的比值应贴着 20；O(主机 × 规则) 会飙到几百。
        XCTAssertLessThan(currentRatio, 45,
                          "派生数据一次求值应随规则数线性涨（20×），实测 "
                          + String(format: "%.1f", currentRatio)
                          + "× —— 说明还有 O(主机 × 规则) 的扫描"
                          + "（同轮改前臂 \(String(format: "%.1f", legacyRatio))×）")
        // 同轮相对比：极端档里改后必须明显便宜。
        XCTAssertLessThan(currentBig, legacyBig * 0.5,
                          "极端档（50 主机 × 20 规则）一次派生求值："
                          + String(format: "改前 %.4fms → 改后 %.4fms", legacyBig, currentBig))
    }
}

// MARK: - 改前臂：两层非 lazy ForEach

/// **改前的容器形状**，只留作同轮对照臂 —— 产线代码已换掉，别再照它写新界面。
///
/// 与改前的 `GlobalForwardingWindowView.listBody` 一字对应：
/// `ScrollView { VStack { ForEach(groups) { 组头 + VStack { ForEach(group.rules) { 行 } } } } }`，
/// 外加同样的每秒 `pollTraffic` 整体替换 `@State traffic`、同样在 body 里现算
/// `groups` / `summary` / `launchItems`、同样的 `isHostOnline` 逐组全扫。
private struct LegacyGlobalForwardingList: View {
    @Query(sort: \ServerProfile.sortOrder) private var profiles: [ServerProfile]
    @Query(sort: \ForwardingRule.sortOrder) private var rules: [ForwardingRule]
    @Environment(ForwardingCoordinator.self) private var coordinator
    @Environment(GlobalForwardingModel.self) private var model
    @Environment(HostKeyChallengeRelay.self) private var relay

    @State private var traffic: [UUID: GFTrafficStat] = [:]
    @State private var lastBytes: [UUID: TunnelBytes] = [:]

    private var groups: [GFGroup<ServerProfile, ForwardingRule>] {
        gfGroupByHost(hosts: profiles, rules: rules,
                      hostID: { $0.id }, ruleServerID: { $0.serverID })
    }

    private var summary: GFSummary {
        gfSummary(statuses: rules.map { coordinator.status($0.id) },
                  launchFlags: rules.map(\.launchAtAppStart))
    }

    private var launchItems: [GlobalForwardingModel.LaunchItem] {
        groups.flatMap { group in
            group.rules.filter(\.launchAtAppStart).map {
                GlobalForwardingModel.LaunchItem(rule: $0.snapshot, server: group.host)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlobalForwardingTitleBar(hostCount: groups.count)
            StartupAutomationBanner(model: model,
                                    launchCount: summary.launchTotal,
                                    upCount: summary.upCount,
                                    failCount: summary.failCount,
                                    onReconnect: {})
            Text("共 \(summary.ruleTotal) 条规则 · \(summary.activeTotal) 活跃")
                .font(.system(size: 11.5)).foregroundStyle(UD.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 9)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(groups, id: \.host.id) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 18)
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(UD.bg)
        .task { await pollTraffic() }
    }

    private func section(_ group: GFGroup<ServerProfile, ForwardingRule>) -> some View {
        let host = group.host
        let online = isHostOnline(host.id)
        let activeN = group.rules.filter { coordinator.status($0.id) == .active }.count
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(online ? UD.success : UD.text4).frame(width: 6, height: 6)
                Text(host.name.isEmpty ? host.host : host.name)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(UD.text)
                Text(host.host).font(UD.mono(11)).foregroundStyle(UD.text4)
                Spacer()
                Text("\(activeN)/\(group.rules.count) 活跃")
                    .font(.system(size: 11)).foregroundStyle(UD.text4)
            }
            .padding(.horizontal, 2).padding(.bottom, 7)

            VStack(spacing: 0) {
                ForEach(Array(group.rules.enumerated()), id: \.element.id) { idx, rule in
                    GlobalForwardRow(rule: rule, server: host, relay: relay,
                                     isLast: idx == group.rules.count - 1,
                                     traffic: traffic[rule.id],
                                     onEdit: {})
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private func isHostOnline(_ hostID: UUID) -> Bool {
        for r in rules where r.serverID == hostID {
            switch coordinator.status(r.id) {
            case .active, .starting: return true
            default: continue
            }
        }
        return false
    }

    private func pollTraffic() async {
        let clock = ContinuousClock()
        var lastTick = clock.now
        while !Task.isCancelled {
            let now = await coordinator.trafficSnapshot()
            let tick = clock.now
            let d = tick - lastTick
            let elapsed = max(0.25, Double(d.components.seconds)
                              + Double(d.components.attoseconds) * 1e-18)
            lastTick = tick
            var stats: [UUID: GFTrafficStat] = [:]
            for (id, bytes) in now {
                let prev = lastBytes[id]
                let upDelta = prev.map { bytes.up >= $0.up ? bytes.up - $0.up : 0 } ?? 0
                let downDelta = prev.map { bytes.down >= $0.down ? bytes.down - $0.down : 0 } ?? 0
                stats[id] = GFTrafficStat(up: bytes.up, down: bytes.down,
                                          upRate: UInt64(Double(upDelta) / elapsed),
                                          downRate: UInt64(Double(downDelta) / elapsed))
            }
            lastBytes = now
            traffic = stats
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
