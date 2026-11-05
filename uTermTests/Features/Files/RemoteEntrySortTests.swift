import XCTest
@testable import uTerm

final class RemoteEntrySortTests: XCTestCase {
    private func file(_ name: String, size: UInt64? = 1, modified: TimeInterval? = nil) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o100644, size: size,
                    modifiedAt: modified.map { Date(timeIntervalSince1970: $0) })
    }
    private func dir(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o040755, size: nil, modifiedAt: nil)
    }

    /// 名字按 Finder 规则：大小写无关、数字按数值（f2 在 f10 前）。
    func testNameUsesLocalizedStandardCompare() {
        let sorted = RemoteEntrySort.sorted(
            [file("f10"), file("F2"), file("f1")],
            options: RemoteEntrySortOptions(showHidden: true))
        XCTAssertEqual(sorted.map(\.name), ["f1", "F2", "f10"])
    }

    func testFoldersFirst() {
        let input = [file("a"), dir("z"), file("b"), dir("m")]
        XCTAssertEqual(RemoteEntrySort.sorted(input, options: .init()).map(\.name),
                       ["m", "z", "a", "b"])
        XCTAssertEqual(RemoteEntrySort.sorted(input, options: .init(foldersFirst: false)).map(\.name),
                       ["a", "b", "m", "z"])
    }

    func testHiddenFilter() {
        let input = [file(".ssh"), file("a")]
        XCTAssertEqual(RemoteEntrySort.sorted(input, options: .init()).map(\.name), ["a"])
        XCTAssertEqual(RemoteEntrySort.sorted(input, options: .init(showHidden: true)).map(\.name),
                       [".ssh", "a"])
    }

    /// size 缺失的永远在末尾，不受升降序影响。
    func testNilSizeLastRegardlessOfDirection() {
        let input = [file("none", size: nil), file("big", size: 10), file("small", size: 1)]
        XCTAssertEqual(RemoteEntrySort.sorted(input, options: .init(key: .size)).map(\.name),
                       ["small", "big", "none"])
        XCTAssertEqual(RemoteEntrySort.sorted(input, options: .init(key: .size, ascending: false)).map(\.name),
                       ["big", "small", "none"])
    }

    func testModifiedDescending() {
        let input = [file("old", modified: 1), file("new", modified: 3), file("mid", modified: 2)]
        XCTAssertEqual(RemoteEntrySort.sorted(input, options: .init(key: .modified, ascending: false)).map(\.name),
                       ["new", "mid", "old"])
    }

    /// 等值时保持 provider 给的原始顺序。
    func testStableForEqualKeys() {
        let input = [file("b", size: 5), file("a", size: 5), file("c", size: 5)]
        XCTAssertEqual(RemoteEntrySort.sorted(input, options: .init(key: .size)).map(\.name),
                       ["b", "a", "c"])
    }
}
