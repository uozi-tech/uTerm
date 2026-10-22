import XCTest
@testable import uTerm

final class ExternalAppPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ExternalAppPreferenceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRemembersPerExtensionCaseInsensitively() {
        let pref = ExternalAppPreference(defaults: defaults, fileExists: { _ in true })
        let app = URL(fileURLWithPath: "/Applications/DB Browser for SQLite.app")
        XCTAssertNil(pref.application(forPath: "/srv/cert.db"))

        pref.remember(app, forPath: "/srv/cert.db")

        XCTAssertEqual(pref.application(forPath: "/other/OTHER.DB")?.path, app.path)
        XCTAssertNil(pref.application(forPath: "/srv/config.ini"))
    }

    func testFilesWithoutExtensionShareOneSlot() {
        let pref = ExternalAppPreference(defaults: defaults, fileExists: { _ in true })
        let app = URL(fileURLWithPath: "/Applications/BBEdit.app")
        pref.remember(app, forPath: "/etc/hosts")
        XCTAssertEqual(pref.application(forPath: "/root/Makefile")?.path, app.path)
    }

    func testMissingApplicationIsTreatedAsNotRemembered() {
        let app = URL(fileURLWithPath: "/Applications/Gone.app")
        ExternalAppPreference(defaults: defaults, fileExists: { _ in true })
            .remember(app, forPath: "/a.csv")
        let pref = ExternalAppPreference(defaults: defaults, fileExists: { _ in false })
        XCTAssertNil(pref.application(forPath: "/a.csv"))
    }

    func testForget() {
        let pref = ExternalAppPreference(defaults: defaults, fileExists: { _ in true })
        pref.remember(URL(fileURLWithPath: "/Applications/Numbers.app"), forPath: "/a.csv")
        pref.forget(forPath: "/b.CSV")
        XCTAssertNil(pref.application(forPath: "/a.csv"))
    }
}
