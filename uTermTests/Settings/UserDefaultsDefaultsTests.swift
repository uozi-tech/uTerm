import XCTest
@testable import uTerm

/// 验证 UserDefaults 在无 stored value 时的回退行为，与 @AppStorage 默认值匹配。
final class UserDefaultsDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "UserDefaultsDefaultsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // ── startupBehavior ──────────────────────────────────────────
    func test_startupBehavior_default_via_nil_fallback() {
        XCTAssertNil(defaults.string(forKey: "startupBehavior"))
        // 生产代码：StartupBehavior(rawValue: defaults.string(...) ?? "welcome")
        let raw = defaults.string(forKey: "startupBehavior") ?? StartupBehavior.welcome.rawValue
        XCTAssertEqual(StartupBehavior(rawValue: raw), .welcome)
    }

    func test_startupBehavior_persist_lastHost() {
        defaults.set(StartupBehavior.lastHost.rawValue, forKey: "startupBehavior")
        XCTAssertEqual(defaults.string(forKey: "startupBehavior"), "last-host")
    }

    func test_startupBehavior_corrupt_value_falls_back() {
        defaults.set("garbage", forKey: "startupBehavior")
        let raw = defaults.string(forKey: "startupBehavior") ?? StartupBehavior.welcome.rawValue
        // raw 是 "garbage"，但 StartupBehavior init 返回 nil
        // 调用方应再 ?? .welcome
        XCTAssertNil(StartupBehavior(rawValue: raw))
    }

    // ── restoreTerminalSession ──────────────────────────────────
    func test_restoreTerminalSession_absent_when_unset() {
        // 注：本测试只验证 UserDefaults 在未写入时的 nil 状态。
        // @AppStorage 的默认 true 由属性声明承担（GeneralSettingsView 与
        // WorkspaceWindowView 都声明 `= true`），不在 UserDefaults 层；
        // 直接读 defaults.bool(forKey:) 在未写入时会返回 false，与
        // @AppStorage 行为不一致——这是 SwiftUI API 设计，不是 bug。
        XCTAssertNil(defaults.object(forKey: "restoreTerminalSession"))
    }

    func test_restoreTerminalSession_persist_false() {
        defaults.set(false, forKey: "restoreTerminalSession")
        XCTAssertFalse(defaults.bool(forKey: "restoreTerminalSession"))
    }

    func test_restoreTerminalSession_persist_true() {
        defaults.set(true, forKey: "restoreTerminalSession")
        XCTAssertTrue(defaults.bool(forKey: "restoreTerminalSession"))
    }
}
