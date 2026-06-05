#if DEBUG
import XCTest
@testable import uTerm

final class MockServerFactoryTests: XCTestCase {
    func test_serverCount_isHonored() {
        let p = MockServerFactory.make(serverCount: 12, groupCount: 0,
                                       pinnedCount: 0, recentCount: 0, nameStyle: .normal)
        XCTAssertEqual(p.count, 12)
    }

    func test_serverCount_clampsToFifty() {
        let p = MockServerFactory.make(serverCount: 100, groupCount: 0,
                                       pinnedCount: 0, recentCount: 0, nameStyle: .normal)
        XCTAssertEqual(p.count, 50)
    }

    func test_groupCount_distributesAcrossDistinctGroups() {
        let p = MockServerFactory.make(serverCount: 9, groupCount: 3,
                                       pinnedCount: 0, recentCount: 0, nameStyle: .normal)
        XCTAssertEqual(Set(p.compactMap(\.group)).count, 3)
    }

    func test_groupCountZero_allUngrouped() {
        let p = MockServerFactory.make(serverCount: 5, groupCount: 0,
                                       pinnedCount: 0, recentCount: 0, nameStyle: .normal)
        XCTAssertTrue(p.allSatisfy { $0.group == nil })
    }

    func test_pinnedCount_clampsToServerCount() {
        let p = MockServerFactory.make(serverCount: 3, groupCount: 0,
                                       pinnedCount: 10, recentCount: 0, nameStyle: .normal)
        XCTAssertEqual(p.filter(\.isPinned).count, 3)
    }

    func test_pinnedCount_exact() {
        let p = MockServerFactory.make(serverCount: 10, groupCount: 0,
                                       pinnedCount: 2, recentCount: 0, nameStyle: .normal)
        XCTAssertEqual(p.filter(\.isPinned).count, 2)
    }

    func test_recentCount_exact() {
        let p = MockServerFactory.make(serverCount: 10, groupCount: 0,
                                       pinnedCount: 0, recentCount: 4, nameStyle: .normal)
        XCTAssertEqual(p.filter { $0.lastConnectedAt != nil }.count, 4)
    }

    func test_longNameStyle_producesLongNames() {
        let p = MockServerFactory.make(serverCount: 3, groupCount: 0,
                                       pinnedCount: 0, recentCount: 0, nameStyle: .long)
        XCTAssertTrue(p.allSatisfy { $0.name.count > 40 })
    }

    func test_deterministicIDs_stableAcrossCalls() {
        let a = MockServerFactory.make(serverCount: 5, groupCount: 2,
                                       pinnedCount: 1, recentCount: 1, nameStyle: .normal)
        let b = MockServerFactory.make(serverCount: 5, groupCount: 2,
                                       pinnedCount: 1, recentCount: 1, nameStyle: .normal)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
    }
}
#endif
