import AppKit
import Observation
import SwiftData
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 欢迎页左侧栏（`WelcomeSidebar`）的渲染成本探针。
///
/// 侧栏与主列表不是同一种形态，尺子也不一样：它**不是滚动屏**
/// （10 组时压根滚不动，硬套滚动探针会撞 playbook §二·3 的「压根没滚动」）。
/// 真正的账在**每次 body 重跑要付多少**，而 body 重跑得很勤 ——
/// **搜索框每一次击键**要重跑一次，**主机列表里按一次 ↑/↓** 也要重跑一次
/// （`selectedProfileID` 是 `WelcomeView` 的 `@State`，变了整棵
/// `WelcomeView.body` 连同侧栏一起重算）。
///
/// ## 这一处的主项不在「行挂几个控件」上
///
/// 与 uTable ⑨ 权限屏角色 rail 同一类（playbook §五·八·⑨：
/// **先看 body 里有没有循环，再数元件**）。侧栏 body 的第一行是
/// `ServerFilter.counts(for:query:)`，改前它「每个 section 各扫一遍 profiles」，
/// 其中分组那一段是 `for g in allGroups { profiles.filter { $0.group == g } }`
/// —— 2000 台 × 60 组 = **12 万次 `ServerProfile.group` 取值**，
/// 而 SwiftData 的属性读要走一遍持久化 / 观察机制。
///
/// ## 规模来源
///
/// 分组数 = 用户建的 `ServerGroup` 行数；主机数 = 保存的 `ServerProfile` 行数。
/// 真实档 100 台 / 10 组，极端档 2000 台 / 60 组（与
/// `WelcomeServerListCostTests` 取同两档，读数才可比）。中间再插一档
/// 2000 台 / 10 组，用来分开「主机数」与「分组数」各自的贡献。
@MainActor
final class WelcomeSidebarCostTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static let size = NSSize(width: 224, height: 620)

    // MARK: - 尺 ①：`ServerFilter.counts` 单独称，改前 / 改后同轮对照

    /// **改前那一版 `ServerFilter.counts` 的逐字拷贝**（只改了函数名）。
    ///
    /// 抄自 `uTerm/Core/Models/ServerFilter.swift`（本 commit 的父提交）。
    /// 每个 section 各扫一遍 profiles，分组那一段是 O(主机数 × 分组数)。
    static func legacyCounts(for profiles: [ServerProfile], query: String) -> [NavSection: Int] {
        let queryHits: (ServerProfile) -> Bool = { p in
            query.isEmpty || legacyMatchesQuery(query, p)
        }
        var result: [NavSection: Int] = [:]
        result[.allHosts] = profiles.lazy.filter(queryHits).count
        result[.pinned]   = profiles.lazy.filter { $0.isPinned && queryHits($0) }.count
        result[.recent]   = profiles.lazy.filter { $0.lastConnectedAt != nil && queryHits($0) }.count
        let allGroups = Set(profiles.compactMap { name in
            let g = name.group ?? ""
            return g.isEmpty ? nil : g
        })
        for g in allGroups {
            result[.group(g)] = profiles.lazy.filter { ($0.group ?? "") == g && queryHits($0) }.count
        }
        result[.ungrouped] = profiles.lazy.filter { ($0.group ?? "").isEmpty && queryHits($0) }.count
        return result
    }

    /// `ServerFilter.matchesQuery` 是 `fileprivate` 的；改前臂照抄一份。
    private static func legacyMatchesQuery(_ q: String, _ p: ServerProfile) -> Bool {
        p.name.localizedCaseInsensitiveContains(q)
            || p.displayEndpoint.localizedCaseInsensitiveContains(q)
            || (p.group ?? "").localizedCaseInsensitiveContains(q)
    }

    private func timeCounts(_ body: ([ServerProfile], String) -> [NavSection: Int],
                            profiles: [ServerProfile], query: String, reps: Int) -> Double {
        _ = body(profiles, query)   // 预热：把 locale / ICU 首调初始化排除在外
        var samples: [Double] = []
        for _ in 0..<reps {
            let start = CFAbsoluteTimeGetCurrent()
            _ = body(profiles, query)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return ProbeMetrics.percentile(samples, 0.5)
    }

    /// 空 query（列表里按 ↑↓ 就是这一档）与非空 query（正在打字）分开量。
    /// 两臂 ABBA 交替，只信同轮相对差。
    func testCountsCostByScaleAndQuery() throws {
        var table: [(String, Double, Double)] = []
        for (hosts, groups) in [(100, 10), (2000, 10), (2000, 60)] {
            let profiles = WelcomeServerListCostTests.makeProfiles(count: hosts, groups: groups)
            let reps = hosts > 500 ? 20 : 200

            // ABBA：legacy → tuned → tuned → legacy
            let l1e = timeCounts(Self.legacyCounts, profiles: profiles, query: "", reps: reps)
            let t1e = timeCounts(ServerFilter.counts, profiles: profiles, query: "", reps: reps)
            let t2e = timeCounts(ServerFilter.counts, profiles: profiles, query: "", reps: reps)
            let l2e = timeCounts(Self.legacyCounts, profiles: profiles, query: "", reps: reps)

            let l1q = timeCounts(Self.legacyCounts, profiles: profiles, query: "web", reps: reps)
            let t1q = timeCounts(ServerFilter.counts, profiles: profiles, query: "web", reps: reps)
            let t2q = timeCounts(ServerFilter.counts, profiles: profiles, query: "web", reps: reps)
            let l2q = timeCounts(Self.legacyCounts, profiles: profiles, query: "web", reps: reps)

            let legacyEmpty = (l1e + l2e) / 2, tunedEmpty = (t1e + t2e) / 2
            let legacyTyping = (l1q + l2q) / 2, tunedTyping = (t1q + t2q) / 2
            print(String(format: """
                [sidebar-counts] hosts=%d groups=%d \
                empty legacy=%.3fms tuned=%.3fms | typing legacy=%.3fms tuned=%.3fms
                """, hosts, groups, legacyEmpty, tunedEmpty, legacyTyping, tunedTyping))
            table.append(("\(hosts)-\(groups)", legacyEmpty, tunedEmpty))

            // ② 等价性：两臂必须逐键相等（这是「改法没改语义」的硬闸门）。
            for query in ["", "web", "host-1", "group-3", "沒有這個"] {
                XCTAssertEqual(ServerFilter.counts(for: profiles, query: query),
                               Self.legacyCounts(for: profiles, query: query),
                               "counts 的语义必须与改前逐键相等（hosts=\(hosts) groups=\(groups) query=\(query)）")
            }
        }

        // ③ 结构判据（**这才是这一处的判据**）：改后 counts 的成本不随**分组数**涨。
        //    改前 2000/60 比 2000/10 贵好几倍（分组那一段是 O(主机 × 分组)）；
        //    改后两档必须在同一量级 —— 门槛放到 2 倍，只挡形态回退。
        let tuned2000x10 = table.first { $0.0 == "2000-10" }!.2
        let tuned2000x60 = table.first { $0.0 == "2000-60" }!.2
        XCTAssertLessThan(tuned2000x60, tuned2000x10 * 2 + 1.0,
                          "counts 必须一趟过：2000 台下 60 组 \(tuned2000x60)ms "
                          + "不能比 10 组 \(tuned2000x10)ms 贵一个量级")

        // ④ 同轮相对差：极端档改后必须显著快于改前。
        let legacy2000x60 = table.first { $0.0 == "2000-60" }!.1
        XCTAssertLessThan(tuned2000x60, legacy2000x60,
                          "2000 台 / 60 组：改后 \(tuned2000x60)ms 必须快于改前 \(legacy2000x60)ms")
    }

    // MARK: - 尺 ②：挂载 + 一次真 body 重跑 + NSView

    /// 让探针能从外面改 query 并**真的**触发 `WelcomeSidebar.body` 重跑。
    ///
    /// 坑：第一版用 `@State var filter` + 换 `host.rootView`。同类型的根视图
    /// 换上去时 `@State` 会被保留、新的初值被丢弃，profiles 数组又 `==` 相等，
    /// 于是**一次 body 都没重跑**，量到的 0.09ms 是「什么都没发生」。
    /// 改成 `@Observable` 盒子，改盒子里的字段才真的驱动更新。
    @Observable
    @MainActor
    final class FilterBox {
        var query: String = ""
        var section: NavSection = .allHosts

        var filter: ServerFilter {
            get {
                var f = ServerFilter()
                f.query = query
                f.section = section
                return f
            }
            set {
                query = newValue.query
                section = newValue.section
            }
        }
    }

    private struct SidebarRoot: View {
        let profiles: [ServerProfile]
        @Bindable var box: FilterBox
        @State private var pane: WelcomePane = .hosts
        @State private var draggingProfileID: UUID?

        var body: some View {
            WelcomeSidebar(profiles: profiles,
                           filter: $box.filter,
                           pane: $pane,
                           draggingProfileID: $draggingProfileID,
                           onDropProfileToGroup: { _, _ in })
                .frame(width: 224, height: 620)
        }
    }

    /// **`cloudKitDatabase: .none` 是必须的**：默认配置会为每个容器起一套
    /// CoreData+CloudKit 镜像。探针一轮要建三个容器（三档规模各一个），
    /// 第二个容器起来时宿主直接死在 CloudKit setup 上
    /// （xcresult 里只有「Restarting after unexpected exit」）。
    /// 这块屏的判据与云同步无关，关掉即可。
    private func makeContainer(groups: Int) throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerGroup.self, ServerProfile.self,
                                           QuickCommand.self, configurations: config)
        let context = ModelContext(container)
        for i in 0..<groups {
            context.insert(ServerGroup(name: "group-\(i)",
                                       colorHex: ServerGroup.palette[i % ServerGroup.palette.count],
                                       isPinned: i % 11 == 0,
                                       sortOrder: i))
        }
        try context.save()
        return container
    }

    struct Reading {
        let hosts: Int
        let groups: Int
        let mountMS: Double
        let keystrokeP50: Double
        let keystrokeP95: Double
        let views: Int
    }

    /// **三档的容器必须全部在挂第一个视图之前建好。**
    ///
    /// 坑（2026-09-08 实测，宿主 SIGTRAP）：拆完上一档的窗口再 `ModelContainer(...)`
    /// 会崩在 `SwiftData → _SwiftData_SwiftUI → NSNotificationCenter` 那条链上 ——
    /// 上一个 `@Query` 的观察者还挂在通知中心里，新容器一建就被叫到一个已经
    /// 拆掉的视图上。xcresult 里只有一句「Restarting after unexpected exit」，
    /// 崩溃栈要去 `~/Library/Logs/DiagnosticReports/uTerm-*.ips` 里读。
    private func measure(hosts: Int, groups: Int, container: ModelContainer) async throws -> Reading {
        let profiles = WelcomeServerListCostTests.makeProfiles(count: hosts, groups: groups)
        let box = FilterBox()

        let host = NSHostingView(rootView: AnyView(
            SidebarRoot(profiles: profiles, box: box).modelContainer(container)))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: Self.size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        XCTAssertTrue(ProbeWindow.blindsRealMouse(try XCTUnwrap(window as? ProbeWindow.Unconstrained)))

        let mountStart = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - mountStart) * 1000

        // 一次击键 = 改一个字符 + 逼一次布局 + 绘制。逐字敲出 "web-01" 再退回去，
        // 来回 6 轮 —— 复刻用户在搜索框里打字那条路径。
        let word = Array("web-01")
        var samples: [Double] = []
        for round in 0..<6 {
            for i in 0...word.count {
                let next = String(word.prefix(round % 2 == 0 ? i : word.count - i))
                let start = CFAbsoluteTimeGetCurrent()
                box.query = next
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
        }

        let reading = Reading(hosts: hosts, groups: groups, mountMS: mountMS,
                              keystrokeP50: ProbeMetrics.percentile(samples, 0.5),
                              keystrokeP95: ProbeMetrics.percentile(samples, 0.95),
                              views: WelcomeServerListCostTests.viewCount(in: host))
        print(String(format: """
            [sidebar] hosts=%d groups=%d mount=%.2fms keystroke-p50=%.3fms \
            keystroke-p95=%.3fms views=%d cpu=%.2fs
            """, hosts, groups, reading.mountMS, reading.keystrokeP50,
            reading.keystrokeP95, reading.views, ProbeMetrics.threadCPUSeconds()))
        print("[sidebar-views] hosts=\(hosts) groups=\(groups) "
              + WelcomeServerListCostTests.classHistogram(in: host))
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
        return reading
    }

    /// 三档：100/10、2000/10、2000/60。
    ///
    /// 结构判据：侧栏的视图拓扑只跟**分组数**走，跟主机数无关 ——
    /// 100 台 / 10 组与 2000 台 / 10 组的 NSView 数必须相同。
    /// 这条一红就说明有人把「按主机」的东西塞进了侧栏行里。
    func testSidebarScale() async throws {
        defer { closeAllWindows() }
        // 先把三个容器全建出来（理由见 `measure` 的注释）。
        let c1 = try makeContainer(groups: 10)
        let c2 = try makeContainer(groups: 10)
        let c3 = try makeContainer(groups: 60)
        let smallHosts = try await measure(hosts: 100, groups: 10, container: c1)
        let manyHosts = try await measure(hosts: 2000, groups: 10, container: c2)
        let manyGroups = try await measure(hosts: 2000, groups: 60, container: c3)

        XCTAssertEqual(smallHosts.views, manyHosts.views,
                       "侧栏视图数不能跟主机数走：100 台 \(smallHosts.views) "
                       + "vs 2000 台 \(manyHosts.views)")
        XCTAssertGreaterThan(manyGroups.views, manyHosts.views,
                             "分组多了侧栏行才该变多（非 lazy 的分组 ForEach）")
        // 一次击键的绝对毫秒只打印；这里只挡「一次击键要一整秒」这种硬故障。
        XCTAssertLessThan(manyGroups.keystrokeP95, 200,
                          "2000 台 / 60 组敲一个字符不该到 200ms")
    }
}
