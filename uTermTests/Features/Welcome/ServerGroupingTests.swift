import Foundation
import XCTest
@testable import uTerm

/// `ServerGrouping` 的语义等价 + 「一趟过」结构闸门。
///
/// ## 这一套为什么在 macOS 的 target 里
///
/// 被测的三个派生量（分组 / 组内台数 / 最近连接）原来是 **iOS 端四份手写的副本**
/// （`HostsScreen` / `CommandFormSheet` / `GroupsScreen` / `CommandPaletteView`）。
/// iOS 没有测试 target，这台机器上也没有可用的模拟器 runtime，
/// 那四份副本没法钉任何闸门。收进 `uTerm/Core/Models/ServerGrouping.swift`
/// 之后它同时编进 macOS target，就能在这里量 ——
/// 形状照 `WelcomeSidebarCostTests`（改前臂逐字拷贝 + ABBA + 结构判据）。
///
/// ## 规模来源
///
/// 与 `WelcomeSidebarCostTests` 取同两档，读数才可比：
/// 真实档 100 台 / 10 组，极端档 2000 台 / 60 组；
/// 中间插一档 2000 台 / 10 组，用来把「主机数」与「分组数」的贡献分开。
@MainActor
final class ServerGroupingTests: XCTestCase {

    // MARK: - 改前臂（iOS 视图里那几份的逐字拷贝）

    /// `HostsScreen.grouped` / `CommandFormSheet.grouped` 改前那一版。
    static func legacyGrouped(_ hosts: [ServerProfile]) -> [(name: String, hosts: [ServerProfile])] {
        var order: [String] = []
        var map: [String: [ServerProfile]] = [:]
        for h in hosts {
            let g = (h.group?.isEmpty == false ? h.group! : "未分组")
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(h)
        }
        return order.map { (name: $0, hosts: map[$0] ?? []) }
    }

    /// `GroupsScreen.count(_:)` / `CommandPaletteView.memberCount(_:)` 改前那一版：
    /// **每个分组各扫一遍全表**。
    static func legacyCounts(_ hosts: [ServerProfile], groupNames: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for name in groupNames {
            out[name] = hosts.filter { $0.group == name }.count
        }
        return out
    }

