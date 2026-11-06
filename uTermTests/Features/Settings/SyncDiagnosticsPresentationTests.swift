import XCTest
@testable import uTerm

/// 「同步诊断」列表的排版（macOS 弹窗与 iOS `SyncDiagnosticsSheet` 共用）。
final class SyncDiagnosticsPresentationTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testEmptyEntriesGiveNoRowsAndAnExplanation() {
        XCTAssertTrue(SyncDiagnosticsPresentation.rows([], timeZone: utc).isEmpty)
        XCTAssertFalse(SyncDiagnosticsPresentation.emptyMessage.isEmpty)
    }

    /// 缓冲区新的在末尾，列表要新→旧。
    func testRowsAreNewestFirst() {
        let entries = [
            CloudKitSyncMonitor.Entry(date: Date(timeIntervalSince1970: 0), text: "setup 开始"),
            CloudKitSyncMonitor.Entry(date: Date(timeIntervalSince1970: 1), text: "setup 完成 · 1s"),
            CloudKitSyncMonitor.Entry(date: Date(timeIntervalSince1970: 2), text: "import 开始"),
        ]
        let rows = SyncDiagnosticsPresentation.rows(entries, timeZone: utc)
        XCTAssertEqual(rows.map(\.text), ["import 开始", "setup 完成 · 1s", "setup 开始"])
        XCTAssertEqual(rows.map(\.id), entries.reversed().map(\.id), "行 id 沿用事件 id")
    }

    func testRowFormatsTimeAsHoursMinutesSeconds() {
        // 1970-01-01 13:05:07 UTC
        let entry = CloudKitSyncMonitor.Entry(date: Date(timeIntervalSince1970: 13 * 3600 + 5 * 60 + 7),
                                              text: "export 失败 · 网络不可用")
        let row = SyncDiagnosticsPresentation.rows([entry], timeZone: utc).first
        XCTAssertEqual(row?.time, "13:05:07")
        XCTAssertEqual(row?.text, "export 失败 · 网络不可用")
    }

    func testTitles() {
        XCTAssertEqual(SyncDiagnosticsPresentation.title, "同步诊断")
        XCTAssertEqual(SyncDiagnosticsPresentation.copyButtonTitle, "复制日志")
    }
}
