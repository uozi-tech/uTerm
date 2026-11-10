import Foundation
import XCTest
@testable import uTerm

/// 测试宿主与正式版共用沙盒容器和钥匙串：远控的默认存储在这里必须是隔离的那一份，外面的中继一律不连。
///
/// 回归的是 2026-11-08 的事故：测试进程拿着本机身份与设备 ID 走到真实中继，正式版被挤成「被其他设备顶替」。
@MainActor
final class RemoteLocalStateTests: XCTestCase {
    func test_test_host_uses_isolated_defaults_and_secrets() {
        XCTAssertTrue(RemoteLocalState.isIsolated, "测试宿主应当被识别出来")
        XCTAssertFalse(RemoteLocalState.defaults === UserDefaults.standard, "远控设置不能写进正式版的偏好")
        XCTAssertTrue(RemoteLocalState.secrets is RemoteMemoryStorage, "身份不能读写正式版的钥匙串")
        XCTAssertTrue(RemoteLocalState.syncedStorage(service: "com.uozi.uTerm.remote.relay") is RemoteMemorySyncedStorage,
                      "中继配置不能读写 iCloud 钥匙串")
    }

    func test_default_device_id_is_not_the_production_one() {
        let id = RemoteLocalDevice.id()
        XCTAssertEqual(RemoteLocalState.defaults.string(forKey: DefaultsKey.remoteDeviceID), id.uuidString)
        if let production = UserDefaults.standard.string(forKey: DefaultsKey.remoteDeviceID) {
            XCTAssertNotEqual(production, id.uuidString, "测试里建的服务端不能冒充这台 Mac")
        }
        let server = RemoteHostServer(registry: TerminalSessionRegistry())
        XCTAssertEqual(server.localID, id)
    }

    func test_default_stores_never_touch_production_state() throws {
        let first = try RemoteIdentityStore(role: .controllers).localIdentity().publicKey.rawRepresentation
        let second = try RemoteIdentityStore(role: .controllers).localIdentity().publicKey.rawRepresentation
        XCTAssertEqual(first, second, "同一进程里默认身份是同一份（隔离的内存存储）")
        XCTAssertNil(RemoteRelayConfigStore().load(), "测试宿主里看不到正式版的中继配置")
    }

    func test_only_loopback_relays_are_reachable_from_the_test_host() async {
        XCTAssertTrue(RemoteLocalState.allowsRelay(host: "127.0.0.1"))
        XCTAssertTrue(RemoteLocalState.allowsRelay(host: "localhost"))
        XCTAssertTrue(RemoteLocalState.allowsRelay(host: "::1"))
        XCTAssertTrue(RemoteLocalState.allowsRelay(host: "[::1]"))
        XCTAssertFalse(RemoteLocalState.allowsRelay(host: "relay.example.com"))
        XCTAssertFalse(RemoteLocalState.allowsRelay(host: "203.0.113.7"))

        let config = RemoteRelayConfig(name: "外面", host: "203.0.113.7", port: 47310, relayID: "abc", key: "k")
        do {
            _ = try await RemoteRelayConnection(config: config).open(timeout: 1)
            XCTFail("测试宿主不该连外部中继")
        } catch RemoteRelayError.unreachable {
        } catch {
            XCTFail("应当在建连前就拒绝：\(error)")
        }
    }
}

/// 生产源码 lint：远控的存储只许经 `RemoteLocalState` 拿，免得新代码又直接碰正式版的偏好与钥匙串。
final class RemoteLocalStateLintTests: XCTestCase {
    private static let allowedFiles: Set<String> = [
        "uTerm/Core/Remote/RemoteLocalState.swift",
    ]

    func testRemoteCodeDoesNotReachForProductionStorageDirectly() throws {
        let rootPath = DefaultsKeyLintTests.repoRoot.path + "/"
        var offenders: [String] = []
        for file in try DefaultsKeyLintTests.productionSwiftFiles() {
            let relative = file.path.replacingOccurrences(of: rootPath, with: "")
            guard !Self.allowedFiles.contains(relative) else { continue }
            let isRemote = relative.contains("/Remote/")
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let keychain = line.contains("RemoteKeychainStorage()") || line.contains("RemoteKeychainSyncedStorage(")
                let standardDefaults = isRemote
                    && (line.contains("defaults: UserDefaults = .standard") || line.contains("defaults: .standard"))
                if keychain || standardDefaults { offenders.append("\(relative):\(index + 1)") }
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            远控代码直接用了正式版的存储（\(offenders.count) 处）：
            \(offenders.joined(separator: "\n"))
            改成 RemoteLocalState.defaults / .secrets / .syncedStorage(service:)：测试宿主与正式版共用沙盒和钥匙串。
            """)
    }
}