    /// `HostsScreen.recent` 改前那一版：**没有截断**。
    static func legacyRecent(_ hosts: [ServerProfile]) -> [ServerProfile] {
        hosts.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    // MARK: - ① 语义等价

    func testGroupedMatchesLegacy() {
        for (hosts, groups) in [(100, 10), (2000, 10), (2000, 60), (50, 0)] {
            let profiles = WelcomeServerListCostTests.makeProfiles(count: hosts, groups: groups)
            let tuned = ServerGrouping.grouped(profiles)
            let legacy = Self.legacyGrouped(profiles)
            XCTAssertEqual(tuned.map(\.name), legacy.map(\.name),
                           "段名与顺序必须逐字相等（hosts=\(hosts) groups=\(groups)）")
            XCTAssertEqual(tuned.map { $0.hosts.map(\.id) }, legacy.map { $0.hosts.map(\.id) },
                           "段内成员与顺序必须逐字相等（hosts=\(hosts) groups=\(groups)）")
        }
    }

    /// 已有分组名：去重、跳过 nil / 空串、本地化升序（`item10` 排在 `item9` 之后）。
    func testExistingNamesDedupesSkipsBlankAndSortsLocalized() {
        let profiles = WelcomeServerListCostTests.makeProfiles(count: 6, groups: 2)
        profiles[0].group = "item10"
        profiles[1].group = nil
        profiles[2].group = "item9"
        profiles[3].group = ""
        profiles[4].group = "item10"
        profiles[5].group = "Alpha"
        XCTAssertEqual(ServerGrouping.existingNames(profiles), ["Alpha", "item9", "item10"])
        XCTAssertEqual(ServerGrouping.existingNames([]), [])
    }

    /// 空 / nil 组名都要落进「未分组」，且**保持首次出现的顺序**。
    func testGroupedPutsBlankAndNilIntoUngrouped() {
        let profiles = WelcomeServerListCostTests.makeProfiles(count: 6, groups: 2)
        profiles[0].group = nil
        profiles[1].group = ""
        profiles[2].group = "prod"
        profiles[3].group = "dev"
        profiles[4].group = "prod"
        profiles[5].group = nil
        let sections = ServerGrouping.grouped(profiles)
        XCTAssertEqual(sections.map(\.name), [ServerGrouping.ungroupedLabel, "prod", "dev"])
        XCTAssertEqual(sections[0].hosts.count, 3)   // nil + "" + nil
        XCTAssertEqual(sections[1].hosts.count, 2)
        XCTAssertEqual(sections[2].hosts.count, 1)
    }

    func testMemberCountsMatchLegacy() {
        for (hosts, groups) in [(100, 10), (2000, 10), (2000, 60)] {
            let profiles = WelcomeServerListCostTests.makeProfiles(count: hosts, groups: groups)
            let names = WelcomeServerListCostTests.groupNames(groups)
            let tuned = ServerGrouping.memberCounts(profiles)
            let legacy = Self.legacyCounts(profiles, groupNames: names)
            for name in names {
                XCTAssertEqual(tuned[name] ?? 0, legacy[name] ?? 0,
                               "组「\(name)」的台数必须与改前相等（hosts=\(hosts) groups=\(groups)）")
            }
            // 没有成员的组不进字典，调用方靠 `?? 0` 兜底。
            XCTAssertNil(tuned["不存在的组"])
        }
    }

    /// `memberCounts` 不数空 / nil 组名 —— 与改前 `$0.group == name` 的语义一致
    ///（`nil` 不等于任何名字），别顺手把「未分组」也塞进去。
    func testMemberCountsIgnoresUngrouped() {
        let profiles = WelcomeServerListCostTests.makeProfiles(count: 4, groups: 1)
        profiles[0].group = nil
        profiles[1].group = ""
        profiles[2].group = "prod"
        profiles[3].group = "prod"
        let counts = ServerGrouping.memberCounts(profiles)
        XCTAssertEqual(counts, ["prod": 2])
    }

    /// `recent` 与改前同序，只是多了个 20 条的截断（对齐 macOS `ServerFilter.apply`）。
    func testRecentIsLegacyOrderTruncated() {
        for hosts in [100, 2000] {
            let profiles = WelcomeServerListCostTests.makeProfiles(count: hosts, groups: 10)
            let legacy = Self.legacyRecent(profiles)
            let tuned = ServerGrouping.recent(profiles)
            XCTAssertEqual(tuned.map(\.id), legacy.prefix(20).map(\.id),
                           "recent 必须是改前顺序的前 20 条（hosts=\(hosts)）")
            XCTAssertLessThanOrEqual(tuned.count, 20)
        }
        // 显式 limit 也照走。
        let profiles = WelcomeServerListCostTests.makeProfiles(count: 100, groups: 5)
        XCTAssertEqual(ServerGrouping.recent(profiles, limit: 3).count, 3)
    }

    // MARK: - ② 结构判据：「组内台数」不随分组数涨

    /// 改前 `legacyCounts` 是 O(分组 × 主机)：2000 台下 60 组要比 10 组贵好几倍。
    /// 改后一趟过，两档必须在同一量级。
    ///
    /// 闸门只用**同轮相对比**与结构判据，绝对毫秒只打印
    /// （门槛放到 2 倍 + 1ms，只挡形态回退，不挡机器抖动）。
    func testMemberCountsDoesNotScaleWithGroupCount() {
        var tuned: [String: Double] = [:]
        var legacy: [String: Double] = [:]

        for (hosts, groups) in [(100, 10), (2000, 10), (2000, 60)] {
            let profiles = WelcomeServerListCostTests.makeProfiles(count: hosts, groups: groups)
            let names = WelcomeServerListCostTests.groupNames(groups)
            let reps = hosts > 500 ? 20 : 200
            let tag = "\(hosts)-\(groups)"

            // ABBA：legacy → tuned → tuned → legacy，只信同轮相对差。
            let l1 = Self.time(reps: reps) { _ = Self.legacyCounts(profiles, groupNames: names) }
            let t1 = Self.time(reps: reps) { _ = ServerGrouping.memberCounts(profiles) }
            let t2 = Self.time(reps: reps) { _ = ServerGrouping.memberCounts(profiles) }
            let l2 = Self.time(reps: reps) { _ = Self.legacyCounts(profiles, groupNames: names) }

            legacy[tag] = (l1 + l2) / 2
            tuned[tag] = (t1 + t2) / 2
            print(String(format: "[grouping-counts] hosts=%d groups=%d legacy=%.3fms tuned=%.3fms",
                         hosts, groups, legacy[tag]!, tuned[tag]!))
        }

        XCTAssertLessThan(tuned["2000-60"]!, tuned["2000-10"]! * 2 + 1.0,
                          "memberCounts 必须一趟过：2000 台下 60 组 \(tuned["2000-60"]!)ms "
                          + "不能比 10 组 \(tuned["2000-10"]!)ms 贵一个量级")
        XCTAssertLessThan(tuned["2000-60"]!, legacy["2000-60"]!,
                          "2000 台 / 60 组：改后 \(tuned["2000-60"]!)ms 必须快于改前 \(legacy["2000-60"]!)ms")
    }

    /// `grouped` 与 `memberCounts` 一样是一趟过：主机数固定时，分组数不该改变成本。
    func testGroupedDoesNotScaleWithGroupCount() {
        var readings: [String: Double] = [:]
        for (hosts, groups) in [(2000, 10), (2000, 60)] {
            let profiles = WelcomeServerListCostTests.makeProfiles(count: hosts, groups: groups)
            readings["\(hosts)-\(groups)"] = Self.time(reps: 20) {
                _ = ServerGrouping.grouped(profiles)
            }
        }
        print(String(format: "[grouping-sections] 2000×10=%.3fms 2000×60=%.3fms",
                     readings["2000-10"]!, readings["2000-60"]!))
        XCTAssertLessThan(readings["2000-60"]!, readings["2000-10"]! * 2 + 1.0,
                          "grouped 必须一趟过，成本不该随分组数涨")
    }

    // MARK: - 工具

    /// 预热一次（把 locale / ICU / 首次分配排除在外），再取 reps 次的 p50。
    private static func time(reps: Int, _ body: () -> Void) -> Double {
        body()
        var samples: [Double] = []
        samples.reserveCapacity(reps)
        for _ in 0..<reps {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return ProbeMetrics.percentile(samples, 0.5)
    }
}
