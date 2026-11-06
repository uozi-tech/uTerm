import XCTest
import SwiftData
@testable import uTerm

/// 已知主机指纹的展示规则（两端共用 `KnownHostDisplay` / `KnownHostCopy`）与共享删除 `KnownHostLibrary`。
@MainActor
final class KnownHostDisplayTests: XCTestCase {

    // MARK: - 地址

    func testAddressOmitsDefaultPort() {
        XCTAssertEqual(KnownHostDisplay.address(host: "example.com", port: 22), "example.com")
    }

    func testAddressKeepsNonDefaultPort() {
        XCTAssertEqual(KnownHostDisplay.address(host: "10.0.0.1", port: 2222), "10.0.0.1:2222")
    }

    // MARK: - 密钥类型

    func testKeyTypeLabelDropsSSHPrefix() {
        XCTAssertEqual(KnownHostDisplay.keyTypeLabel("ssh-ed25519"), "ed25519")
        XCTAssertEqual(KnownHostDisplay.keyTypeLabel("ssh-rsa"), "rsa")
    }

    func testKeyTypeLabelKeepsOtherAlgorithms() {
        XCTAssertEqual(KnownHostDisplay.keyTypeLabel("rsa-sha2-256"), "rsa-sha2-256")
        XCTAssertEqual(KnownHostDisplay.keyTypeLabel("ecdsa-sha2-nistp256"), "ecdsa-sha2-nistp256")
        XCTAssertEqual(KnownHostDisplay.keyTypeLabel(""), "")
    }

    // MARK: - 过滤

    private func matches(_ query: String, host: String = "prod.example.com", port: Int = 22,
                         fingerprint: String = "SHA256:AbCdEf123") -> Bool {
        KnownHostDisplay.matches(query: query, host: host, port: port, fingerprint: fingerprint)
    }

    func testBlankQueryMatchesEverything() {
        XCTAssertTrue(matches(""))
        XCTAssertTrue(matches("   "))
    }

    func testQueryMatchesHostCaseInsensitively() {
        XCTAssertTrue(matches("PROD"))
        XCTAssertTrue(matches(" example "))
        XCTAssertFalse(matches("staging"))
    }

    func testQueryMatchesPortOnlyWhenShown() {
        XCTAssertTrue(matches(":2222", host: "10.0.0.1", port: 2222))
        XCTAssertFalse(matches(":22", host: "10.0.0.1", port: 22), "默认端口不显示，也不参与匹配")
    }

    func testQueryMatchesFingerprintCaseInsensitively() {
        XCTAssertTrue(matches("abcdef"))
        XCTAssertTrue(matches("sha256:"))
        XCTAssertFalse(matches("zzz"))
    }

    // MARK: - 文案

    func testDeleteTitleNamesTheAddress() {
        XCTAssertEqual(KnownHostCopy.deleteTitle(address: "10.0.0.1:2222"), "删除「10.0.0.1:2222」的指纹？")
        XCTAssertTrue(KnownHostCopy.deleteMessage.contains("iCloud"), "说明要提醒同步设备上也会删除")
    }

    // MARK: - 模型转发

    func testModelPropertiesForwardToSharedRules() {
        let host = KnownHost()
        host.host = "box.local"
        host.port = 2200
        host.keyTypeRaw = "ssh-ed25519"
        host.fingerprint = "SHA256:xyz"
        XCTAssertEqual(host.displayAddress, "box.local:2200")
        XCTAssertEqual(host.keyTypeLabel, "ed25519")
        XCTAssertTrue(host.matches("XYZ"))
        XCTAssertFalse(host.matches("other"))
    }

    // MARK: - 删除

    /// 与 `KnownHostTests` 同一份内存配置（`cloudKitDatabase: .none`）：默认 `.automatic` 会把假数据灌进 iCloud。
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: KnownHost.self, configurations: config)
        return ModelContext(container)
    }

    func testLibraryDeleteRemovesOnlyThatHostAndSaves() throws {
        let ctx = try makeContext()
        let keep = KnownHost()
        keep.host = "keep.example"
        let drop = KnownHost()
        drop.host = "drop.example"
        ctx.insert(keep)
        ctx.insert(drop)
        try ctx.save()

        KnownHostLibrary.delete(drop, in: ctx)

        XCTAssertFalse(ctx.hasChanges, "删除后已经保存")
        let remaining = try ctx.fetch(FetchDescriptor<KnownHost>())
        XCTAssertEqual(remaining.map(\.host), ["keep.example"])
    }
}
