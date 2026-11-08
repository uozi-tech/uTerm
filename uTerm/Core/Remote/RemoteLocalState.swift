import Foundation

/// 远控落在本机的状态从哪儿读写：设置与设备 ID（UserDefaults）、长期身份（钥匙串）、中继配置（iCloud 钥匙串）。
///
/// 测试宿主与正式版同 bundle id、同沙盒容器、同钥匙串访问组。直接用 `.standard` 和钥匙串，测试里随手建的
/// `RemoteHostServer` 就拿着这台 Mac 真实的设备 ID 在局域网上广播、写正式版的远控设置；拿到中继配置时还会以
/// 本机身份注册中继，把正在运行的正式版挤成「被其他设备顶替」（2026-11-08）。所以远控代码的默认存储只从这里取：
/// 测试宿主里一律换成和正式版分开的存储，并且只连本机回环上的中继（`allowsRelay`）。
/// 生产代码别再直接写 `.standard`、`RemoteKeychainStorage()`、`RemoteKeychainSyncedStorage(…)`
/// （`RemoteLocalStateLintTests` 拦）。
nonisolated enum RemoteLocalState {
    /// 是否跑在测试宿主里（隔离生效）。
    static let isIsolated = TestHostEnvironment.isActive

    /// 远控的设置、设备 ID 等偏好。测试宿主里是单独的一份（`uTerm.tests.remote`）。
    nonisolated(unsafe) static let defaults: UserDefaults = isIsolated
        ? (UserDefaults(suiteName: "uTerm.tests.remote") ?? .standard)
        : .standard

    /// 长期身份、配对过的设备。测试宿主里只在内存（同一进程里共用一份，进程退出即丢）。
    static let secrets: any RemoteSecretStorage = isIsolated ? RemoteMemoryStorage() : RemoteKeychainStorage()

    /// 随 iCloud 钥匙串同步的条目（中继配置、旧版设备名单）。测试宿主里只在内存，绝不同步出去。
    static func syncedStorage(service: String) -> any RemoteSyncedStorage {
        isIsolated ? RemoteMemorySyncedStorage() : RemoteKeychainSyncedStorage(service: service)
    }

    /// 能不能连这台中继。测试宿主里只许本机回环（`make test-relay-e2e` 起的那台），外面的中继一律不连：
    /// 测试进程拿着本机的身份或设备 ID 去注册，会把正式版顶掉。
    static func allowsRelay(host: String) -> Bool {
        !isIsolated || isLoopback(host)
    }

    static func isLoopback(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return trimmed == "localhost" || trimmed == "::1" || trimmed.hasPrefix("127.")
    }
}
