import XCTest
import SwiftData
@testable import uTerm

/// 两端共用启动引导 `AppBootstrap` 的顺序与产物。只用私有 UserDefaults 套件与内存库，
/// 不碰宿主的真实设置与 iCloud；接收端没启用过时不会开 NWListener。
@MainActor
final class AppBootstrapTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let name = "AppBootstrapTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        self.defaults = defaults
    }

    private func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(for: ServerProfile.self, configurations: config)
    }

    private func startReceiverCore(
        monitor: CloudKitSyncMonitor = CloudKitSyncMonitor(),
        makeContainer: (() -> ModelContainer)? = nil
    ) -> AppBootstrap.Core {
        AppBootstrap.startCore(
            lanRole: .receiver,
            makeContainer: makeContainer ?? self.makeContainer,
            cloudKitSync: monitor,
            preferences: SharedPreferencesSync(defaults: defaults, store: BootstrapNoopKeyValueStore()),
            lanDefaults: defaults)
    }

    /// CloudKit 可能在容器初始化期间就发事件：订阅必须早于建容器。
    func testCloudKitMonitorStartsBeforeContainerIsCreated() {
        let monitor = CloudKitSyncMonitor()
        XCTAssertFalse(monitor.isStarted)
        var startedWhenContainerBuilt: Bool?
        let core = startReceiverCore(monitor: monitor) {
            startedWhenContainerBuilt = monitor.isStarted
            return self.makeContainer()
        }
        XCTAssertEqual(startedWhenContainerBuilt, true, "建容器时 CloudKit 监听必须已经订阅")
        XCTAssertTrue(core.cloudKitSync === monitor)
    }

    func testCoreWiresTheSameInstancesTogether() {
        let core = startReceiverCore()
        XCTAssertEqual(core.lanSync.pairingCode, "", "接收端不生成配对码（发送端才生成）")
        XCTAssertFalse(core.preferences.isReady, "第 1–4 步只建偏好桥，第 6 步才启动")
    }

    /// 接收端首次启动不监听（不弹「本地网络」授权）。
    func testFreshReceiverDoesNotStartListeningAtLaunch() {
        let core = startReceiverCore()
        XCTAssertFalse(core.lanSync.isReceiverActivated)
        XCTAssertEqual(core.lanSync.status, .stopped)
    }

    func testLockFollowsStoredPreference() {
        let core = startReceiverCore()
        defaults.set(true, forKey: DefaultsKey.requireAuthAtLaunch)
        XCTAssertEqual(AppBootstrap.finishCore(core, authenticator: FakeBiometricAuthenticator(),
                                               defaults: defaults).state, .locked)
        defaults.set(false, forKey: DefaultsKey.requireAuthAtLaunch)
        XCTAssertEqual(AppBootstrap.finishCore(core, authenticator: FakeBiometricAuthenticator(),
                                               defaults: defaults).state, .unlocked)
    }

    /// 缺键时按平台默认值（mac 开 / iOS 关），与 `AppLockPreference.defaultValue` 一致。
    func testLockUsesPlatformDefaultWhenKeyMissing() {
        let core = startReceiverCore()
        let lock = AppBootstrap.finishCore(core, authenticator: FakeBiometricAuthenticator(), defaults: defaults)
        XCTAssertEqual(lock.state, AppLockPreference.defaultValue ? .locked : .unlocked)
    }

    /// 第 6 步走 `startForAppLaunch()`：测试宿主里不启动 KVS 桥，免得测试把设置推给用户的设备。
    func testFinishCoreDoesNotStartPreferenceBridgeInTestHost() {
        XCTAssertTrue(TestHostEnvironment.isActive)
        let core = startReceiverCore()
        _ = AppBootstrap.finishCore(core, authenticator: FakeBiometricAuthenticator(), defaults: defaults)
        XCTAssertFalse(core.preferences.isReady)
    }
}

private final class BootstrapNoopKeyValueStore: NSUbiquitousKeyValueStore {}
