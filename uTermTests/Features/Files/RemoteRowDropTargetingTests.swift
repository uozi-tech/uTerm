import XCTest
import SwiftUI
@testable import uTerm

/// 「整表一个拖放目标」的行为闸门。
///
/// 行内 `.onDrop` 被摘掉之后，「拖到哪一行」不再由 AppKit 的命中测试给出，
/// 而是按固定行高算出来的。所以拖入契约必须在这里钉死：
/// 只有 `..` 行与**目录**行收货，文件行、列表之外一律不收，且收到的必须是
/// 落点正下方的那一条。
@MainActor
final class RemoteRowDropTargetingTests: XCTestCase {

    private func entry(_ name: String, directory: Bool) -> RemoteEntry {
        RemoteEntry(name: name,
                    posixPermissions: directory ? 0o040755 : 0o100644,
                    size: directory ? nil : 10, modifiedAt: nil)
    }

    // MARK: 落点 → 行号

    func testParentRowTakesTheFirstBand() {
        let target = RemoteRowDropTargeting.target(
            atY: 10, showsParentRow: true, parentRowHeight: 46, rowHeight: 52, entryCount: 3)
        XCTAssertEqual(target, .parent)
    }

    func testFirstEntryStartsRightAfterTheParentRow() {
        XCTAssertEqual(
            RemoteRowDropTargeting.target(atY: 45.9, showsParentRow: true,
                                          parentRowHeight: 46, rowHeight: 52, entryCount: 3),
            .parent)
        XCTAssertEqual(
            RemoteRowDropTargeting.target(atY: 46, showsParentRow: true,
                                          parentRowHeight: 46, rowHeight: 52, entryCount: 3),
            .entry(0))
        XCTAssertEqual(
            RemoteRowDropTargeting.target(atY: 46 + 51.9, showsParentRow: true,
                                          parentRowHeight: 46, rowHeight: 52, entryCount: 3),
            .entry(0))
        XCTAssertEqual(
            RemoteRowDropTargeting.target(atY: 46 + 52, showsParentRow: true,
                                          parentRowHeight: 46, rowHeight: 52, entryCount: 3),
            .entry(1))
    }

    func testWithoutParentRowTheFirstEntryStartsAtZero() {
        XCTAssertEqual(
            RemoteRowDropTargeting.target(atY: 0, showsParentRow: false,
                                          parentRowHeight: 46, rowHeight: 30, entryCount: 3),
            .entry(0))
        XCTAssertEqual(
            RemoteRowDropTargeting.target(atY: 89, showsParentRow: false,
                                          parentRowHeight: 46, rowHeight: 30, entryCount: 3),
            .entry(2))
    }

    func testOutOfRangeYieldsNoTarget() {
        XCTAssertNil(RemoteRowDropTargeting.target(
            atY: -1, showsParentRow: true, parentRowHeight: 46, rowHeight: 52, entryCount: 3))
        // 末行之后的空白（列表短于视口时的下方留白）不收货。
        XCTAssertNil(RemoteRowDropTargeting.target(
            atY: 46 + 52 * 3, showsParentRow: true,
            parentRowHeight: 46, rowHeight: 52, entryCount: 3))
        XCTAssertNil(RemoteRowDropTargeting.target(
            atY: 10, showsParentRow: false, parentRowHeight: 46, rowHeight: 52, entryCount: 0))
    }

    // MARK: 收货契约

    private func makeDelegate(_ entries: [RemoteEntry],
                              showsParentRow: Bool = true,
                              onEntry: @escaping ([NSItemProvider], RemoteEntry) -> Bool = { _, _ in true },
                              onParent: @escaping ([NSItemProvider]) -> Bool = { _ in true })
        -> RemoteRowDropDelegate {
        RemoteRowDropDelegate(entries: entries,
                              showsParentRow: showsParentRow,
                              parentRowHeight: 46,
                              rowHeight: 52,
                              onDropToEntry: onEntry,
                              onDropToParent: onParent)
    }

    func testOnlyDirectoryRowsAndTheParentRowAccept() {
        let entries = [entry("docs", directory: true),
                       entry("a.txt", directory: false),
                       entry("build", directory: true)]
        let delegate = makeDelegate(entries)
        XCTAssertEqual(delegate.acceptedTarget(atY: 10), .parent)
        XCTAssertEqual(delegate.acceptedTarget(atY: 46 + 10), .entry(0))
        XCTAssertNil(delegate.acceptedTarget(atY: 46 + 52 + 10), "文件行不收货")
        XCTAssertEqual(delegate.acceptedTarget(atY: 46 + 52 * 2 + 10), .entry(2))
        XCTAssertNil(delegate.acceptedTarget(atY: 46 + 52 * 3 + 1), "末行之后不收货")
    }

    func testPerformRoutesToTheRowUnderTheDropPoint() {
        let entries = [entry("docs", directory: true),
                       entry("a.txt", directory: false),
                       entry("build", directory: true)]
        var receivedEntry: RemoteEntry?
        var parentHits = 0
        let delegate = makeDelegate(entries,
                                    onEntry: { _, e in receivedEntry = e; return true },
                                    onParent: { _ in parentHits += 1; return true })
        let providers = [NSItemProvider(object: "x" as NSString)]

        XCTAssertTrue(delegate.perform(providers, atY: 46 + 52 * 2 + 10))
        XCTAssertEqual(receivedEntry?.name, "build", "必须落到落点正下方的那一条目录")

        receivedEntry = nil
        XCTAssertFalse(delegate.perform(providers, atY: 46 + 52 + 10), "文件行不收货")
        XCTAssertNil(receivedEntry)

        XCTAssertTrue(delegate.perform(providers, atY: 5))
        XCTAssertEqual(parentHits, 1, "落在 `..` 行上必须走「移到上一级」")
    }

    func testWithoutParentRowNothingRoutesToTheParent() {
        let entries = [entry("docs", directory: true)]
        var parentHits = 0
        let delegate = makeDelegate(entries, showsParentRow: false,
                                    onParent: { _ in parentHits += 1; return true })
        XCTAssertEqual(delegate.acceptedTarget(atY: 1), .entry(0))
        XCTAssertTrue(delegate.perform([NSItemProvider(object: "x" as NSString)], atY: 1))
        XCTAssertEqual(parentHits, 0, "根目录没有 `..` 行，落点不该被判成上一级")
    }

    /// 两个列表里「行高常量」与「行真正的 `.frame(height:)`」必须同源 ——
    /// 落点换算全靠它，改了一处忘了另一处，拖入就会错行。
    func testRowHeightConstantsMatchTheRenderedRows() {
        XCTAssertEqual(SFTPFileTable.rowHeight, 36)
        XCTAssertEqual(SFTPFileTable.parentRowHeight, 32)
        XCTAssertEqual(FileBrowserContent.rowHeight, 30)
    }
}
