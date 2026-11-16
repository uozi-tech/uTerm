import CryptoKit
import XCTest
@testable import uTerm

/// 设备组的 App 级单例：后台不生成身份、打开页面才生成；弹窗问哪个加入请求（关掉过、核对通过的不弹）；
/// 有人在看、在显示核对码、有人想加入、在等别的设备时轮询改快。
@MainActor
final class RemoteDeviceGroupServiceTests: XCTestCase {
    private let synced = RemoteMemorySyncedStorage()
    private lazy var roster = RemoteGroupRoster(storage: synced)

    private func makeDevice(_ name: String) -> RemoteDeviceGroup {
        let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
        let key = try! store.signingKey()
        let local = RemoteGroupDevice(id: UUID(), name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                      publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                      signingKey: key.publicKey.rawRepresentation, updatedAt: Date())
        return RemoteDeviceGroup(local: local, signingKey: key, roster: roster, store: store)
    }

    private func code(_ device: RemoteDeviceGroup) -> String? {
        guard case .showingCode(let code, _) = device.joinState else { return nil }
        return code
    }

    func test_background_never_creates_an_identity_but_opening_the_page_does() {
        var asked: [Bool] = []
        let device = makeDevice("iPad")
        let service = RemoteDeviceGroupService { createsIdentity in
            asked.append(createsIdentity)
            return createsIdentity ? device : nil
        }
        service.tick()
        XCTAssertNil(service.model, "后台只读不生成：从没用过远程控制的人不会因此多出一把钥匙")
        XCTAssertEqual(asked, [false])
        XCTAssertNotNil(service.ensureModel())
        XCTAssertEqual(asked, [false, true])
        service.tick()
        service.ensureModel()
        XCTAssertEqual(asked, [false, true], "有了之后不再重建：全 App 只能有一个实例")
        XCTAssertTrue(roster.load().devices.contains { $0.id == device.local.id }, "打开页面时登记本机")
    }

    func test_popup_shows_the_join_request_until_it_is_hidden_and_again_when_its_status_changes() throws {
        let phone = makeDevice("iPhone")
        let pad = makeDevice("iPad")
        let service = RemoteDeviceGroupService { _ in phone }
        service.tick()
        XCTAssertNil(service.pendingRequest)

        pad.startJoin()
        service.tick()
        let request = try XCTUnwrap(service.pendingRequest)
        XCTAssertEqual(request.candidate.id, pad.local.id)
        XCTAssertEqual(request.status, .waitingForCode(attemptsLeft: RemoteDeviceGroup.submissionLimit))

        // 输错：组员这边先是「正在核对」，关掉就不弹。
        let shown = try XCTUnwrap(code(pad))
        let wrong = String(format: "%06d", ((Int(shown) ?? 0) + 1) % 1_000_000)
        XCTAssertTrue(service.submit(wrong, for: request))
        let verifying = try XCTUnwrap(service.pendingRequest)
        XCTAssertEqual(verifying.status, .verifying)
        service.hidePrompt(verifying)
        XCTAssertNil(service.pendingRequest, "关掉后核对在后台继续，不再弹")
        service.tick()
        XCTAssertNil(service.pendingRequest)

        // 新设备作废这个数、换了新数：状态变了，再弹。
        pad.refresh()
        service.tick()
        let retry = try XCTUnwrap(service.pendingRequest)
        XCTAssertEqual(retry.status, .wrongCode(attemptsLeft: RemoteDeviceGroup.submissionLimit - 1))

        // 输对：核对通过的不弹，也不留在名单里（不然轮询一直是快的）。
        XCTAssertTrue(service.submit(try XCTUnwrap(code(pad)), for: retry))
        pad.refresh()
        service.tick()
        XCTAssertNil(service.pendingRequest)
        XCTAssertTrue(phone.joinRequests.isEmpty)
        XCTAssertTrue(phone.members.contains { $0.device.id == pad.local.id })
        XCTAssertTrue(service.hiddenRequests.isEmpty, "请求没了，关掉的记录也清掉")
    }

    func test_rejecting_hides_that_round() throws {
        let phone = makeDevice("iPhone")
        let pad = makeDevice("iPad")
        let service = RemoteDeviceGroupService { _ in phone }
        pad.startJoin()
        service.tick()
        service.reject(try XCTUnwrap(service.pendingRequest))
        XCTAssertNil(service.pendingRequest)
        service.tick()
        XCTAssertNil(service.pendingRequest)
    }

    func test_pending_skips_admitted_and_hidden_requests() {
        let device = makeDevice("Mac").local
        let other = makeDevice("Mac mini").local
        let admitted = RemoteDeviceGroup.JoinRequest(candidate: device, status: .admitted)
        let waiting = RemoteDeviceGroup.JoinRequest(candidate: other, status: .waitingForCode(attemptsLeft: 3))
        XCTAssertEqual(RemoteDeviceGroupService.pending(in: [admitted, waiting], hidden: [:]), waiting)
        XCTAssertNil(RemoteDeviceGroupService.pending(in: [waiting], hidden: [other.id: waiting.status]))
        XCTAssertEqual(RemoteDeviceGroupService.pending(in: [waiting], hidden: [other.id: .verifying]), waiting)
        XCTAssertNil(RemoteDeviceGroupService.pending(in: [], hidden: [:]))
    }

    func test_polls_faster_while_showing_a_code_or_someone_wants_to_join() {
        let phone = makeDevice("iPhone")
        let pad = makeDevice("iPad")
        let padService = RemoteDeviceGroupService { _ in pad }
        let phoneService = RemoteDeviceGroupService { _ in phone }
        padService.tick()
        phoneService.tick()
        XCTAssertEqual(padService.interval, RemoteDeviceGroupService.idleInterval)
        XCTAssertEqual(phoneService.interval, RemoteDeviceGroupService.idleInterval)

        pad.startJoin()
        padService.tick()
        XCTAssertEqual(padService.interval, RemoteDeviceGroupService.activeInterval, "显示着核对码")
        phoneService.tick()
        XCTAssertEqual(phoneService.interval, RemoteDeviceGroupService.activeInterval, "有设备想加入")

        XCTAssertTrue(phoneService.submit(code(pad) ?? "", for: phoneService.pendingRequest!))
        padService.tick()
        XCTAssertEqual(pad.joinState, .joined)
        XCTAssertNotNil(pad.awaitingAcknowledgement)
        XCTAssertEqual(padService.interval, RemoteDeviceGroupService.activeInterval, "已加入、在等对方回执")
        phoneService.tick()
        padService.tick()
        XCTAssertNil(pad.awaitingAcknowledgement)
        // G2：刚进组的 10 分钟里仍是快的（等各台 Mac 的开通结果），10 分钟后回到慢的见
        // `RemoteDeviceGroupHostsTests.test_fast_polling_for_ten_minutes_after_joining_then_idle`。
        XCTAssertTrue(pad.isOpeningHosts)
        XCTAssertEqual(padService.interval, RemoteDeviceGroupService.activeInterval, "刚进组，等 Mac 的结果")
        XCTAssertEqual(phoneService.interval, RemoteDeviceGroupService.idleInterval)
    }

    func test_polls_faster_while_someone_is_looking() async {
        let service = RemoteDeviceGroupService { _ in nil }
        XCTAssertEqual(service.interval, RemoteDeviceGroupService.idleInterval)
        let looking = Task { await service.keepActive() }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(service.interval, RemoteDeviceGroupService.activeInterval)
        looking.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(service.interval, RemoteDeviceGroupService.idleInterval)
    }
}
