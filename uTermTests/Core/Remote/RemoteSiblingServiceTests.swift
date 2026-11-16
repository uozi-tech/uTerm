import CryptoKit
import XCTest
@testable import uTerm

/// 「我的设备」的 App 级单例：后台不生成身份、打开页面才生成；弹窗先问核对通过的那一个；有人在看时轮询改快。
@MainActor
final class RemoteSiblingServiceTests: XCTestCase {
    private let roster = RemoteSiblingRoster(storage: RemoteMemorySyncedStorage())

    private func device(_ name: String) -> (RemoteSiblingDevice, Curve25519.KeyAgreement.PrivateKey) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (RemoteSiblingDevice(id: UUID(), name: name, model: nil, platform: "mobile",
                                    publicKey: key.publicKey.rawRepresentation, updatedAt: Date()), key)
    }

    func test_background_never_creates_an_identity_but_opening_the_page_does() {
        var asked: [Bool] = []
        let (local, key) = device("iPad")
        let service = RemoteSiblingService { createsIdentity in
            asked.append(createsIdentity)
            return createsIdentity ? RemoteSiblingDevices(local: local, localKey: key, roster: self.roster,
                                                          store: RemoteSiblingLocalStore(storage: RemoteMemoryStorage())) : nil
        }
        service.tick()
        XCTAssertNil(service.model, "后台只读不生成：从没用过远程控制的人不会因此多出一把钥匙")
        XCTAssertEqual(asked, [false])
        XCTAssertNotNil(service.ensureModel())
        XCTAssertEqual(asked, [false, true])
        service.tick()
        XCTAssertEqual(asked, [false, true], "有了之后不再重建：全 App 只能有一个实例")
    }

    func test_popup_asks_about_the_verified_request_first() {
        let (phone, _) = device("iPhone")
        let (mac, _) = device("Mac")
        let waiting = RemoteSiblingDevices.Incoming(voucher: phone, code: "123456", verified: false)
        let verified = RemoteSiblingDevices.Incoming(voucher: mac, code: "654321", verified: true)
        XCTAssertEqual(RemoteSiblingService.pending(in: [waiting, verified]), verified)
        XCTAssertEqual(RemoteSiblingService.pending(in: [waiting]), waiting)
        XCTAssertNil(RemoteSiblingService.pending(in: []))
    }

    func test_polls_faster_while_someone_is_looking() async {
        let service = RemoteSiblingService { _ in nil }
        XCTAssertEqual(service.interval, RemoteSiblingService.idleInterval)
        let looking = Task { await service.keepActive() }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(service.interval, RemoteSiblingService.activeInterval)
        looking.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(service.interval, RemoteSiblingService.idleInterval)
    }
}
