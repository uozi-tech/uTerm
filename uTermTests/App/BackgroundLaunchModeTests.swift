import XCTest
@testable import uTerm

@MainActor
final class BackgroundLaunchModeTests: XCTestCase {
    func testLoginHelperUsesExplicitBackgroundEntry() {
        XCTAssertEqual(
            BackgroundLaunchMode.presentation(arguments: ["uTerm", "--background", "--launch-source", "login-item"]),
            .background
        )
    }

    func testCLIUsesExplicitBackgroundEntry() {
        XCTAssertTrue(BackgroundLaunchMode.shouldStartHidden(arguments: ["uTerm", "--background"]))
    }

    func testManualColdLaunchIsForegroundEvenWhenPreferencesExist() {
        XCTAssertEqual(BackgroundLaunchMode.presentation(arguments: ["uTerm"]), .foreground)
    }

    func testReopeningExistingBackgroundProcessPromotesGUI() {
        XCTAssertEqual(BackgroundLaunchMode.reopenPresentation, .foreground)
    }

    private func defaults(onDemand: Bool?, controlEnabled: Bool?) -> UserDefaults {
        let name = "BackgroundLaunchModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        if let onDemand { defaults.set(onDemand, forKey: BackgroundServiceSettings.Keys.allowOnDemandLaunch) }
        if let controlEnabled { defaults.set(controlEnabled, forKey: ControlSettings.Keys.enabled) }
        return defaults
    }

    private let cliArguments = ["uTerm", "--background", "--launch-source", "cli"]

    /// 客户端读不到设置时照样请求启动，app 自己按设置把关：两项都开才留下。
    func testCLILaunchNeedsBothOnDemandAndControlInterface() {
        XCTAssertNil(BackgroundLaunchMode.cliLaunchRefusal(
            arguments: cliArguments, defaults: defaults(onDemand: true, controlEnabled: true)))
        XCTAssertNotNil(BackgroundLaunchMode.cliLaunchRefusal(
            arguments: cliArguments, defaults: defaults(onDemand: false, controlEnabled: true)))
        XCTAssertNotNil(BackgroundLaunchMode.cliLaunchRefusal(
            arguments: cliArguments, defaults: defaults(onDemand: true, controlEnabled: false)))
        // 没设过 = 默认关。
        XCTAssertNotNil(BackgroundLaunchMode.cliLaunchRefusal(
            arguments: cliArguments, defaults: defaults(onDemand: nil, controlEnabled: nil)))
    }

    /// 手动打开、登录项唤起不受这两个开关影响。
    func testNonCLILaunchesAreNeverRefused() {
        let off = defaults(onDemand: false, controlEnabled: false)
        XCTAssertNil(BackgroundLaunchMode.cliLaunchRefusal(arguments: ["uTerm"], defaults: off))
        XCTAssertNil(BackgroundLaunchMode.cliLaunchRefusal(
            arguments: ["uTerm", "--background", "--launch-source", "login-item"], defaults: off))
        XCTAssertNil(BackgroundLaunchMode.cliLaunchRefusal(
            arguments: ["uTerm", "--launch-source"], defaults: off))
    }
}
