import XCTest
@testable import uTerm

@MainActor
final class ServerFilterTests: XCTestCase {

    private func make(_ name: String, host: String = "h", group: String? = nil,
                      pinned: Bool = false, connected: Date? = nil) -> ServerProfile {
        let p = ServerProfile()
        p.name = name; p.host = host; p.port = 22; p.username = "u"
        p.group = group; p.isPinned = pinned; p.lastConnectedAt = connected
        return p
    }

    func test_allHosts_returnsAll() {
        let ps = [make("a"), make("b")]
        var f = ServerFilter(); f.section = .allHosts
        XCTAssertEqual(f.apply(to: ps).count, 2)
    }

    func test_pinned_returnsOnlyPinned() {
        let ps = [make("a", pinned: true), make("b")]
        var f = ServerFilter(); f.section = .pinned
        XCTAssertEqual(f.apply(to: ps).map(\.name), ["a"])
    }

    func test_recent_returnsByMostRecentFirst() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let ps = [make("old", connected: early), make("new", connected: late), make("none")]
        var f = ServerFilter(); f.section = .recent
        let result = f.apply(to: ps)
        XCTAssertEqual(result.map(\.name), ["new", "old"])   // none 过滤掉
    }

    func test_group_filtersByExactName() {
        let ps = [make("a", group: "生产"), make("b", group: "测试"), make("c")]
        var f = ServerFilter(); f.section = .group("生产")
        XCTAssertEqual(f.apply(to: ps).map(\.name), ["a"])
    }

    func test_ungrouped_includesNilAndEmpty() {
        let ps = [make("a", group: nil), make("b", group: ""), make("c", group: "g")]
        var f = ServerFilter(); f.section = .ungrouped
        XCTAssertEqual(Set(f.apply(to: ps).map(\.name)), ["a", "b"])
    }

    func test_queryFiltersNameAndHostAndGroup() {
        let ps = [make("alpha", host: "h1"),
                  make("beta", host: "host-alpha"),
                  make("gamma", group: "alpha")]
        var f = ServerFilter(); f.section = .allHosts; f.query = "alpha"
        XCTAssertEqual(Set(f.apply(to: ps).map(\.name)), ["alpha", "beta", "gamma"])
    }

    func test_queryIsCaseInsensitive() {
        let ps = [make("Alpha")]
        var f = ServerFilter(); f.query = "ALPHA"
        XCTAssertEqual(f.apply(to: ps).count, 1)
    }

    func test_counts_acrossSections() {
        let ps = [make("a", pinned: true), make("b", group: "g"),
                  make("c", connected: .now)]
        let counts = ServerFilter.counts(for: ps, query: "")
        XCTAssertEqual(counts[.allHosts], 3)
        XCTAssertEqual(counts[.pinned], 1)
        XCTAssertEqual(counts[.recent], 1)
        XCTAssertEqual(counts[.group("g")], 1)
        XCTAssertEqual(counts[.ungrouped], 2)   // "a" 与 "c" 未分组
    }

    func test_counts_respectQuery() {
        let ps = [make("alpha", group: "生产"), make("beta", group: "生产")]
        let counts = ServerFilter.counts(for: ps, query: "alpha")
        XCTAssertEqual(counts[.allHosts], 1)
        XCTAssertEqual(counts[.group("生产")], 1)
    }

    /// 分组键取自 **profiles 自身**（不是 `ServerGroup` 表），而且一个分组即使
    /// 被 query 全过滤掉也要留在字典里、值为 0 —— 侧栏靠它把不命中的分组行
    /// 变暗（`WelcomeSidebar.isDimmedGroup`）。
    ///
    /// 2026-09-08 把 `counts` 从「每段扫一遍」改成一趟过（2000 台 / 60 组
    /// 52 → 2.4ms，见 `WelcomeSidebarCostTests`）时，这一条是最容易被改丢的
    /// 语义，所以单独钉住。
    func test_counts_keepsZeroHitGroupsInTheDictionary() {
        let ps = [make("alpha", group: "生产"), make("beta", group: "预发")]
        let counts = ServerFilter.counts(for: ps, query: "alpha")
        XCTAssertEqual(counts[.group("生产")], 1)
        XCTAssertEqual(counts[.group("预发")], 0,
                       "被 query 全过滤掉的分组仍要在字典里、值为 0")
        XCTAssertNil(counts[.group("不存在的组")],
                     "没有任何 profile 属于它的分组不该凭空出现")
    }

    /// 一趟过之后四个内建 section 必须恒有值（哪怕是 0）—— 调用方直接下标读。
    func test_counts_alwaysCarriesTheFourBuiltInSections() {
        let counts = ServerFilter.counts(for: [], query: "")
        XCTAssertEqual(counts[.allHosts], 0)
        XCTAssertEqual(counts[.pinned], 0)
        XCTAssertEqual(counts[.recent], 0)
        XCTAssertEqual(counts[.ungrouped], 0)
    }
}
