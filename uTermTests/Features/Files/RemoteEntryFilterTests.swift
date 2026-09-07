import XCTest
@testable import uTerm

/// 筛选记忆化的行为闸门：语义必须与它替掉的那句
/// `sortedEntries.filter { $0.name.localizedCaseInsensitiveContains(query) }`
/// 一字不差，同时保证「同一份数据 + 同一个词」不重复扫全表。
@MainActor
final class RemoteEntryFilterTests: XCTestCase {

    private func entries(_ names: [String]) -> [RemoteEntry] {
        names.map { RemoteEntry(name: $0, posixPermissions: 0o100644,
                                size: 1, modifiedAt: nil) }
    }

    func testEmptyQueryReturnsEverything() {
        let filter = RemoteEntryFilter()
        let source = entries(["a.txt", "B.md", "c"])
        XCTAssertEqual(filter.apply(source, query: ""), source)
    }

    func testMatchesCaseInsensitivelyLikeTheOriginalPredicate() {
        let filter = RemoteEntryFilter()
        let source = entries(["Readme.md", "readme.txt", "notes"])
        let expected = source.filter { $0.name.localizedCaseInsensitiveContains("README") }
        XCTAssertEqual(filter.apply(source, query: "README").map(\.name), expected.map(\.name))
        XCTAssertEqual(expected.count, 2)
    }

    func testRepeatedCallsWithTheSameInputsDoNotRescan() {
        let filter = RemoteEntryFilter()
        let source = entries((0..<200).map { "file-\($0)" })
        _ = filter.apply(source, query: "1")
        let afterFirst = filter.recomputeCount
        // 一次 body 里 visible 被读三次（文件表 / 检视器 / 状态栏）——只该扫一遍。
        _ = filter.apply(source, query: "1")
        _ = filter.apply(source, query: "1")
        XCTAssertEqual(filter.recomputeCount, afterFirst, "同一份数据 + 同一个词不该重扫")
    }

    func testQueryChangeAndSourceChangeBothInvalidate() {
        let filter = RemoteEntryFilter()
        let source = entries(["alpha", "beta"])
        _ = filter.apply(source, query: "a")
        let afterFirst = filter.recomputeCount
        _ = filter.apply(source, query: "b")
        XCTAssertEqual(filter.recomputeCount, afterFirst + 1, "换词必须重算")
        let changed = entries(["alpha", "beta", "gamma"])
        _ = filter.apply(changed, query: "b")
        XCTAssertEqual(filter.recomputeCount, afterFirst + 2, "换数据必须重算")
    }

    func testSelectedLookupOnlySeesVisibleEntries() {
        let filter = RemoteEntryFilter()
        let source = entries(["alpha", "beta"])
        XCTAssertEqual(filter.entry(id: "alpha", in: source, query: "")?.name, "alpha")
        // 被筛掉的选中项必须返回 nil —— 检视器与「已选 1 项」要跟着清空。
        XCTAssertNil(filter.entry(id: "alpha", in: source, query: "bet"))
        XCTAssertEqual(filter.entry(id: "beta", in: source, query: "bet")?.name, "beta")
        XCTAssertNil(filter.entry(id: nil, in: source, query: ""))
    }

    func testSelectedLookupDoesNotRescanAfterVisibleWasComputed() {
        let filter = RemoteEntryFilter()
        let source = entries((0..<100).map { "file-\($0)" })
        _ = filter.apply(source, query: "7")
        let afterFirst = filter.recomputeCount
        _ = filter.entry(id: "file-7", in: source, query: "7")
        _ = filter.entry(id: "file-7", in: source, query: "7")
        XCTAssertEqual(filter.recomputeCount, afterFirst)
    }
}
