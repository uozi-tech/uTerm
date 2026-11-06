import XCTest
@testable import uTerm

@MainActor
final class SyncStatusPresentationTests: XCTestCase {
    private let allCloud: [CloudKitSyncStatus] = [
        .localOnly, .signedOut, .connecting, .downloading, .uploading, .failed, .synced, .waiting,
    ]

    func testCloudSymbolComesFromStatus() {
        for status in allCloud {
            XCTAssertEqual(SyncStatusPresentation.cloud(status).symbol, status.symbol)
        }
    }

    func testCloudTones() {
        XCTAssertEqual(SyncStatusPresentation.cloud(.localOnly).tone, .muted)
        XCTAssertEqual(SyncStatusPresentation.cloud(.signedOut).tone, .muted)
        XCTAssertEqual(SyncStatusPresentation.cloud(.waiting).tone, .muted)
        XCTAssertEqual(SyncStatusPresentation.cloud(.failed).tone, .warning)
        for status in [CloudKitSyncStatus.connecting, .downloading, .uploading, .synced] {
            XCTAssertEqual(SyncStatusPresentation.cloud(status).tone, .active, "\(status)")
        }
    }

    func testLANMapping() {
        XCTAssertEqual(SyncStatusPresentation.lan(.ready).symbol, "wifi")
        XCTAssertEqual(SyncStatusPresentation.lan(.ready).tone, .active)
        XCTAssertEqual(SyncStatusPresentation.lan(.waitingForConfirmation).symbol, "hourglass")
        XCTAssertEqual(SyncStatusPresentation.lan(.syncing).symbol, "arrow.up.circle")
        XCTAssertEqual(SyncStatusPresentation.lan(.error("x")).symbol, "exclamationmark.triangle")
        XCTAssertEqual(SyncStatusPresentation.lan(.error("x")).tone, .warning)
        for status in [LANSyncCoordinator.Status.stopped, .searching, .hosting] {
            XCTAssertEqual(SyncStatusPresentation.lan(status).symbol, "wifi.slash")
            XCTAssertEqual(SyncStatusPresentation.lan(status).tone, .muted)
        }
    }

    func testCloudHintDependsOnLogin() {
        XCTAssertTrue(SyncStatusPresentation.cloudHint(loggedIn: true).contains("iCloud 在后台独立同步"))
        XCTAssertTrue(SyncStatusPresentation.cloudHint(loggedIn: false).contains("未登录 iCloud"))
    }

    func testDiagnosticsSubtitle() {
        XCTAssertEqual(SyncStatusPresentation.diagnosticsSubtitle(status: .signedOut, lastError: "boom"),
                       CloudKitSyncStatus.signedOut.label, "看不了细节时只报基础状态")
        XCTAssertEqual(SyncStatusPresentation.diagnosticsSubtitle(status: .synced, lastError: "boom"), "boom")
        XCTAssertEqual(SyncStatusPresentation.diagnosticsSubtitle(status: .synced, lastError: nil),
                       "查看最近同步事件 · 复制日志")
    }
}
