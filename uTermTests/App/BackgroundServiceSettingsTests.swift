import XCTest
@testable import uTerm

@MainActor
final class BackgroundServiceSettingsTests: XCTestCase {
    private final class MockService: BackgroundServiceSettings.LoginItemServicing {
        var status: BackgroundServiceSettings.LoginItemStatus
        var registerError: Error?
        var unregisterError: Error?
        var statusAfterRegister: BackgroundServiceSettings.LoginItemStatus?

        init(status: BackgroundServiceSettings.LoginItemStatus) { self.status = status }

        func register() throws {
            if let registerError { throw registerError }
            if let statusAfterRegister { status = statusAfterRegister }
        }

        func unregister() throws {
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    private struct TestError: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    private func defaults() -> UserDefaults {
        let suite = "BackgroundServiceSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testRegisterFailureRollsToggleAndPersistedValueBack() {
        let service = MockService(status: .notRegistered)
        service.registerError = TestError()
        let defaults = defaults()
        let settings = BackgroundServiceSettings(defaults: defaults, loginItemService: service)

        settings.setLaunchAtLogin(true)

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(defaults.bool(forKey: "background.launchAtLogin"))
        XCTAssertEqual(settings.loginItemError, "无法启用登录后台启动：Operation not permitted")
    }

    func testRequiresApprovalIsDistinctFromFailure() {
        let service = MockService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let settings = BackgroundServiceSettings(defaults: defaults(), loginItemService: service)

        settings.setLaunchAtLogin(true)

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.needsLoginItemApproval)
        XCTAssertNil(settings.loginItemError)
    }

    func testRefreshTracksExternalSystemStatus() {
        let service = MockService(status: .enabled)
        let settings = BackgroundServiceSettings(defaults: defaults(), loginItemService: service)
        XCTAssertTrue(settings.launchAtLogin)

        service.status = .notRegistered
        settings.refreshLoginItemStatus()

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.loginItemStatus, .notRegistered)
    }

    func testUnregisterFailureKeepsSystemEnabledState() {
        let service = MockService(status: .enabled)
        service.unregisterError = TestError()
        let settings = BackgroundServiceSettings(defaults: defaults(), loginItemService: service)

        settings.setLaunchAtLogin(false)

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.loginItemStatus, .enabled)
        XCTAssertNotNil(settings.loginItemError)
    }
}
