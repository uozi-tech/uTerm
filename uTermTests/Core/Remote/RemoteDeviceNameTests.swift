import XCTest
@testable import uTerm

/// 已配对设备的显示名：机型商品名、本机别名、钥匙串里老数据的兼容。
final class RemoteDeviceNameTests: XCTestCase {
    private func peer(name: String = "iPhone", model: String? = nil, alias: String? = nil) -> RemotePeer {
        RemotePeer(id: UUID(), name: name, publicKey: Data(repeating: 1, count: 32), pairedAt: Date(),
                   model: model, alias: alias)
    }

    func test_marketing_name_comes_from_hardware_identifier() {
        XCTAssertEqual(RemoteDeviceModel.marketingName(for: "iPhone17,1"), "iPhone 16 Pro")
        XCTAssertEqual(RemoteDeviceModel.marketingName(for: "iPhone19,4"), "iPhone Duo")
        XCTAssertEqual(RemoteDeviceModel.marketingName(for: "iPad16,6"), "iPad Pro (13-inch) (M4)")
        XCTAssertNil(RemoteDeviceModel.marketingName(for: "iPhone99,1"), "没见过的新机型不猜，交给调用方退回通用名")
    }

    /// Mac 的商品名读设备树（Apple 芯片才有），在沙盒里的测试宿主也读得到。
    func test_mac_reports_its_product_name_on_apple_silicon() throws {
        #if arch(arm64)
        let name = try XCTUnwrap(RemoteDeviceModel.current())
        XCTAssertTrue(name.hasPrefix("Mac"), "如「MacBook Pro (14-inch, M5 Pro)」，实际 \(name)")
        XCTAssertFalse(name.contains("\u{0}"))
        #else
        throw XCTSkip("Intel Mac 的设备树里没有商品名")
        #endif
    }

    func test_mac_peer_symbol_follows_its_model() {
        var laptop = peer(name: "我的 Mac", model: "MacBook Pro (14-inch, M5 Pro)")
        laptop.platform = RemoteDevicePlatform.mac.rawValue
        var desktop = peer(name: "工作室", model: "Mac mini (2024)")
        desktop.platform = RemoteDevicePlatform.mac.rawValue
        XCTAssertEqual(settingsDeviceSymbol(for: laptop), "laptopcomputer")
        XCTAssertEqual(settingsDeviceSymbol(for: desktop), "desktopcomputer")
        XCTAssertEqual(settingsDeviceSymbol(for: peer(name: "iPad", model: "iPad Air")), "ipad", "老版本不报 platform，按手机看")
    }

    func test_rename_trims_and_clears_alias_when_blank_or_same_as_reported() {
        let base = peer(name: "我的 iPhone")
        XCTAssertEqual(base.renamed("  办公室  ").alias, "办公室")
        XCTAssertEqual(base.renamed("  办公室  ").displayName, "办公室")
        XCTAssertNil(base.renamed("   ").alias)
        XCTAssertNil(base.renamed("我的 iPhone").alias, "改回设备报的名字等于不设别名，之后继续跟着设备走")
    }

    func test_model_detail_is_omitted_when_it_would_repeat_the_title() {
        XCTAssertEqual(peer(name: "我的 iPhone", model: "iPhone 16 Pro").modelDetail, "iPhone 16 Pro")
        XCTAssertNil(peer(name: "iPhone 16 Pro", model: "iPhone 16 Pro").modelDetail, "名字本来就是退回的机型名")
        XCTAssertEqual(peer(name: "iPhone 16 Pro", model: "iPhone 16 Pro", alias: "办公室").modelDetail,
                       "iPhone 16 Pro")
        XCTAssertNil(peer(model: nil).modelDetail, "老版本没报机型")
    }

    func test_peers_saved_before_model_and_alias_still_decode() throws {
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","name":"iPhone","publicKey":"AQE=","pairedAt":0}]"#
        let peers = try JSONDecoder().decode([RemotePeer].self, from: Data(old.utf8))
        XCTAssertEqual(peers.first?.id, id)
        XCTAssertNil(peers.first?.model)
        XCTAssertNil(peers.first?.alias)
        XCTAssertEqual(peers.first?.displayName, "iPhone")
    }

    func test_hello_without_device_model_from_old_phone_still_decodes() throws {
        let hello = RemoteHello(version: 1, deviceID: UUID(), deviceName: "iPhone", ephemeralKey: Data([1]),
                                staticKey: Data([2]))
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any])
        json.removeValue(forKey: "deviceModel")
        let decoded = try JSONDecoder().decode(RemoteHello.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.deviceModel)
    }
}
