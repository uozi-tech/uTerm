import XCTest
@testable import uTerm

@MainActor
final class CloudKitSyncStatusTests: XCTestCase {

    private func resolve(_ phase: CloudKitSyncMonitor.Phase,
                         synced: Bool = false,
                         loggedIn: Bool = true,
                         usingCloudKit: Bool = true) -> CloudKitSyncStatus {
        CloudKitSyncStatus.resolve(phase: phase,
                                   lastSyncedAt: synced ? Date() : nil,
                                   loggedIn: loggedIn,
                                   usingCloudKit: usingCloudKit)
    }

    func testLocalStoreWinsOverEverythingElse() {
        // 容器没以 CloudKit 建成时，登录与否、phase 是什么都不重要。
        XCTAssertEqual(resolve(.exporting, loggedIn: false, usingCloudKit: false), .localOnly)
        XCTAssertEqual(resolve(.idle, synced: true, usingCloudKit: false), .localOnly)
        XCTAssertEqual(CloudKitSyncStatus.localOnly.label, "本地存储")
    }

    func testSignedOutGatesPhase() {
        XCTAssertEqual(resolve(.importing, loggedIn: false), .signedOut)
        XCTAssertEqual(CloudKitSyncStatus.signedOut.label, "未登录 iCloud")
        XCTAssertEqual(CloudKitSyncStatus.signedOut.symbol, "person.crop.circle.badge.xmark")
    }

    func testActivePhasesMapToProgressLabels() {
        XCTAssertEqual(resolve(.setup).label, "连接中…")
        XCTAssertEqual(resolve(.importing).label, "下载中…")
        XCTAssertEqual(resolve(.exporting).label, "上传中…")
        XCTAssertEqual(resolve(.error).label, "同步出错")
        XCTAssertEqual(resolve(.error).symbol, "exclamationmark.icloud")
    }

    func testIdleDistinguishesSyncedFromWaiting() {
        XCTAssertEqual(resolve(.idle, synced: true), .synced)
        XCTAssertEqual(resolve(.idle, synced: true).label, "已同步")
        XCTAssertEqual(resolve(.idle, synced: true).symbol, "checkmark.icloud")
        XCTAssertEqual(resolve(.idle), .waiting)
        XCTAssertEqual(resolve(.idle).label, "等待同步")
        XCTAssertEqual(resolve(.idle).symbol, "icloud")
    }

    func testCloudActiveOnlyPastBothGates() {
        XCTAssertFalse(CloudKitSyncStatus.localOnly.isCloudActive)
        XCTAssertFalse(CloudKitSyncStatus.signedOut.isCloudActive)
        XCTAssertTrue(resolve(.idle).isCloudActive)
        XCTAssertTrue(resolve(.error).isCloudActive)
    }

    func testMonitorDefaultsToCloudKitContainer() {
        // mac 调用不传 usingCloudKit：新建的 monitor 处于 idle、从未同步。
        let monitor = CloudKitSyncMonitor()
        XCTAssertEqual(monitor.status(loggedIn: true), .waiting)
        XCTAssertEqual(monitor.status(loggedIn: false), .signedOut)
        XCTAssertEqual(monitor.status(loggedIn: true, usingCloudKit: false), .localOnly)
    }
}
