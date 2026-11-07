import XCTest
@testable import uTermMobile

/// 手机密码库的契约（界面解锁逻辑依赖这些行为）。真钥匙串 + Face ID 不在单测里跑，这里用内存实现核契约。
@MainActor
final class RemoteUnlockVaultTests: XCTestCase {
    func test_save_read_roundtrip_per_mac() async throws {
        let store = MemoryRemoteUnlockStore()
        let macA = UUID(), macB = UUID()
        XCTAssertFalse(store.hasPassword(forMac: macA))

        try store.save("pw-a", forMac: macA)
        try store.save("pw-b", forMac: macB)
        XCTAssertTrue(store.hasPassword(forMac: macA))

        let readA = try await store.password(forMac: macA, reason: "测试")
        let readB = try await store.password(forMac: macB, reason: "测试")
        XCTAssertEqual(readA, "pw-a")
        XCTAssertEqual(readB, "pw-b", "不同 Mac 的密码互不串台")
    }

    func test_remove_clears_password() async throws {
        let store = MemoryRemoteUnlockStore()
        let mac = UUID()
        try store.save("pw", forMac: mac)
        store.remove(forMac: mac)
        XCTAssertFalse(store.hasPassword(forMac: mac))
        let read = try await store.password(forMac: mac, reason: "测试")
        XCTAssertNil(read)
    }

    func test_read_missing_returns_nil() async throws {
        let store = MemoryRemoteUnlockStore()
        let read = try await store.password(forMac: UUID(), reason: "测试")
        XCTAssertNil(read)
    }

    func test_read_surfaces_biometry_failure() async throws {
        let store = MemoryRemoteUnlockStore()
        let mac = UUID()
        try store.save("pw", forMac: mac)
        store.readError = RemoteUnlockVaultError.biometryUnavailable
        do {
            _ = try await store.password(forMac: mac, reason: "测试")
            XCTFail("生物识别失败时应抛错，而不是返回密码")
        } catch {
            // 预期
        }
    }
}
