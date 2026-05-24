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
}
