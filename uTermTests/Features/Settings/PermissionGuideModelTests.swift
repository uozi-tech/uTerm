import Network
import XCTest
@testable import uTerm

@MainActor
final class PermissionGuideModelTests: XCTestCase {
    /// 可控的系统能力：记录调用，状态由用例直接改。
    @MainActor
    private final class FakeSystem {
        var notification: PermissionStatus = .notAsked
        var notificationAfterRequest: PermissionStatus = .granted
        var screenCapture = false
        var postEvents = false
        var loginItemNeedsApproval = false
        var opened: [PermissionKind] = []
        var screenCaptureRequests = 0
        var relaunches = 0
        var localNetworkUpdate: (@MainActor (PermissionStatus) -> Void)?
        var localNetworkStopped = false

        var environment: PermissionGuideEnvironment {
            PermissionGuideEnvironment(
                notificationStatus: { self.notification },
                requestNotifications: { self.notification = self.notificationAfterRequest },
                screenCaptureGranted: { self.screenCapture },
                requestScreenCapture: { self.screenCaptureRequests += 1 },
                postEventsGranted: { self.postEvents },
                requestPostEvents: {},
                loginItemNeedsApproval: { self.loginItemNeedsApproval },
                observeLocalNetwork: { update in
                    self.localNetworkUpdate = update
                    return { self.localNetworkStopped = true }
                },
                openSettings: { self.opened.append($0) },
                relaunch: { self.relaunches += 1 })
        }
    }

    func testRefreshMapsSystemState() async {
        let system = FakeSystem()
        system.notification = .notGranted
        system.screenCapture = true
        let model = PermissionGuideModel(environment: system.environment)

        await model.refresh()

        XCTAssertEqual(model.status(of: .notifications), .notGranted)
        XCTAssertEqual(model.status(of: .screenCapture), .granted)
        XCTAssertEqual(model.status(of: .accessibility), .notGranted)
        XCTAssertEqual(model.status(of: .localNetwork), .checking, "本地网络只由观察者推送")
    }

    func testRequestingNotificationsUpdatesStatus() async {
        let system = FakeSystem()
        let model = PermissionGuideModel(environment: system.environment)
        await model.refresh()
        XCTAssertEqual(model.status(of: .notifications), .notAsked)

        await model.request(.notifications)

        XCTAssertEqual(model.status(of: .notifications), .granted)
    }

    func testScreenCaptureRequestNeedsRelaunchUntilGranted() async {
        let system = FakeSystem()
        let model = PermissionGuideModel(environment: system.environment)
        await model.refresh()
        XCTAssertFalse(model.needsRelaunch)

        await model.request(.screenCapture)

        XCTAssertEqual(system.screenCaptureRequests, 1)
        XCTAssertEqual(model.status(of: .screenCapture), .needsRelaunch)
        XCTAssertTrue(model.needsRelaunch)

        system.screenCapture = true
        await model.refresh()
        XCTAssertEqual(model.status(of: .screenCapture), .granted)
        XCTAssertFalse(model.needsRelaunch)
    }

    func testLocalNetworkRequestOpensSettingsInsteadOfPrompting() async {
        let system = FakeSystem()
        let model = PermissionGuideModel(environment: system.environment)

        await model.request(.localNetwork)

        XCTAssertEqual(system.opened, [.localNetwork])
    }

    func testLocalNetworkObserverDrivesStatusAndStops() {
        let system = FakeSystem()
        let model = PermissionGuideModel(environment: system.environment)

        model.start()
        system.localNetworkUpdate?(.notGranted)
        XCTAssertEqual(model.status(of: .localNetwork), .notGranted)
        system.localNetworkUpdate?(.granted)
        XCTAssertEqual(model.status(of: .localNetwork), .granted)

        model.stop()
        XCTAssertTrue(system.localNetworkStopped)
    }

    func testLoginItemOnlyListedWhileAwaitingApproval() async {
        let system = FakeSystem()
        let model = PermissionGuideModel(environment: system.environment)

        await model.refresh()
        XCTAssertFalse(model.visibleKinds.contains(.loginItem))

        system.loginItemNeedsApproval = true
        await model.refresh()
        XCTAssertTrue(model.visibleKinds.contains(.loginItem))
        XCTAssertEqual(model.status(of: .loginItem), .notGranted)
    }

    func testGrantedCountOnlyCountsVisibleItems() async {
        let system = FakeSystem()
        system.notification = .granted
        system.postEvents = true
        let model = PermissionGuideModel(environment: system.environment)

        await model.refresh()

        XCTAssertEqual(model.visibleKinds.count, 4)
        XCTAssertEqual(model.grantedCount, 2)
    }

    func testPresentsOncePerRevisionAndNeverInBackground() {
        let current = PermissionGuideWindow.revision
        XCTAssertTrue(PermissionGuideWindow.shouldPresentAtLaunch(presentedRevision: 0, startsHidden: false, isTestHost: false))
        XCTAssertFalse(PermissionGuideWindow.shouldPresentAtLaunch(presentedRevision: current, startsHidden: false, isTestHost: false))
        XCTAssertFalse(PermissionGuideWindow.shouldPresentAtLaunch(presentedRevision: 0, startsHidden: true, isTestHost: false))
        XCTAssertFalse(PermissionGuideWindow.shouldPresentAtLaunch(presentedRevision: 0, startsHidden: false, isTestHost: true))
    }

    func testOnlyPolicyDeniedCountsAsLocalNetworkRefusal() {
        let denied = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
        XCTAssertTrue(LocalNetworkPermissionProbe.isPolicyDenied(denied))
        XCTAssertFalse(LocalNetworkPermissionProbe.isPolicyDenied(.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord))))
        XCTAssertFalse(LocalNetworkPermissionProbe.isPolicyDenied(.posix(.ECONNREFUSED)))
    }
}
