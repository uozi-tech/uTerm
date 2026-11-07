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
        XCTAssertNil(RemoteDeviceModel.current(), "Mac 不报机型")
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
